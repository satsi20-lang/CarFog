package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SystemBarsDecisionTest {
    private val delay = 2000L

    @Test
    fun `выключенный сторож ничего не прячет`() {
        val s = SystemBarsDecision.next(false, true, 0L, 10_000L, delay)
        assertFalse(s.hide)
        assertNull(s.visibleSinceMs)
    }

    @Test
    fun `панель не видна — момент появления сбрасывается`() {
        val s = SystemBarsDecision.next(true, false, 1_000L, 10_000L, delay)
        assertFalse(s.hide)
        assertNull(s.visibleSinceMs)
    }

    @Test
    fun `панель только появилась — запоминаем момент, не прячем`() {
        val s = SystemBarsDecision.next(true, true, null, 5_000L, delay)
        assertFalse(s.hide)
        assertEquals(5_000L, s.visibleSinceMs)
    }

    @Test
    fun `видна меньше задержки — не прячем`() {
        val s = SystemBarsDecision.next(true, true, 5_000L, 6_999L, delay)
        assertFalse(s.hide)
        assertEquals(5_000L, s.visibleSinceMs)
    }

    @Test
    fun `видна задержку и дольше — прячем`() {
        assertTrue(SystemBarsDecision.next(true, true, 5_000L, 7_000L, delay).hide)
        assertTrue(SystemBarsDecision.next(true, true, 5_000L, 60_000L, delay).hide)
    }

    @Test
    fun `проверка раз в секунду прячет не позже чем через 3 с`() {
        // Панель появилась между проверками: первая проверка её видит, далее
        // тики по 1000 мс.
        var since: Long? = null
        var hiddenAt = -1L
        for (t in listOf(1_300L, 2_300L, 3_300L, 4_300L)) {
            val s = SystemBarsDecision.next(true, true, since, t, delay)
            since = s.visibleSinceMs
            if (s.hide) { hiddenAt = t; break }
        }
        assertEquals(3_300L, hiddenAt)
        assertTrue(hiddenAt - 1_000L <= 3_000L) // появилась после 1_000
    }
}
