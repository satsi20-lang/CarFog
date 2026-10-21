package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCardPayment.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Оплата картой в основном потоке (1.11.0, ТЗ раздел 6) на реальных кадрах
// адаптера Wafer и подставных часах. Цена 2,00 € = 200 ед. = 00 C8, запах 3.
class MdbCardPaymentTest {

    private class Rig {
        var now = 0L
        var owns = false
        val sent = mutableListOf<String>()
        val events = mutableListOf<Pair<String, Map<String, Any?>>>()
        val queue = MdbCommandQueue({ d, _ -> sent += MdbCashlessProtocol.toHex(d) }, {}, { now })
        val pay = MdbCardPayment(queue, {}, { t, d -> events += t to d }, { now }, { owns = it })

        fun rx(frame: String) {
            val e = MdbCashlessProtocol.parseFrame(frame)
            queue.onEvent(e)
            pay.onEvent(e)
        }

        fun ack() = rx("00\r\n")

        fun advance(ms: Long) {
            var left = ms
            while (left > 0) {
                val step = minOf(50L, left); now += step; left -= step
                pay.tick(); queue.tick()
            }
        }

        fun last() = events.last()
        fun types() = events.map { it.first }

        fun armed(units: Int = 200): Rig {
            pay.arm(units, 3, 30_000, true)
            assertTrue(owns)
            return this
        }

        // 10 03 → vend → 00 → 10 05 на 200 ед.
        fun approved(): Rig {
            armed()
            rx("10 03 03 E8\r\n")
            assertEquals(listOf(VEND), sent)
            advance(90); ack()
            advance(4000); rx("10 05 00 C8\r\n")
            assertEquals(State.APPROVED, pay.state)
            assertEquals("approved", last().first)
            sent.clear()
            advance(300)
            return this
        }
    }

    @Test
    fun normalPathTerminalClosesSessionItselfThenSuccess() {
        val r = Rig().approved()
        // ~40 с после 10 05 терминал сам просит закрыть сессию — 13 04.
        r.advance(35_000); r.rx("10 04\r\n")
        assertEquals(listOf("13 04"), r.sent)
        r.ack(); r.advance(96); r.rx("10 07\r\n")
        assertEquals(State.APPROVED, r.pay.state)
        // цикл прошёл минуты спустя — 13 02 уже не нужен
        r.advance(120_000)
        r.pay.finishSuccess()
        assertEquals("success", r.last().first)
        assertEquals(listOf("13 04"), r.sent)
        assertEquals(State.IDLE, r.pay.state)
        assertFalse(r.owns)
    }

    @Test
    fun successWhileSessionOpenSends1302Then1304() {
        val r = Rig().approved()
        r.advance(20_000)
        r.pay.finishSuccess()
        assertEquals(listOf("13 02 00 03"), r.sent)
        r.ack(); r.advance(300)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n")
        val (type, data) = r.last()
        assertEquals("success", type)
        assertEquals("ACK 00", data["confirm"])
        assertEquals(true, data["end_10_07"])
    }

    @Test
    fun declinedClosesSession() {
        val r = Rig().armed()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack()
        r.advance(3000); r.rx("10 06\r\n")
        r.advance(300)
        assertEquals(listOf(VEND, "13 04"), r.sent)
        r.ack(); r.rx("10 07\r\n")
        assertEquals("declined", r.last().first)
        assertEquals(State.IDLE, r.pay.state)
        assertFalse(r.types().contains("approved"))
    }

    @Test
    fun insufficientFundsNoVend() {
        val r = Rig().armed()
        r.rx("10 03 00 64\r\n")
        assertEquals(listOf("13 04"), r.sent)
        r.ack(); r.rx("10 07\r\n")
        assertEquals("insufficient_funds", r.last().first)
        assertEquals(100, r.last().second["funds"])
        assertTrue(r.sent.none { it.startsWith("13 00") })
    }

    @Test
    fun beginSessionWithoutFundsIsInsufficient() {
        val r = Rig().armed()
        r.rx("10 03\r\n")
        assertEquals(listOf("13 04"), r.sent)
    }

