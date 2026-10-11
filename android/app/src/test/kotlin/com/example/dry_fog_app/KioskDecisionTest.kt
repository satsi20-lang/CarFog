package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KioskDecisionTest {
    @Test
    fun locksOnlyAsDeviceOwnerWithLockEnabled() {
        assertTrue(KioskDecision.shouldLock(true, true, 0L, 1000L))
        assertFalse(KioskDecision.shouldLock(false, true, 0L, 1000L))
        assertFalse(KioskDecision.shouldLock(true, false, 0L, 1000L))
        assertFalse(KioskDecision.shouldLock(false, false, 0L, 1000L))
    }

    @Test
    fun temporaryExitSuspendsLockUntilDeadline() {
        val until = 1000L + KioskPolicy.EXIT_WINDOW_MS
        assertFalse(KioskDecision.shouldLock(true, true, until, 1000L))
        assertFalse(KioskDecision.shouldLock(true, true, until, until - 1))
        assertTrue(KioskDecision.shouldLock(true, true, until, until))
    }

    @Test
    fun exitRemaining() {
        assertEquals(0L, KioskDecision.exitRemainingMs(0L, 5000L))
        assertEquals(0L, KioskDecision.exitRemainingMs(5000L, 6000L))
        assertEquals(4000L, KioskDecision.exitRemainingMs(9000L, 5000L))
    }

    @Test
    fun exitWindowIsTenMinutes() {
        assertEquals(10 * 60 * 1000L, KioskPolicy.EXIT_WINDOW_MS)
    }

    @Test
    fun relaunchAfterUpdateOnlyWithActiveLock() {
        assertTrue(KioskDecision.relaunchAfterUpdate(true, true))
        assertFalse(KioskDecision.relaunchAfterUpdate(true, false))
        assertFalse(KioskDecision.relaunchAfterUpdate(false, true))
        assertFalse(KioskDecision.relaunchAfterUpdate(false, false))
    }

    @Test
    fun replaceInstanceOnlyWhenAliasGoesAway() {
        assertTrue(KioskDecision.replaceInstanceOnRelease(true, false))
        assertFalse(KioskDecision.replaceInstanceOnRelease(true, true))
        assertFalse(KioskDecision.replaceInstanceOnRelease(false, false))
        assertFalse(KioskDecision.replaceInstanceOnRelease(false, true))
    }
}
