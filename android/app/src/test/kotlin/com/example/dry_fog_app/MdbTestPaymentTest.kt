package com.example.dry_fog_app

import com.example.dry_fog_app.MdbTestPayment.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

// Режим «одна тестовая оплата 0,10 €» на реальных кадрах адаптера Wafer.
class MdbTestPaymentTest {

    private class Rig {
        var now = 0L
        val sent = mutableListOf<String>()
        val notes = mutableListOf<String>()
        var failSend = false
        val pay = MdbTestPayment(
            send = { d, _ ->
                if (failSend) throw IOException("порт не открыт")
                sent += MdbCashlessProtocol.toHex(d)
            },
            note = { notes += it },
            clock = { now },
        )

        fun rx(frame: String) = pay.onEvent(MdbCashlessProtocol.parseFrame(frame))

        fun after(ms: Long) {
            now += ms
            pay.tick()
        }

        // setup → ответ → prices → ACK → enable → ACK: ждём карту.
        fun startToSession(): Rig {
            pay.start()
            rx("01 01 19 78 01 02 78 0D 1B\r\n")
            rx("00\r\n")
            rx("00\r\n")
            assertEquals(State.WAIT_SESSION, pay.state)
            assertEquals(listOf("11 00 01 00 00 00", "11 01 FF FF 00 00", "14 01"), sent)
            sent.clear()
            return this
        }
    }

    private val vend10 = "13 00 00 0A 00 01"

