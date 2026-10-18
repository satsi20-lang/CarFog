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

    @Test
    fun setupReplyFromManual() {
        val r = MdbCashlessProtocol.parseSetupReply("010109720102070D94")!!
        assertEquals(1, r.level)
        assertEquals(0x0972, r.country)
        assertEquals(1, r.scale)
        assertEquals(2, r.decimals)
        assertEquals(7, r.maxResponseSec)
        assertEquals(0x0D, r.options)
        assertEquals(true, r.checksumOk)
    }

    @Test
    fun checksumIsSumOfPreviousBytes() {
        val data = hex("010109720102070D94")
        assertEquals(0x94, MdbCashlessProtocol.checksum(data, 0, data.size - 1))
        assertTrue(MdbCashlessProtocol.hasValidChecksum(data))
        assertEquals(false, MdbCashlessProtocol.parseSetupReply("010109720102070D95")!!.checksumOk)
        assertNull(MdbCashlessProtocol.parseSetupReply("010109720102070D")!!.checksumOk)
    }

    @Test
    fun setupReplyRejectsOtherMessages() {
        assertNull(MdbCashlessProtocol.parseSetupReply("03FFFE"))
        assertNull(MdbCashlessProtocol.parseSetupReply("0101"))
        assertNull(MdbCashlessProtocol.parseSetupReply("zz"))
        // масштаб 0 — не подменяем, а не разбираем
        assertNull(MdbCashlessProtocol.parseSetupReply("0101097200020700"))
    }

    @Test
    fun badHexInput() {
        for (s in listOf("", "1", "14 0", "GG", "14-01")) {
            try {
                MdbCashlessProtocol.parseHex(s)
                throw AssertionError("ожидалась ошибка для \"$s\"")
            } catch (e: IllegalArgumentException) {
                // ожидаемо
            }
        }
        assertArrayEquals(byteArrayOf(0x14, 0x01), MdbCashlessProtocol.parseHex(" 14 01\n"))
        assertArrayEquals(byteArrayOf(0x0a), MdbCashlessProtocol.parseHex("0a"))
    }

    @Test
    fun knownEvents() {
        assertEquals(Event.BeginSession(0xFFFE, null), MdbCashlessProtocol.parseEvent("03FFFE"))
        assertEquals(Event.VendApproved(10, null), MdbCashlessProtocol.parseEvent("05000A"))
        assertEquals(Event.EndSession(null), MdbCashlessProtocol.parseEvent("07"))
        assertEquals(Event.VendDenied(null), MdbCashlessProtocol.parseEvent("06"))
        assertEquals(Event.Cancelled(null), MdbCashlessProtocol.parseEvent("08"))
        // с контрольной суммой
        assertEquals(Event.EndSession(true), MdbCashlessProtocol.parseEvent("0707"))
        assertEquals(Event.VendApproved(10, true), MdbCashlessProtocol.parseEvent("05000A0F"))
    }

    @Test
    fun unknownOrMalformedEventsAreNotGuessed() {
        for (s in listOf("00", "04", "0A", "03FF", "07 08", "05000A00", "xyz", "")) {
            assertTrue(s, MdbCashlessProtocol.parseEvent(s) is Event.Unrecognized)
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

    @Test
    fun eventsWithChecksum() {
        assertEquals(Event.BeginSession(0xFFFE, true), MdbCashlessProtocol.parseEvent("03FFFE00"))
        assertEquals(Event.VendDenied(true), MdbCashlessProtocol.parseEvent("0606"))
        assertEquals(Event.Cancelled(true), MdbCashlessProtocol.parseEvent("0808"))
        // неверная контрольная сумма — не догадываемся
        assertTrue(MdbCashlessProtocol.parseEvent("03FFFE01") is Event.Unrecognized)
    }
}