    @Test
    fun approvedAmountMismatchRefundsBeforeCycle() {
        val r = Rig().armed()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack()
        r.advance(3000); r.rx("10 05 00 64\r\n")
        assertEquals(listOf(VEND, "13 03"), r.sent)
        r.ack(); r.advance(300)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n")
        val (type, data) = r.last()
        assertEquals("amount_mismatch", type)
        assertEquals(100, data["approved_units"])
        assertFalse("цикл не запускается", r.types().contains("approved"))
    }

    @Test
    fun failureWithinWindowRefundsAutomatically() {
        val r = Rig().approved()
        r.advance(10_000)
        r.pay.finishFailure("bus_unavailable")
        assertEquals(listOf("13 03"), r.sent)
        r.ack(); r.advance(300)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n")
        val (type, data) = r.last()
        assertEquals("refunded", type)
        assertEquals("ACK 00", data["refund"])
        assertEquals("bus_unavailable", data["cycle_reason"])
    }

    @Test
    fun failureAfterWindowNeedsManualRefundAndOnly1304On1004() {
        val r = Rig().approved()
        r.advance(31_000)
        r.pay.finishFailure("heater_failure")
        assertEquals("manual_refund_needed", r.last().first)
        assertEquals("окно возврата прошло", r.last().second["refund"])
        assertTrue("никаких 13 03", r.sent.isEmpty())
        // 10 04 после итога — уже не наша сессия (контур связи ответит 13 04).
        assertEquals(State.IDLE, r.pay.state)
        assertFalse(r.owns)
    }

    @Test
    fun failureWithinWindowButSessionAlreadyClosedIsManual() {
        val r = Rig().approved()
        r.advance(5_000); r.rx("10 04\r\n"); r.ack(); r.rx("10 07\r\n")
        r.pay.finishFailure("sensor")
        assertEquals("manual_refund_needed", r.last().first)
        assertEquals("сессия уже закрыта терминалом", r.last().second["refund"])
    }

    @Test
    fun refundFfIsRetriedOnceThenManual() {
        val r = Rig().approved()
        r.pay.finishFailure("x")
        r.rx("FF\r\n"); r.advance(300)
        assertEquals(listOf("13 03", "13 03"), r.sent)
        r.rx("FF\r\n"); r.advance(300)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n")
        assertEquals("manual_refund_needed", r.last().first)
    }

    @Test
    fun refundFfOnceThenAckIsRefunded() {
        val r = Rig().approved()
        r.pay.finishFailure("x")
        r.rx("FF\r\n"); r.advance(300); r.ack()
        r.advance(300); r.ack(); r.rx("10 07\r\n")
        assertEquals("refunded", r.last().first)
    }

    @Test
    fun cancelRequestBeforeApprovalClosesSession() {
        val r = Rig().armed()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack()
        r.rx("10 04\r\n"); r.advance(300)
        assertEquals(listOf(VEND, "13 04"), r.sent)
        r.ack(); r.rx("10 07\r\n")
        assertEquals("cancelled_by_terminal", r.last().first)
    }

    @Test
    fun ffOnVendStopsAndClosesSession() {
        val r = Rig().armed()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.rx("FF\r\n")
        r.advance(300)
        assertEquals(listOf(VEND, "13 04"), r.sent)
        r.ack(); r.rx("10 07\r\n")
        assertEquals("vend_failed", r.last().first)
    }

    @Test
    fun lostAckOnVendStopsAndClosesSession() {
        val r = Rig().armed()
        r.rx("10 03 03 E8\r\n")
        r.advance(2_300)
        assertEquals(listOf(VEND, "13 04"), r.sent)
    }

    @Test
    fun noResultFor60sCancelsVend() {
        val r = Rig().armed()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack()
        r.advance(60_000)
        assertEquals(listOf(VEND, "13 01"), r.sent)
        r.ack(); r.rx("10 06\r\n"); r.advance(300)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n")
        assertEquals("vend_timeout", r.last().first)
    }

    @Test
    fun noAnswerAfter1301ClosesSessionAnyway() {
        val r = Rig().armed()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack()
        r.advance(60_000); r.ack()
        r.advance(10_000)
        assertEquals("13 04", r.sent.last())
    }

