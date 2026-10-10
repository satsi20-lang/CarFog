package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Test

class BusWatchdogTest {

    @Test
    fun `переоткрытие ровно на десятой ошибке подряд`() {
        val w = BusWatchdog()
        repeat(9) { assertEquals(BusWatchdog.Action.NONE, w.onResult(false, 0)) }
        assertEquals(BusWatchdog.Action.REOPEN, w.onResult(false, 0))
        assertEquals("после переоткрытия серия начинается заново", 0, w.consecutiveFailures)
    }

    @Test
    fun `успех сбрасывает серию и считается`() {
        val w = BusWatchdog()
        repeat(5) { w.onResult(false, 0) }
        w.onResult(true, 0)
        assertEquals(0, w.consecutiveFailures)
        assertEquals(1L, w.successTotal)
    }

    @Test
    fun `окно 60 с - не больше трёх переоткрытий`() {
        val w = BusWatchdog()
        var reopens = 0
        for (t in 0 until 59_000L step 100) {
            if (w.onResult(false, t) == BusWatchdog.Action.REOPEN) reopens++
        }
        assertEquals(3, reopens)
        // Первое переоткрытие было на t=900 — через 60 с от него окно освобождается.
        assertEquals(BusWatchdog.Action.REOPEN, w.onResult(false, 60_900))
    }

    @Test
    fun `canReopen=false - только счёт`() {
        val w = BusWatchdog()
        repeat(20) { assertEquals(BusWatchdog.Action.NONE, w.onResult(false, 0, canReopen = false)) }
        assertEquals(20, w.consecutiveFailures)
    }
}
