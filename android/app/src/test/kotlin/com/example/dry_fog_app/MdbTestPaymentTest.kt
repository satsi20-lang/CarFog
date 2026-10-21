package com.example.dry_fog_app

import com.example.dry_fog_app.MdbTestPayment.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

// Тестовая оплата через очередь команд (1.10.12) на реальных кадрах адаптера
// Wafer. Время — подставные часы, без реальных пауз; шаг тика 50 мс, как у
// стенда.
class MdbTestPaymentTest {

    class Rig {
        var now = 0L
        val sent = mutableListOf<String>()
        val sentAt = mutableListOf<Long>()
        val notes = mutableListOf<String>()
        var failSend = false
        val queue = MdbCommandQueue(
            send = { d, _ ->
                if (failSend) throw IOException("порт не открыт")
                sent += MdbCashlessProtocol.toHex(d)
                sentAt += now
            },
            note = { notes += it },
            clock = { now },
        )
        val pay = MdbTestPayment(queue, { notes += it }, { now })

        // Порядок как в MdbUsbBench.dispatch: сначала очередь, потом автомат.
        fun rx(frame: String) {
            val e = MdbCashlessProtocol.parseFrame(frame)
            queue.onEvent(e)
            pay.onEvent(e)
        }

        fun ack() = rx("00\r\n")

        fun advance(ms: Long) {
            var left = ms
            while (left > 0) {
                val step = minOf(50L, left)
                now += step
                left -= step
                pay.tick()
                queue.tick()
            }
        }

        fun timeOf(hex: String): Long = sentAt[sent.lastIndexOf(hex)]

        // Как в журнале CARFOG-100 21.10.2026 17:55: setup → 01 … → prices → 00 →
        // enable → 00; ответы через ~100 мс.
        fun startToSession(): Rig {
            pay.start()
            advance(100); rx("01 01 19 78 01 02 78 0D 1B\r\n")
            advance(400); ack()
            advance(400); ack()
            assertEquals(State.WAIT_SESSION, pay.state)
            assertEquals(listOf("11 00 01 00 00 00", "11 01 FF FF 00 00", "14 01"), sent)
            // Пауза после ACK на enable прошла — следующая команда уйдёт сразу.
            advance(300)
            sent.clear(); sentAt.clear()
            return this
        }

        // 10 03 → vend → 00 → 10 05 на 10 ед.
        fun toApproved(): Rig {
            startToSession()
            advance(2600); rx("10 03 03 E8\r\n")
            assertEquals("vend уходит сразу на 10 03", listOf(VEND), sent)
            advance(90); ack()
            advance(4000); rx("10 05 00 0A\r\n")
            return this
        }
    }

    @Test
    fun normalCycleWithAcks() {
        val r = Rig().toApproved()
        assertEquals(listOf(VEND, "13 02 00 01"), r.sent)
        // До ACK на 13 02 ничего больше не уходит — ни через 3 мс, ни через 1,9 с.
        r.advance(1900)
        assertEquals(listOf(VEND, "13 02 00 01"), r.sent)
        r.ack()
        r.advance(999)
        assertEquals("13 04 не раньше 1 с после ACK на 13 02", 2, r.sent.size)
        r.advance(1)
        assertEquals("13 04", r.sent.last())
        assertTrue(r.timeOf("13 04") - r.timeOf("13 02 00 01") >= 1000)
        r.advance(30); r.ack()
        r.advance(96); r.rx("10 07\r\n")
        r.advance(300)
        assertEquals("14 00", r.sent.last())
        r.ack()
        assertEquals(State.DONE, r.pay.state)
        assertTrue(r.pay.outcome!!.text, r.pay.outcome!!.ok)
        assertTrue(r.pay.outcome!!.text.startsWith("УСПЕХ"))
        assertFalse(r.pay.outcome!!.sessionMayHang)
    }

