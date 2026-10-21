package com.example.dry_fog_app

import com.example.dry_fog_app.MdbKeepAlive.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MdbKeepAliveTest {
    private var now = 0L
    private val k = MdbKeepAlive({ now })
    private fun frame(s: String) = MdbCashlessProtocol.parseFrame(s)

    @Test
    fun noPollWhileReceptionDisabled() {
        now = 120_000
        assertEquals(Action.NONE, k.tick())
    }

    @Test
    fun pollsEvery60sWhileEnabledAndNoSession() {
        k.onSent(MdbCashlessProtocol.ENABLE)
        now = 59_999
        assertEquals(Action.NONE, k.tick())
        now = 60_000
        assertEquals(Action.SEND_SETUP, k.tick())
        k.onEvent(frame("01 01 19 78 01 02 78 0D 1B\r\n"))
        assertFalse(k.silent)
        now = 119_999
        assertEquals(Action.NONE, k.tick())
        now = 120_000
        assertEquals(Action.SEND_SETUP, k.tick())
    }

    @Test
    fun noPollDuringSession() {
        k.onSent(MdbCashlessProtocol.ENABLE)
        k.onEvent(frame("10 03 03 E8\r\n"))
        now = 300_000
        assertEquals(Action.NONE, k.tick())
        k.onEvent(frame("10 07\r\n"))
        assertEquals(Action.SEND_SETUP, k.tick())
    }

    @Test
    fun silenceIsReportedOnceAndNothingIsResentAutomatically() {
        k.onSent(MdbCashlessProtocol.ENABLE)
        now = 60_000
        assertEquals(Action.SEND_SETUP, k.tick())
        now = 64_999
        assertEquals(Action.NONE, k.tick())
        now = 65_000
        assertEquals(Action.REPORT_SILENCE, k.tick())
        assertTrue(k.silent)
        // дальше только обычный опрос setup раз в 60 с — prices/enable сам не шлёт
        now = 100_000
        assertEquals(Action.NONE, k.tick())
        now = 120_000
        assertEquals(Action.SEND_SETUP, k.tick())
    }

    @Test
    fun disableStopsPollingAndManualEnableClearsSilence() {
        k.onSent(MdbCashlessProtocol.ENABLE)
        now = 60_000
        k.tick()
        now = 65_000
        k.tick()
        assertTrue(k.silent)
        k.onSent(MdbCashlessProtocol.DISABLE)
        now = 500_000
        assertEquals(Action.NONE, k.tick())
        k.onSent(MdbCashlessProtocol.ENABLE)
        assertFalse(k.silent)
    }

    @Test
    fun pausedDuringTestPayment() {
        k.onSent(MdbCashlessProtocol.ENABLE)
        now = 60_000
        assertEquals(Action.NONE, k.tick(paused = true))
        assertEquals(Action.SEND_SETUP, k.tick())
    }
}