    @Test
    fun happyPath() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        assertEquals("vend уходит сразу на 10 03", listOf(vend10), r.sent)
        r.rx("10 05 00 0A\r\n")
        assertEquals(listOf(vend10, "13 02 00 01", "13 04"), r.sent)
        assertEquals(State.WAIT_END_SESSION, r.pay.state)
        r.rx("00\r\n")
        r.rx("10 07\r\n")
        assertEquals(listOf(vend10, "13 02 00 01", "13 04", "14 00"), r.sent)
        assertEquals(State.DONE, r.pay.state)
        assertTrue(r.pay.outcome!!.ok)
    }

    @Test
    fun noCardIn60sDisablesWithoutVend() {
        val r = Rig().startToSession()
        r.after(59_000)
        assertEquals(State.WAIT_SESSION, r.pay.state)
        r.after(1_000)
        assertEquals(listOf("14 00"), r.sent)
        assertFalse(r.pay.outcome!!.ok)
    }

    @Test
    fun beginSessionWithoutFundsOrBelow10GetsSessionCompleteNotVend() {
        for (frame in listOf("10 03\r\n", "10 03 00 09\r\n")) {
            val r = Rig().startToSession()
            r.rx(frame)
            assertEquals(frame, listOf("13 04"), r.sent)
            r.rx("10 07\r\n")
            assertEquals(frame, listOf("13 04", "14 00"), r.sent)
            assertFalse(r.pay.outcome!!.ok)
        }
    }

    @Test
    fun largerApprovedAmountIsRefunded() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.rx("10 05 00 14\r\n")
        assertEquals(listOf(vend10, "13 03", "13 04"), r.sent)
        r.rx("10 07\r\n")
        assertEquals(listOf(vend10, "13 03", "13 04", "14 00"), r.sent)
        assertFalse(r.pay.outcome!!.ok)
        assertTrue(r.pay.outcome!!.text, r.pay.outcome!!.text.contains("13 03"))
    }

    @Test
    fun approvalWithoutAmountIsRefundedToo() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.rx("10 05\r\n")
        assertEquals(listOf(vend10, "13 03", "13 04"), r.sent)
    }

    @Test
    fun deniedGetsSessionComplete() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.rx("10 06\r\n")
        assertEquals(listOf(vend10, "13 04"), r.sent)
        r.rx("10 07\r\n")
        assertEquals(listOf(vend10, "13 04", "14 00"), r.sent)
        assertFalse(r.pay.outcome!!.ok)
    }

    @Test
    fun cancelRequestGetsSessionComplete() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.rx("10 04\r\n")
        assertEquals(listOf(vend10, "13 04"), r.sent)
        r.rx("10 04\r\n") // повтор не вызывает второго 13 04
        r.rx("10 07\r\n")
        assertEquals(listOf(vend10, "13 04", "14 00"), r.sent)
    }

    @Test
    fun cancelRequestBeforeCardGetsSessionComplete() {
        val r = Rig().startToSession()
        r.rx("10 04\r\n")
        assertEquals(listOf("13 04"), r.sent)
    }

    @Test
    fun secondBeginSessionNeverSendsSecondVend() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.rx("10 03 03 E8\r\n")
        assertEquals(listOf(vend10), r.sent)
    }

    @Test
    fun endSessionTimeoutStillDisables() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.rx("10 05 00 0A\r\n")
        r.after(10_000)
        assertEquals(listOf(vend10, "13 02 00 01", "13 04", "14 00"), r.sent)
        assertTrue("деньги одобрены и выдача подтверждена", r.pay.outcome!!.ok)
        assertTrue(r.pay.outcome!!.text.contains("10 07 не пришло"))
    }

    @Test
    fun noVendResultCancelsThenCompletes() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.after(60_000)
        assertEquals(listOf(vend10, "13 01"), r.sent)
        r.rx("10 06\r\n")
        assertEquals(listOf(vend10, "13 01", "13 04"), r.sent)
        r.rx("10 07\r\n")
        assertEquals(listOf(vend10, "13 01", "13 04", "14 00"), r.sent)
        assertFalse(r.pay.outcome!!.ok)
    }

    @Test
    fun lateApprovalAfterCancelIsRefunded() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.after(60_000)
        r.rx("10 05 00 0A\r\n")
        assertEquals(listOf(vend10, "13 01", "13 03", "13 04"), r.sent)
    }

    @Test
    fun setupWithOtherScaleNeverEnables() {
        val r = Rig()
        r.pay.start()
        // масштаб 5: 0,10 € = 2 ед., не 10
        r.rx("01 01 19 78 05 02 78 0D 1F\r\n")
        assertEquals(listOf("11 00 01 00 00 00", "14 00"), r.sent)
        assertFalse(r.pay.outcome!!.ok)
    }

    @Test
    fun badChecksumSetupIsIgnoredAndTimesOut() {
        val r = Rig()
        r.pay.start()
        r.rx("01 01 19 78 01 02 78 0D 1C\r\n")
        assertEquals(State.WAIT_SETUP, r.pay.state)
        r.after(5_000)
        assertEquals(listOf("11 00 01 00 00 00", "14 00"), r.sent)
    }

    @Test
    fun missingAckStops() {
        val r = Rig()
        r.pay.start()
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n")
        r.after(3_000)
        assertEquals(listOf("11 00 01 00 00 00", "11 01 FF FF 00 00", "14 00"), r.sent)
    }

    @Test
    fun garbageAndUnknownFramesChangeNothing() {
        val r = Rig().startToSession()
        for (f in listOf("zz", "10 0", "10 09", "05 00 0A", "")) r.rx(f)
        assertEquals(State.WAIT_SESSION, r.pay.state)
        assertTrue(r.sent.isEmpty())
    }

    @Test
    fun abortWhileWaitingForCardDisables() {
        val r = Rig().startToSession()
        r.pay.abort()
        assertEquals(listOf("14 00"), r.sent)
        assertFalse(r.pay.active)
    }

    @Test
    fun portLostAfterVendWarnsToCheckNayax() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.pay.portLost("адаптер отключён")
        assertFalse(r.pay.active)
        assertTrue(r.pay.outcome!!.text.contains("кабинете Nayax"))
    }

    @Test
    fun sendFailureEndsWithoutRetry() {
        val r = Rig().startToSession()
        r.failSend = true
        r.rx("10 03 03 E8\r\n")
        assertFalse(r.pay.active)
        assertTrue(r.sent.isEmpty())
    }

    @Test
    fun cannotStartTwice() {
        val r = Rig()
        r.pay.start()
        try {
            r.pay.start()
            throw AssertionError("второй старт должен быть запрещён")
        } catch (e: IllegalStateException) {
            // ожидаемо
        }
    }
}
