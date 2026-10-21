package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCommandQueue.Command
import com.example.dry_fog_app.MdbCommandQueue.Result
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MdbCommandQueueTest {
    private var now = 0L
    private val sent = mutableListOf<Pair<Long, String>>()
    private val notes = mutableListOf<String>()
    private val q = MdbCommandQueue(
        send = { d, _ -> sent += now to MdbCashlessProtocol.toHex(d) },
        note = { notes += it },
        clock = { now },
    )
    private fun rx(s: String) = q.onEvent(MdbCashlessProtocol.parseFrame(s))
    private fun advance(ms: Long) {
        var left = ms
        while (left > 0) {
            val step = minOf(50L, left); now += step; left -= step; q.tick()
        }
    }

    @Test
    fun oneCommandAtATimeWaitsForAckAndGap() {
        q.enqueue(Command(MdbCashlessProtocol.vendSuccess(1), "13 02"))
        q.enqueue(Command(MdbCashlessProtocol.SESSION_COMPLETE, "13 04"))
        assertEquals(listOf("13 02 00 01"), sent.map { it.second })
        advance(1000)
        assertEquals("без ACK вторая не уходит", 1, sent.size)
        rx("00\r\n")
        advance(250)
        assertEquals("не раньше 300 мс после ACK", 1, sent.size)
        advance(50)
        assertEquals(listOf("13 02 00 01", "13 04"), sent.map { it.second })
        assertEquals(1300L, sent[1].first)
    }

    @Test
    fun ffIsNak() {
        var result: Result? = null
        q.enqueue(Command(MdbCashlessProtocol.vendSuccess(1), "13 02") { r, _ -> result = r })
        assertTrue(rx("FF\r\n"))
        assertEquals(Result.NAK, result)
        assertTrue(notes.single().contains("отказ адаптера (FF)"))
    }

    @Test
    fun noAckIn2sIsTimeoutAndQueueMovesOn() {
        var result: Result? = null
        q.enqueue(Command(MdbCashlessProtocol.SESSION_COMPLETE, "13 04") { r, _ -> result = r })
        q.enqueue(Command(MdbCashlessProtocol.DISABLE, "14 00"))
        advance(1950)
        assertEquals(null, result)
        advance(50)
        assertEquals(Result.TIMEOUT, result)
        advance(300)
        assertEquals(listOf("13 04", "14 00"), sent.map { it.second })
    }

    @Test
    fun setupReplyCountsAsAckOnlyForSetup() {
        var setup: Result? = null
        q.enqueue(Command(MdbCashlessProtocol.SETUP, "setup") { r, e ->
            setup = r
            assertTrue(e is MdbCashlessProtocol.Event.Setup)
        })
        assertTrue(rx("01 01 19 78 01 02 78 0D 1B\r\n"))
        assertEquals(Result.ACK, setup)
        advance(300)
        q.enqueue(Command(MdbCashlessProtocol.PRICES, "prices"))
        assertFalse("ответ setup — не ACK для prices", rx("01 01 19 78 01 02 78 0D 1B\r\n"))
        assertTrue(q.busy)
    }

    @Test
    fun eventsDoNotCompleteCommands() {
        q.enqueue(Command(MdbCashlessProtocol.SESSION_COMPLETE, "13 04"))
        for (f in listOf("10 07\r\n", "10 03 03 E8\r\n", "zz", "10 0")) assertFalse(f, rx(f))
        assertTrue(q.busy)
    }

    @Test
    fun clearDropsEverythingAndNothingIsSentAfterwards() {
        val results = mutableListOf<Result>()
        q.enqueue(Command(MdbCashlessProtocol.SESSION_COMPLETE, "13 04") { r, _ ->
            results += r
            q.enqueue(Command(MdbCashlessProtocol.DISABLE, "14 00"))
        })
        q.enqueue(Command(MdbCashlessProtocol.DISABLE, "14 00") { r, _ -> results += r })
        q.clear()
        advance(1000)
        assertEquals(listOf(Result.DROPPED, Result.DROPPED), results)
        assertEquals(1, sent.size)
        assertFalse(q.busy)
    }
}
