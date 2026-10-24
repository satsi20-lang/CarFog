package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MdbCashlessProtocolTest {
    private fun hex(s: String) = MdbCashlessProtocol.parseHex(s)

    @Test
    fun fixedCommandsMatchWaferManual() {
        assertArrayEquals(hex("110001000000"), MdbCashlessProtocol.SETUP)
        assertArrayEquals(hex("1101FFFF0000"), MdbCashlessProtocol.PRICES)
        assertArrayEquals(hex("1401"), MdbCashlessProtocol.ENABLE)
        assertArrayEquals(hex("1400"), MdbCashlessProtocol.DISABLE)
        assertArrayEquals(hex("1402"), MdbCashlessProtocol.READER_CANCEL)
        assertArrayEquals(hex("1301"), MdbCashlessProtocol.VEND_CANCEL)
        assertArrayEquals(hex("1303"), MdbCashlessProtocol.VEND_FAILURE)
        assertArrayEquals(hex("1304"), MdbCashlessProtocol.SESSION_COMPLETE)
    }

    @Test
    fun vendTenCentsAtScale1Decimals2() {
        val units = MdbCashlessProtocol.priceUnits("0.10", 1, 2)
        assertEquals(10, units)
        assertArrayEquals(hex("13 00 00 0A 00 01"), MdbCashlessProtocol.vendRequest(units, 1))
        assertEquals(10, MdbCashlessProtocol.priceUnits("0,10", 1, 2))
    }

    @Test
    fun vendSuccessItem1() {
        assertArrayEquals(hex("13 02 00 01"), MdbCashlessProtocol.vendSuccess(1))
    }

    @Test
    fun priceUnitsWithScale() {
        assertEquals(2, MdbCashlessProtocol.priceUnits("0.10", 5, 2))
        assertEquals(200, MdbCashlessProtocol.priceUnits("2", 1, 2))
        assertEquals(65535, MdbCashlessProtocol.priceUnits("655.35", 1, 2))
    }

    @Test
    fun priceOutOfRangeOrInexactIsRejected() {
        for ((amount, scale) in listOf("655.36" to 1, "-0.10" to 1, "0.12" to 5, "0.001" to 1, "abc" to 1)) {
            try {
                MdbCashlessProtocol.priceUnits(amount, scale, 2)
                throw AssertionError("ожидалась ошибка для $amount")
            } catch (e: IllegalArgumentException) {
                // ожидаемо
            }
        }
        for (units in listOf(-1, 0x10000)) {
            try {
                MdbCashlessProtocol.vendRequest(units, 1)
                throw AssertionError("ожидалась ошибка для $units")
            } catch (e: IllegalArgumentException) {
                // ожидаемо
            }
        }
    }

    @Test
    fun requestIdIs1700Plus29Bytes() {
        val cmd = MdbCashlessProtocol.requestId("CRF", "123", "DRYFOG", 0x0110)
        assertEquals(31, cmd.size)
        assertEquals(0x17, cmd[0].toInt())
        assertEquals(0x00, cmd[1].toInt())
        assertEquals("CRF", String(cmd, 2, 3, Charsets.US_ASCII))
        assertEquals("123         ", String(cmd, 5, 12, Charsets.US_ASCII))
        assertEquals("DRYFOG      ", String(cmd, 17, 12, Charsets.US_ASCII))
        assertEquals(0x01, cmd[29].toInt())
        assertEquals(0x10, cmd[30].toInt())
    }

    @Test(expected = IllegalArgumentException::class)
    fun requestIdRejectsLongField() {
        MdbCashlessProtocol.requestId("CRFX", "1", "M", 0)
    }

    // ---- реальные кадры адаптера Wafer (паспорт стенда, 1.10.11) ----
    private fun frame(s: String) = MdbCashlessProtocol.parseFrame(s)

    @Test
    fun setupReplyFromHardware() {
        val r = MdbCashlessProtocol.parseSetupReply("01 01 19 78 01 02 78 0D 1B\r\n")!!
        assertEquals(1, r.level)
        assertEquals(0x1978, r.country)
        assertEquals(1, r.scale)
        assertEquals(2, r.decimals)
        assertEquals(120, r.maxResponseSec)
        assertEquals(0x0D, r.options)
        // 0,10 € = 10 ед. = 00 0A
        assertEquals(10, MdbCashlessProtocol.priceUnits("0.10", r.scale, r.decimals))
        assertArrayEquals(hex("13 00 00 0A 00 01"),
            MdbCashlessProtocol.vendRequest(MdbCashlessProtocol.priceUnits("0.10", r.scale, r.decimals), 1))
    }

    @Test
    fun setupChecksumIsSumOfFirstEightBytes() {
        val data = hex("01 01 19 78 01 02 78 0D 1B")
        assertEquals(0x1B, MdbCashlessProtocol.checksum(data, 0, 8))
        assertTrue(MdbCashlessProtocol.hasValidChecksum(data))
        // пример из инструкции Wafer — тоже сходится
        assertEquals(2, MdbCashlessProtocol.parseSetupReply("010109720102070D94")!!.decimals)
    }

    @Test
    fun setupWithBadOrMissingChecksumIsNotAccepted() {
        assertNull(MdbCashlessProtocol.parseSetupReply("01 01 19 78 01 02 78 0D 1C"))
        assertNull(MdbCashlessProtocol.parseSetupReply("01 01 19 78 01 02 78 0D"))
        assertTrue(frame("01 01 19 78 01 02 78 0D 1C") is Event.Unrecognized)
        // масштаб 0 при верной сумме — тоже нет
        assertNull(MdbCashlessProtocol.parseSetupReply("01 01 19 78 00 02 78 0D 1A"))
    }

    @Test
    fun ffIsAdapterRefusal() {
        assertEquals(Event.Nak, frame("FF\r\n"))
        assertEquals("отказ адаптера (FF)", MdbCashlessProtocol.describe(Event.Nak))
        assertTrue(frame("FF FF") is Event.Unrecognized)
    }

    @Test
    fun ack() {
        assertEquals(Event.Ack, frame("00\r\n"))
        assertEquals(Event.Ack, frame("00"))
    }

    @Test
    fun terminalEventsWithPrefix10() {
        assertEquals(Event.BeginSession(1000), frame("10 03 03 E8\r\n"))
        assertEquals(Event.SessionCancelRequest, frame("10 04\r\n"))
        assertEquals(Event.VendApproved(10), frame("10 05 00 0A\r\n"))
        assertEquals(Event.VendDenied, frame("10 06\r\n"))
        assertEquals(Event.EndSession, frame("10 07\r\n"))
        assertEquals(Event.Cancelled, frame("10 08\r\n"))
        // 10 00 — Just Reset (терминал перезапустился, 1.11.2); с хвостом — не угадываем
        assertEquals(Event.JustReset, frame("10 00\r\n"))
        assertTrue(frame("10 00 01") is Event.Unrecognized)
        // сумма не пришла — событие есть, суммы нет (тестовая оплата не шлёт vend / делает возврат)
        assertEquals(Event.BeginSession(null), frame("10 03"))
        assertEquals(Event.VendApproved(null), frame("10 05"))
    }

    @Test
    fun eventsWithoutPrefixAreNotGuessed() {
        // по паспорту без префикса идут только ответы на команды (00, 01 …)
        for (s in listOf("03 03 E8", "05 00 0A", "06", "07", "08")) {
            assertTrue(s, frame(s) is Event.Unrecognized)
        }
    }

    @Test
    fun gluedTwoFramesInOneTextAreNotGuessed() {
        // Если бы кадры склеились, такой текст не должен разобраться как одно из событий.
        assertTrue(frame("00\r\n10 07\r\n") is Event.Unrecognized)
        assertTrue(frame("10 05 00 0A 10 07") is Event.Unrecognized)
    }

    @Test
    fun incompleteFramesAreNotGuessed() {
        for (s in listOf("10", "10 0", "10 03 03", "10 05 00", "01 01 19 78", "0")) {
            assertTrue(s, frame(s) is Event.Unrecognized)
        }
    }

    @Test
    fun garbageIsNotGuessed() {
        for (s in listOf("", "\r\n", "zz", "10 GG", "\u0000\u00FF", "10 09", "10 0A 01", "02", "FE")) {
            assertTrue(s, frame(s) is Event.Unrecognized)
        }
    }

    private fun priceError(amount: String, scale: Int, decimals: Int = 2): String = try {
        MdbCashlessProtocol.priceUnits(amount, scale, decimals)
        throw AssertionError("ожидалась ошибка для $amount")
    } catch (e: IllegalArgumentException) {
        e.message!!
    }

    @Test
    fun notDivisibleMessageNamesAmountAndStep() {
        val msg = priceError("0.12", 5)
        assertTrue(msg, msg.contains("0.12 €"))
        assertTrue(msg, msg.contains("шаг терминала 0.05 €"))
        assertTrue(msg, msg.contains("масштаб 5, знаков 2"))
    }

    @Test
    fun outOfRangeMessageNamesUnitsAndMaximum() {
        val msg = priceError("700", 1)
        assertTrue(msg, msg.contains("70000 ед."))
        assertTrue(msg, msg.contains("0..65535"))
        assertTrue(msg, msg.contains("максимум 655.35 €"))
    }

    @Test
    fun scaleWithInfiniteFractionGivesReadableErrorNotArithmeticException() {
        // Прежний BigDecimal.divide бросал здесь ArithmeticException.
        assertEquals(10, MdbCashlessProtocol.priceUnits("0.30", 3, 2))
        val msg = priceError("0.10", 3)
        assertTrue(msg, msg.contains("шаг терминала 0.03 €"))
    }

    @Test
    fun amountInputIsChecked() {
        for (s in listOf("", " ", "1e3", "0.1.0", "12345678", "1,2,3")) {
            assertTrue(s, priceError(s, 1).contains("числом вида 0.10"))
        }
    }

    @Test
    fun formatAmountIsInverseOfPriceUnits() {
        assertEquals("0.10", MdbCashlessProtocol.formatAmount(10, 1, 2))
        assertEquals("0.10", MdbCashlessProtocol.formatAmount(2, 5, 2))
        assertEquals("655.35", MdbCashlessProtocol.formatAmount(65535, 1, 2))
        assertEquals("5.00", MdbCashlessProtocol.formatAmount(5, 1, 0))
        assertEquals("0.010", MdbCashlessProtocol.formatAmount(10, 1, 3))
    }

    @Test
    fun vendSuccessOtherItemAndRequestBounds() {
        assertArrayEquals(hex("13 02 00 02"), MdbCashlessProtocol.vendSuccess(2))
        assertArrayEquals(hex("13 00 FF FF 01 00"), MdbCashlessProtocol.vendRequest(0xFFFF, 0x100))
    }
}
