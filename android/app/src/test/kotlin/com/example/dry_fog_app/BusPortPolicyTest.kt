package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BusPortPolicyTest {
    @Test
    fun allowsSerialNodes() {
        assertTrue(BusPortPolicy.isAllowed("/dev/ttyS4"))
        assertTrue(BusPortPolicy.isAllowed("/dev/ttyS12"))
        assertTrue(BusPortPolicy.isAllowed("/dev/ttyUSB3"))
        assertTrue(BusPortPolicy.isAllowed("/dev/ttyACM0"))
    }

    @Test
    fun rejectsForbiddenNodes() {
        for (p in listOf("/dev/ttyS1", "/dev/ttyUSB0", "/dev/ttyUSB1", "/dev/ttyUSB2")) {
            assertFalse(p, BusPortPolicy.isAllowed(p))
        }
        assertEquals(4, BusPortPolicy.forbidden.size)
    }

    @Test
    fun rejectsOtherShapes() {
        for (p in listOf("", "ttyS4", "/dev/ttyS", "/dev/ttyS4 ", "/dev/ttyS4/../ttyS1",
            "/dev/null", "/data/local/tmp/x", "/dev/ttyS-1", "/dev/ttyP0")) {
            assertFalse(p, BusPortPolicy.isAllowed(p))
        }
    }
}
