package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Закрытие сессии — то же, что делает стенд на 10 04 вне тестовой оплаты
// (например после enable без нашей оплаты).
class MdbSessionCloserTest {
    private var now = 0L
    private val sent = mutableListOf<String>()
    private val q = MdbCommandQueue({ d, _ -> sent += MdbCashlessProtocol.toHex(d) }, {}, { now })
    private var report: MdbSessionCloser.Report? = null
    private val closer = MdbSessionCloser(q, {}, { now }, { report = it })

    private fun rx(s: String) {
        val e = MdbCashlessProtocol.parseFrame(s)
        q.onEvent(e)
        closer.onEvent(e)
    }
    private fun advance(ms: Long) {
        var left = ms
        while (left > 0) {
            val step = minOf(50L, left); now += step; left -= step; closer.tick(); q.tick()
        }
    }

    @Test
    fun cancelRequestOutsideCycleFromHardwareLog() {
        // Одиночный 13 04 → 00 → через 96 мс 10 07 (журнал 17:57:19).
        closer.start("10 04 от терминала")
        assertEquals(listOf("13 04"), sent)
        advance(30); rx("00\r\n")
        advance(96); rx("10 07\r\n")
        val r = report!!
        assertTrue(r.ackOk)
        assertTrue(r.ended)
        assertFalse(r.hanging)
        assertEquals(1, r.attempts)
    }

    @Test
    fun endBeforeAckWaitsForAck() {
        closer.start("тест")
        rx("10 07\r\n")
        assertEquals(null, report)
        rx("00\r\n")
        assertTrue(report!!.ackOk && report!!.ended)
    }

    @Test
    fun ffOn1304IsRetriedOnce() {
        closer.start("тест")
        rx("FF\r\n")
        advance(300)
        assertEquals(listOf("13 04", "13 04"), sent)
        rx("00\r\n"); rx("10 07\r\n")
        assertTrue(report!!.ackOk && report!!.ended)
        assertEquals(2, report!!.attempts)
    }

    @Test
    fun hangingAfterTwoAttempts() {
        closer.start("тест")
        rx("00\r\n")
        advance(10_000)
        assertEquals(listOf("13 04", "13 04"), sent)
        rx("00\r\n")
        advance(9_950)
        assertEquals(null, report)
        advance(50)
        assertTrue(report!!.hanging)
        assertEquals(MdbSessionCloser.HANGING_TEXT, "сессия может висеть, нажмите done")
        assertEquals(2, sent.size)
    }

    @Test
    fun secondStartWhileActiveIsIgnored() {
        closer.start("10 04")
        closer.start("10 04 ещё раз")
        advance(1000)
        assertEquals(listOf("13 04"), sent)
    }
}
