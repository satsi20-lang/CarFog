package com.example.dry_fog_app

import com.example.dry_fog_app.SystemBarsDecision.Action
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SystemBarsDecisionTest {
    private val delay = 2000L
    private val cooldown = 10_000L

    private fun next(
        enabled: Boolean = true,
        visible: Boolean = false,
        lost: Boolean = false,
        since: Long? = null,
        lastAbort: Long? = null,
        now: Long,
    ) = SystemBarsDecision.next(enabled, visible, lost, since, lastAbort, now, delay, cooldown)

    @Test
    fun `выключенный сторож ничего не делает`() {
        val s = next(enabled = false, visible = true, lost = true, since = 0L, now = 10_000L)
        assertEquals(Action.NONE, s.action)
        assertNull(s.shownSinceMs)
    }

    @Test
    fun `панель скрыта и управление у окна — момент сбрасывается`() {
        val s = next(since = 1_000L, now = 10_000L)
        assertEquals(Action.NONE, s.action)
        assertNull(s.shownSinceMs)
    }

    @Test
    fun `постоянный показ — прячем через задержку`() {
        assertEquals(5_000L, next(visible = true, now = 5_000L).shownSinceMs)
        assertEquals(Action.NONE, next(visible = true, since = 5_000L, now = 6_999L).action)
        assertEquals(Action.HIDE, next(visible = true, since = 5_000L, now = 7_000L).action)
    }

    @Test
    fun `временный показ (нет управления) — прерываем через задержку`() {
        assertEquals(Action.NONE, next(lost = true, since = 5_000L, now = 6_000L).action)
        val s = next(lost = true, since = 5_000L, now = 7_000L)
        assertEquals(Action.ABORT_AND_HIDE, s.action)
        assertNull(s.shownSinceMs)
    }

    @Test
    fun `прерывание не чаще раза в 10 с — панель не мигает`() {
        // Управление не вернулось после прерывания в 7_000.
        val s1 = next(lost = true, since = 8_000L, lastAbort = 7_000L, now = 12_000L)
        assertEquals(Action.NONE, s1.action)
        assertEquals(8_000L, s1.shownSinceMs)
        assertEquals(
            Action.ABORT_AND_HIDE,
            next(lost = true, since = 8_000L, lastAbort = 7_000L, now = 17_000L).action,
        )
    }

    @Test
    fun `залипший временный показ снимается не позже чем через 3 с`() {
        // Управление потеряно в 1_000 (свайп), тики раз в секунду.
        var since: Long? = null
        var at = -1L
        for (t in listOf(1_300L, 2_300L, 3_300L, 4_300L)) {
            val s = next(lost = true, since = since, now = t)
            since = s.shownSinceMs
            if (s.action != Action.NONE) { at = t; break }
        }
        assertEquals(3_300L, at)
    }
}
