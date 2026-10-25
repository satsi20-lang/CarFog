package com.example.dry_fog_app

import com.example.dry_fog_app.MdbLinkSupervisor.State
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Контур связи с терминалом в основном потоке (1.11.0, ТЗ раздел 7) на
// реальных кадрах адаптера Wafer и подставных часах.
class MdbLinkSupervisorTest {

    private class Rig {
        var now = 0L
        var present = true
        var openOk = true
        var opens = 0
        val closes = mutableListOf<String>()
        val sent = mutableListOf<String>()
        val events = mutableListOf<Pair<String, Map<String, Any?>>>()
        val queue = MdbCommandQueue({ d, _ -> sent += MdbCashlessProtocol.toHex(d) }, {}, { now })
        val sup = MdbLinkSupervisor(
            queue,
            object : MdbLinkSupervisor.Io {
                override fun devicePresent() = present
                override fun openPort(): Boolean {
                    opens++
                    return openOk
                }
                override fun closePort(reason: String) {
                    closes += reason
                }
            },
            {},
            { t, d -> events += t to d },
            { now },
        )

        fun rx(frame: String) {
            val e = MdbCashlessProtocol.parseFrame(frame)
            queue.onEvent(e)
            sup.onEvent(e)
        }

        fun advance(ms: Long) {
            var left = ms
            while (left > 0) {
                val step = minOf(50L, left); now += step; left -= step
                sup.tick(); queue.tick()
            }
        }

        fun eventTypes() = events.map { it.first }

        // Включение: setup → 01 … → prices → 00 → enable → 00.
        fun startReady(enabled: Boolean = true): Rig {
            sup.setDesiredEnabled(enabled)
            sup.setActive(true)
            assertEquals(listOf(SETUP), sent)
            rx("01 01 19 78 01 02 78 0D 1B\r\n")
            advance(300); rx("00\r\n")
            advance(300); rx("00\r\n")
            assertEquals(State.READY, sup.state)
            // Пауза 300 мс после ACK на enable прошла — следующая команда уйдёт сразу.
            advance(300)
            sent.clear()
            return this
        }
    }

    @Test
    fun startupSendsSetupPricesEnableAndBecomesReady() {
        val r = Rig()
        r.sup.setDesiredEnabled(true)
        r.sup.setActive(true)
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n")
        r.advance(300); r.rx("00\r\n")
        r.advance(300); r.rx("00\r\n")
        assertEquals(listOf(SETUP, PRICES, "14 01"), r.sent)
        assertTrue(r.sup.cardAvailable)
        assertEquals(1, r.sup.setupReply!!.scale)
        assertTrue(r.events.isEmpty())
    }

    @Test
    fun outOfServiceMeansDisableNotEnable() {
        val r = Rig().startReady(enabled = false)
        assertFalse(r.sup.readerEnabled)
        assertFalse(r.sup.cardAvailable)
        r.sup.setDesiredEnabled(true)
        r.advance(300)
        assertEquals(listOf("14 01"), r.sent)
        r.rx("00\r\n")
        assertTrue(r.sup.cardAvailable)
        r.advance(300)
        r.sup.setDesiredEnabled(false)
        r.advance(300)
        assertEquals("14 00", r.sent.last())
    }

    @Test
    fun pollEvery60sInIdle() {
        val r = Rig().startReady()
        r.advance(58_700)
        assertTrue(r.sent.isEmpty())
        r.advance(1_000)
        assertEquals(listOf(SETUP), r.sent)
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n")
        assertEquals(State.READY, r.sup.state)
        assertEquals(0, r.sup.consecutiveFailures)
    }

    @Test
    fun noPollDuringSession() {
        val r = Rig().startReady()
        r.sup.paymentOwnsSession = true
        r.rx("10 03 03 E8\r\n")
        r.advance(120_000)
        assertTrue("во время сессии опроса нет", r.sent.none { it == SETUP })
    }

    @Test
    fun silenceReopensPortAndReinitializes() {
        val r = Rig().startReady()
        r.advance(60_000)
        r.advance(2_000) // нет ответа на опрос
        assertEquals(State.RECOVERING, r.sup.state)
        assertEquals(1, r.closes.size)
        assertFalse(r.sup.cardAvailable)
        r.advance(5_000)
        assertEquals("порт открыт заново", 2, r.opens)
        assertEquals(SETUP, r.sent.last())
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n")
        r.advance(300); r.rx("00\r\n")
        r.advance(300); r.rx("00\r\n")
        assertEquals(State.READY, r.sup.state)
        assertTrue(r.sup.cardAvailable)
        assertTrue("одна неудача — без terminal_offline", r.events.isEmpty())
    }