    @Test
    fun replayOfFailedLogNeverSendsTwoCommandsBackToBack() {
        // В журнале 17:55:07 13 02 и 13 04 ушли через 3 мс → FF. Теперь каждые
        // две соседние команды разделены ответом и паузой ≥ 300 мс.
        val r = Rig().toApproved()
        r.advance(120); r.ack()
        r.advance(1000); r.advance(30); r.ack()
        r.advance(96); r.rx("10 07\r\n")
        r.advance(300); r.ack()
        for (i in 1 until r.sentAt.size) {
            assertTrue("${r.sent[i - 1]} → ${r.sent[i]}", r.sentAt[i] - r.sentAt[i - 1] >= 300)
        }
    }

    @Test
    fun ffOn1302IsRetriedOnce() {
        val r = Rig().toApproved()
        r.advance(120); r.rx("FF\r\n")
        assertTrue(r.notes.any { it.contains("отказ адаптера (FF)") })
        r.advance(300)
        assertEquals(listOf(VEND, "13 02 00 01", "13 02 00 01"), r.sent)
        r.ack()
        r.advance(1000)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n")
        r.advance(300); r.ack()
        assertTrue(r.pay.outcome!!.text, r.pay.outcome!!.ok)
    }

    @Test
    fun ffTwiceOn1302IsNotSuccessButSessionIsStillClosed() {
        val r = Rig().toApproved()
        r.advance(120); r.rx("FF\r\n")
        r.advance(300); r.rx("FF\r\n")
        assertEquals(listOf(VEND, "13 02 00 01", "13 02 00 01"), r.sent)
        r.advance(1000)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n")
        r.advance(300); r.ack()
        val o = r.pay.outcome!!
        assertFalse(o.ok)
        assertTrue(o.text, o.text.contains("оплата одобрена, выдача НЕ подтверждена терминалом"))
        assertTrue(o.text, o.text.contains("13 04: ACK"))
        assertTrue(o.text, o.text.contains("10 07: пришло"))
    }

    @Test
    fun noAckOn1302IsRetriedThenNotConfirmed() {
        val r = Rig().toApproved()
        r.advance(2000)
        assertEquals("нет ACK за 2 с — повтор", listOf(VEND, "13 02 00 01"), r.sent)
        r.advance(300)
        assertEquals(listOf(VEND, "13 02 00 01", "13 02 00 01"), r.sent)
        r.advance(2000)
        r.advance(1000)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n"); r.advance(300); r.ack()
        assertFalse(r.pay.outcome!!.ok)
        assertTrue(r.pay.outcome!!.text.contains("выдача НЕ подтверждена"))
    }

    @Test
    fun missingAckOn1304IsRetried() {
        val r = Rig().toApproved()
        r.ack(); r.advance(1000)
        assertEquals("13 04", r.sent.last())
        r.advance(2000) // нет ACK
        r.advance(300)
        assertEquals(listOf(VEND, "13 02 00 01", "13 04", "13 04"), r.sent)
        r.ack(); r.advance(96); r.rx("10 07\r\n")
        r.advance(300); r.ack()
        assertTrue(r.pay.outcome!!.text, r.pay.outcome!!.ok)
        assertTrue(r.pay.outcome!!.text.contains("попыток 2"))
    }

    @Test
    fun no1007MeansOneRepeatOf1304() {
        val r = Rig().toApproved()
        r.ack(); r.advance(1000); r.ack()
        r.advance(9_950)
        assertEquals(listOf(VEND, "13 02 00 01", "13 04"), r.sent)
        r.advance(50)
        assertEquals("10 07 нет за 10 с — повтор 13 04", listOf(VEND, "13 02 00 01", "13 04", "13 04"), r.sent)
        r.ack(); r.rx("10 07\r\n")
        r.advance(300); r.ack()
        assertTrue(r.pay.outcome!!.text, r.pay.outcome!!.ok)
    }