    @Test
    fun repeat1304WhenNo1007() {
        val r = Rig().approved()
        r.pay.finishFailure("x")
        r.ack(); r.advance(300); r.ack()
        r.advance(10_000)
        assertEquals(listOf("13 03", "13 04", "13 04"), r.sent)
        r.ack(); r.advance(10_000)
        val (type, data) = r.last()
        assertEquals("refunded", type)
        assertEquals(true, data["session_may_hang"])
    }

    @Test
    fun customerCancelOnlyBeforeCard() {
        val r = Rig().armed()
        assertTrue(r.pay.customerCanCancel)
        r.pay.cancelByCustomer()
        assertEquals(listOf("14 02"), r.sent)
        assertEquals(State.IDLE, r.pay.state)
        assertFalse(r.owns)

        val r2 = Rig().armed()
        r2.rx("10 03 03 E8\r\n")
        assertFalse(r2.pay.customerCanCancel)
        r2.pay.cancelByCustomer()
        assertEquals("после 10 03 отмена не действует", listOf(VEND), r2.sent)
    }

    @Test
    fun coinBeforeCardChangesVendAmount() {
        val r = Rig().armed(200)
        r.pay.updateUnits(100)
        r.rx("10 03 03 E8\r\n")
        assertEquals(listOf("13 00 00 64 00 03"), r.sent)
    }

    @Test
    fun disarmWithoutCardSendsNothing() {
        val r = Rig().armed()
        r.pay.disarm("таймаут")
        assertTrue(r.sent.isEmpty())
        assertEquals(State.IDLE, r.pay.state)
        assertFalse(r.owns)
    }

    @Test
    fun linkLostBeforeApprovalAborts() {
        val r = Rig().armed()
        r.rx("10 03 03 E8\r\n")
        r.pay.portLost("adapter detached")
        r.queue.clear()
        assertEquals("payment_aborted", r.last().first)
        assertEquals(true, r.last().second["vend_sent"])
        assertEquals(State.IDLE, r.pay.state)
    }

    @Test
    fun linkLostAfterApprovalThenFailureIsManual() {
        val r = Rig().approved()
        r.pay.portLost("adapter detached")
        r.queue.clear()
        r.pay.finishFailure("bus_unavailable")
        assertEquals("manual_refund_needed", r.last().first)
        assertTrue(r.sent.isEmpty())
    }

    @Test
    fun linkLostWhile1302InFlightEndsOnce() {
        val r = Rig().approved()
        r.pay.finishSuccess()
        r.pay.portLost("adapter detached")
        r.queue.clear()
        assertEquals(1, r.types().count { it == "success" })
        assertEquals(State.IDLE, r.pay.state)
    }

    @Test
    fun cannotArmTwiceAndBoundsAreChecked() {
        val r = Rig().armed()
        try {
            r.pay.arm(200, 3, 30_000, true); throw AssertionError()
        } catch (e: IllegalStateException) { /* ожидаемо */ }
        val r2 = Rig()
        for ((u, i) in listOf(0 to 1, 65536 to 1, 200 to 0, 200 to 9)) {
            try {
                r2.pay.arm(u, i, 30_000, true); throw AssertionError("$u/$i")
            } catch (e: IllegalArgumentException) { /* ожидаемо */ }
        }
        assertNull(r2.pay.approvedAt)
    }

    @Test
    fun confirmDisabledSkips1302() {
        val r = Rig()
        r.pay.arm(200, 3, 30_000, false)
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack(); r.rx("10 05 00 C8\r\n")
        r.sent.clear(); r.advance(300)
        r.pay.finishSuccess()
        assertEquals(listOf("13 04"), r.sent)
    }

    @Test
    fun unitsFromCentsFormula() {
        assertEquals(200, MdbCashlessProtocol.unitsFromCents(200, 1, 2))
        assertEquals(20, MdbCashlessProtocol.unitsFromCents(200, 10, 2))
        assertNull("2,05 € при масштабе 10 — не целое", MdbCashlessProtocol.unitsFromCents(205, 10, 2))
        assertNull(MdbCashlessProtocol.unitsFromCents(70_000, 1, 2))
        assertEquals(2, MdbCashlessProtocol.unitsFromCents(200, 1, 0))
        assertNull("2,50 € без знаков после запятой — не целое", MdbCashlessProtocol.unitsFromCents(250, 1, 0))
    }

    companion object {
        const val VEND = "13 00 00 C8 00 03"
    }
}