    @Test
    fun threeFailuresInARowGoOfflineOnceThenRecover() {
        val r = Rig().startReady()
        r.advance(60_000); r.advance(2_000)          // 1: опрос без ответа
        r.advance(5_000); r.rx("FF\r\n")             // 2: FF на setup
        assertEquals(State.RECOVERING, r.sup.state)
        r.advance(5_000); r.advance(2_000)           // 3: молчание
        assertEquals(State.OFFLINE, r.sup.state)
        assertEquals(listOf("terminal_offline"), r.eventTypes())
        assertEquals("no_answer", r.events.single().second["reason"])
        assertFalse(r.sup.cardAvailable)
        // в offline пробуем раз в минуту, событие не повторяется
        r.advance(60_000); r.advance(2_000)
        assertEquals(listOf("terminal_offline"), r.eventTypes())
        // терминал вернулся
        r.advance(60_000)
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n")
        r.advance(300); r.rx("00\r\n")
        r.advance(300); r.rx("00\r\n")
        assertEquals(State.READY, r.sup.state)
        assertEquals(listOf("terminal_offline", "terminal_recovered"), r.eventTypes())
    }

    @Test
    fun offlineEventNotMoreOftenThanEvery5Minutes() {
        val r = Rig()
        r.present = false
        r.sup.setActive(true)
        assertEquals(State.NO_DEVICE, r.sup.state)
        assertEquals(listOf("terminal_offline"), r.eventTypes())
        assertEquals("no_device", r.events.single().second["reason"])
        // адаптер вставили → готов → recovered
        r.present = true
        r.sup.onDeviceChanged()
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n"); r.advance(300); r.rx("00\r\n"); r.advance(300); r.rx("00\r\n")
        assertEquals(listOf("terminal_offline", "terminal_recovered"), r.eventTypes())
        // снова выдернули через минуту — новое offline подавлено (меньше 5 мин)
        r.advance(60_000)
        r.present = false
        r.sup.onPortLost("USB_DEVICE_DETACHED")
        r.advance(10_000)
        assertEquals(State.NO_DEVICE, r.sup.state)
        assertEquals(listOf("terminal_offline", "terminal_recovered"), r.eventTypes())
    }

    @Test
    fun detachDuringReadyClosesAndWaitsForDevice() {
        val r = Rig().startReady()
        r.present = false
        r.sup.onPortLost("USB_DEVICE_DETACHED")
        assertFalse(r.sup.cardAvailable)
        assertEquals("при потере порта не считаем снятые команды", 1, r.sup.consecutiveFailures)
        r.advance(5_000)
        assertEquals(State.NO_DEVICE, r.sup.state)
    }

    @Test
    fun cancelRequestOutsidePaymentGetsSessionComplete() {
        val r = Rig().startReady()
        r.rx("10 04\r\n")
        assertEquals(listOf("13 04"), r.sent)
        r.rx("00\r\n"); r.rx("10 07\r\n")
        assertFalse(r.sup.inSession)
    }

    @Test
    fun cardTappedWithoutFlavorGetsSessionCompleteWithoutVend() {
        val r = Rig().startReady()
        r.rx("10 03 03 E8\r\n")
        assertEquals(listOf("13 04"), r.sent)
        assertEquals("card_tapped_without_flavor", r.eventTypes().single())
        assertFalse("сессия открыта — карта недоступна", r.sup.cardAvailable)
        r.rx("00\r\n"); r.advance(96); r.rx("10 07\r\n")
        assertTrue(r.sup.cardAvailable)
        assertTrue("vend не отправлялся", r.sent.none { it.startsWith("13 00") })
    }

    @Test
    fun paymentOwnedSessionIsNotClosedBySupervisor() {
        val r = Rig().startReady()
        r.sup.paymentOwnsSession = true
        r.rx("10 03 03 E8\r\n")
        r.rx("10 04\r\n")
        assertTrue(r.sent.isEmpty())
    }

    @Test
    fun unexpectedFrameIsReported() {
        val r = Rig().startReady()
        r.rx("10 09\r\n")
        assertEquals(1, r.sup.unexpectedFrames)
        assertEquals("terminal_unexpected_frame", r.eventTypes().single())
    }

    @Test
    fun benchTakesPortAndGivesItBack() {
        val r = Rig().startReady()
        r.sup.setService(true)
        assertEquals(State.SERVICE, r.sup.state)
        assertEquals(listOf("порт передан стенду"), r.closes)
        assertFalse(r.sup.cardAvailable)
        r.advance(120_000)
        assertTrue("в сервисном режиме ничего не шлём", r.sent.isEmpty())
        r.sup.setService(false)
        assertEquals(State.INITIALIZING, r.sup.state)
        assertEquals(listOf(SETUP), r.sent)
    }

    @Test
    fun typeNotMdbClosesPortAndStaysQuiet() {
        val r = Rig().startReady()
        r.sup.setActive(false)
        assertEquals(State.INACTIVE, r.sup.state)
        r.advance(300_000)
        assertTrue(r.sent.isEmpty())
        assertTrue(r.events.isEmpty())
    }

