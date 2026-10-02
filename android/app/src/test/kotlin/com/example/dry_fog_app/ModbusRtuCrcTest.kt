package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Контрольные кадры CWT-BK-1616T-S (задача "смена Slave ID") — проверяют
// CRC16 Modbus (init 0xFFFF, poly 0xA001, сдвиг вправо, в кадр уходит
// сначала младший байт, потом старший) на реальных, заранее посчитанных
// кадрах устройства, а не только на абстрактных числах. Локальные JVM-тесты
// (src/test) — не требуют эмулятора/планшета, запускаются обычным
// `./gradlew testDebugUnitTest`.
class ModbusRtuCrcTest {
    private val modbus = ModbusRtu()

    // Считает CRC по кадру БЕЗ двух последних байт и возвращает его в том
    // же порядке, в каком он уходит в эфир (младший байт первым) — тем же
    // форматом "XX XX", что и в контрольной таблице, для удобного сравнения.
    private fun crcOf(frameWithoutCrcHex: String): String {
        val bytes = frameWithoutCrcHex
            .trim()
            .split(Regex("\\s+"))
            .map { it.toInt(16).toByte() }
            .toByteArray()
        val crc = modbus.calcCrc(bytes)
        val lo = crc and 0xFF
        val hi = (crc shr 8) and 0xFF
        return "%02X %02X".format(lo, hi)
    }

    @Test
    fun `чтение ID с адреса 1`() {
        assertEquals("84 0A", crcOf("01 03 00 00 00 01"))
    }

    @Test
    fun `запись ID=5 на адрес 1`() {
        assertEquals("49 C9", crcOf("01 06 00 00 00 05"))
    }

    @Test
    fun `сохранение на адресе 1`() {
        assertEquals("19 E4", crcOf("01 06 00 09 00 6F"))
    }

    @Test
    fun `сохранение на адресе 5`() {
        assertEquals("18 60", crcOf("05 06 00 09 00 6F"))
    }

    @Test
    fun `чтение ID с адреса 5`() {
        assertEquals("85 8E", crcOf("05 03 00 00 00 01"))
    }

    @Test
    fun `чтение скорости с адреса 5`() {
        assertEquals("24 4E", crcOf("05 03 00 02 00 01"))
    }

    @Test
    fun `чтение всех DI, адрес 5`() {
        assertEquals("78 42", crcOf("05 02 00 00 00 10"))
    }

    @Test
    fun `чтение всех DO, адрес 5`() {
        assertEquals("3C 42", crcOf("05 01 00 00 00 10"))
    }

    @Test
    fun `DO0 включить, адрес 5`() {
        assertEquals("8D BE", crcOf("05 05 00 00 FF 00"))
    }

    @Test
    fun `DO0 выключить, адрес 5`() {
        assertEquals("CC 4E", crcOf("05 05 00 00 00 00"))
    }

    @Test
    fun `DO9 ТЭН включить, адрес 5`() {
        assertEquals("5D BC", crcOf("05 05 00 09 FF 00"))
    }

    // Ответ с неверной контрольной суммой должен ЦЕЛИКОМ отбрасываться —
    // не разбираться частично. checkCrc — ровно та проверка, на которой
    // это решение принимается выше по стеку (sendAndReceive/scanTransact).
    @Test
    fun `битый CRC отбрасывается целиком, не разбирается частично`() {
        val good = "01 03 00 00 00 01 84 0A"
            .split(" ")
            .map { it.toInt(16).toByte() }
            .toByteArray()
        assertTrue(modbus.checkCrc(good))

        val corrupted = good.copyOf()
        corrupted[corrupted.size - 1] = (corrupted[corrupted.size - 1] + 1).toByte()
        assertFalse(modbus.checkCrc(corrupted))
    }
}