    @Test
    fun no1007AfterRepeatWarnsSessionMayHang() {
        val r = Rig().toApproved()
        r.ack(); r.advance(1000); r.ack()
        r.advance(10_000); r.ack()
        r.advance(10_000)
        r.advance(300)
        assertEquals("14 00", r.sent.last())
        r.ack()
        val o = r.pay.outcome!!
        assertFalse(o.ok)
        assertTrue(o.sessionMayHang)
        assertTrue(o.text, o.text.contains("сессия может висеть, нажмите done"))
        assertEquals(2, r.sent.count { it == "13 04" })
    }

    @Test
    fun delayed1007WithinTenSecondsIsFine() {
        val r = Rig().toApproved()
        r.ack(); r.advance(1000); r.ack()
        r.advance(9_900); r.rx("10 07\r\n")
        r.advance(300); r.ack()
        assertEquals(1, r.sent.count { it == "13 04" })
        assertTrue(r.pay.outcome!!.ok)
    }

    @Test
    fun ffOnVendStopsCycleWithSessionCompleteAndDisable() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.advance(90); r.rx("FF\r\n")
        r.advance(300)
        assertEquals(listOf(VEND, "13 04"), r.sent)
        r.ack(); r.rx("10 07\r\n")
        r.advance(300)
        assertEquals(listOf(VEND, "13 04", "14 00"), r.sent)
        r.ack()
        assertFalse(r.pay.outcome!!.ok)
        assertTrue(r.pay.outcome!!.text.contains("vend не принят адаптером"))
    }

    @Test
    fun noAckOnVendStopsCycle() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.advance(2300)
        assertEquals(listOf(VEND, "13 04"), r.sent)
    }

    @Test
    fun cancelRequestAfterEnableWithoutPayment() {
        val r = Rig().startToSession()
        r.advance(500); r.rx("10 04\r\n")
        assertEquals(listOf("13 04"), r.sent)
        r.ack(); r.rx("10 07\r\n")
        r.advance(300)
        assertEquals(listOf("13 04", "14 00"), r.sent)
    }

    @Test
    fun beginSessionWithoutFundsOrBelow10ClosesWithoutVend() {
        for (frame in listOf("10 03\r\n", "10 03 00 09\r\n")) {
            val r = Rig().startToSession()
            r.rx(frame)
            assertEquals(frame, listOf("13 04"), r.sent)
        }
    }

    @Test
    fun largerApprovedAmountIsRefunded() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack()
        r.advance(4000); r.rx("10 05 00 14\r\n")
        assertEquals(listOf(VEND, "13 03"), r.sent)
        r.ack(); r.advance(300)
        assertEquals("13 04", r.sent.last())
        r.ack(); r.rx("10 07\r\n"); r.advance(300); r.ack()
        assertFalse(r.pay.outcome!!.ok)
    }

    @Test
    fun deniedClosesSession() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack()
        r.advance(3000); r.rx("10 06\r\n")
        r.advance(300)
        assertEquals(listOf(VEND, "13 04"), r.sent)
    }

    @Test
    fun noCardIn60sDisables() {
        val r = Rig().startToSession()
        r.advance(60_000)
        assertEquals(listOf("14 00"), r.sent)
    }

    @Test
    fun secondBeginSessionNeverSendsSecondVend() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n"); r.advance(90); r.ack()
        r.rx("10 03 03 E8\r\n")
        r.advance(1000)
        assertEquals(listOf(VEND), r.sent)
    }

    @Test
    fun portLostAfterVendWarns() {
        val r = Rig().startToSession()
        r.rx("10 03 03 E8\r\n")
        r.pay.portLost("адаптер отключён")
        r.queue.clear()
        assertFalse(r.pay.active)
        assertTrue(r.pay.outcome!!.text.contains("кабинет Nayax"))
    }

    @Test
    fun setupWithOtherScaleNeverEnables() {
        val r = Rig()
        r.pay.start()
        r.rx("01 01 19 78 05 02 78 0D 1F\r\n")
        r.advance(300)
        assertEquals(listOf("11 00 01 00 00 00", "14 00"), r.sent)
    }

    companion object {
        const val VEND = "13 00 00 0A 00 01"
    }
}