    @Test
    fun failedSetupDuringStartupCountsAndRetries() {
        val r = Rig()
        r.sup.setDesiredEnabled(true)
        r.sup.setActive(true)
        r.rx("FF\r\n")
        assertEquals(State.RECOVERING, r.sup.state)
        r.advance(5_000)
        assertEquals(2, r.opens)
    }

    // ---- 10 00 — Just Reset (1.11.2) ----

    @Test
    fun justResetOutsidePaymentReinitializesImmediately() {
        val r = Rig().startReady()
        r.advance(10_000)
        r.rx("10 00\r\n")
        // сразу, не через 60 с опроса
        assertEquals(listOf(SETUP), r.sent)
        assertEquals(State.INITIALIZING, r.sup.state)
        assertFalse(r.sup.cardAvailable)
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n")
        r.advance(100)
        assertEquals("пауза ≥300 мс после ACK", listOf(SETUP), r.sent)
        r.advance(200); r.rx("00\r\n")
        r.advance(300); r.rx("00\r\n")
        assertEquals(listOf(SETUP, PRICES, "14 01"), r.sent)
        assertEquals(State.READY, r.sup.state)
        assertTrue(r.sup.cardAvailable)
        assertEquals(listOf("terminal_reset"), r.eventTypes())
        assertEquals(false, r.events.single().second["during_payment"])
        assertEquals(0, r.sup.unexpectedFrames)
    }

    @Test
    fun justResetDuringPaymentOnlyLogsAndReports() {
        val r = Rig().startReady()
        r.sup.paymentOwnsSession = true
        r.rx("10 00\r\n")
        r.advance(5_000)
        assertTrue("никаких команд во время оплаты", r.sent.isEmpty())
        assertEquals(State.READY, r.sup.state)
        assertEquals(listOf("terminal_reset"), r.eventTypes())
        assertEquals(true, r.events.single().second["during_payment"])
        assertFalse(r.eventTypes().contains("terminal_unexpected_frame"))
    }

    @Test
    fun justResetDuringInitRestartsSetupOnce() {
        val r = Rig()
        r.sup.setDesiredEnabled(true)
        r.sup.setActive(true)
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n")
        r.advance(300)
        assertEquals(listOf(SETUP, PRICES), r.sent)
        r.rx("10 00\r\n")
        // prices в полёте — новая настройка ждёт его ответа, затем setup
        r.rx("00\r\n")
        r.advance(300)
        assertEquals(SETUP, r.sent.last())
        r.rx("01 01 19 78 01 02 78 0D 1B\r\n")
        r.advance(300); r.rx("00\r\n")
        r.advance(300); r.rx("00\r\n")
        assertEquals(State.READY, r.sup.state)
        assertEquals(0, r.sup.consecutiveFailures)
    }

    // ---- обрывки кадров (1.11.5) ----

    @Test
    fun fragmentsAreCountedNotUnexpectedAndReportedHourly() {
        val r = Rig().startReady()
        r.sup.onFrameFragment("не hex: нужна чётная длина")
        r.sup.onFrameFragment("кадр 78… не из паспорта")
        // первое — сразу (count 1), второе ждёт часа
        assertEquals(listOf("terminal_frame_fragments"), r.eventTypes())
        assertEquals(1, r.events[0].second["count"])
        assertEquals(0, r.sup.unexpectedFrames)
        assertEquals(2, r.sup.frameFragments)
        r.advance(30 * 60_000L)
        r.sup.onFrameFragment("кадр 19… не из паспорта")
        assertEquals(1, r.eventTypes().count { it == "terminal_frame_fragments" })
        // через час — сводно за период, даже без нового обрывка
        r.advance(31 * 60_000L)
        val e = r.events.filter { it.first == "terminal_frame_fragments" }
        assertEquals(2, e.size)
        assertEquals(2, e[1].second["count"])
        assertEquals(3, e[1].second["total"])
        assertEquals("кадр 19… не из паспорта", e[1].second["last_reason"])
        assertFalse(r.eventTypes().contains("terminal_unexpected_frame"))
        // нет новых — нет события
        r.advance(2 * 60 * 60_000L)
        assertEquals(2, r.eventTypes().count { it == "terminal_frame_fragments" })
    }

    @Test
    fun fragmentDoesNotBreakLinkAndWholeUnknownLineIsStillUnexpected() {
        val r = Rig().startReady()
        r.sup.onFrameFragment("кадр 78… не из паспорта")
        assertEquals(State.READY, r.sup.state)
        assertEquals(0, r.sup.consecutiveFailures)
        r.rx("10 09\r\n") // целая строка с \r\n, не из паспорта
        assertTrue(r.eventTypes().contains("terminal_unexpected_frame"))
        assertEquals(1, r.sup.unexpectedFrames)
    }

    companion object {
        const val SETUP = "11 00 01 00 00 00"
        const val PRICES = "11 01 FF FF 00 00"
    }
}
