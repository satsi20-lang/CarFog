package com.example.dry_fog_app

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
        assertFalse(k.due())
    }

    @Test
    fun pollsEvery60sAfterEnableAck() {
        k.onAcked(MdbCashlessProtocol.ENABLE)
        now = 59_999
        assertFalse(k.due())
        now = 60_000
        assertTrue(k.due())
        assertFalse("пока ответ не пришёл, второй опрос не ставим", k.due())
        k.onPollDone(true)
        now = 119_999
        assertFalse(k.due())
        now = 120_000
        assertTrue(k.due())
    }

    @Test
    fun noPollDuringSession() {
        k.onAcked(MdbCashlessProtocol.ENABLE)
        k.onEvent(frame("10 03 03 E8\r\n"))
        now = 300_000
        assertFalse(k.due())
        k.onEvent(frame("10 07\r\n"))
        assertTrue(k.due())
    }

    @Test
    fun silenceIsFlaggedAndClearedOnlyByAnswerOrEnable() {
        k.onAcked(MdbCashlessProtocol.ENABLE)
        now = 60_000
        assertTrue(k.due())
        k.onPollDone(false)
        assertTrue(k.silent)
        k.onEvent(frame("01 01 19 78 01 02 78 0D 1B\r\n"))
        assertFalse(k.silent)
    }

    @Test
    fun disableStopsPolling() {
        k.onAcked(MdbCashlessProtocol.ENABLE)
        k.onAcked(MdbCashlessProtocol.DISABLE)
        now = 500_000
        assertFalse(k.due())
    }

    @Test
    fun pausedDuringTestPayment() {
        k.onAcked(MdbCashlessProtocol.ENABLE)
        now = 60_000
        assertFalse(k.due(paused = true))
        assertTrue(k.due())
    }
}
