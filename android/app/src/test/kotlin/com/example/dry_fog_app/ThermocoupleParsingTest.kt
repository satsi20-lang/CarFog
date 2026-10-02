package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Test

// Термопара HLS-KWL-4TC отдаёт регистр как знаковое 16-бит значение
// (десятые доли градуса), а readHoldingRegisters возвращает его как
// беззнаковое 0..65535 — ModbusChannel.parseThermocoupleRaw() обязан
// привести через toShort() перед делением, иначе отрицательная
// температура превращается в бессмысленное большое положительное число
// (задача "контроль цикла по электросчётчику, температурный режим,
// готовность оплаты").
class ThermocoupleParsingTest {

    @Test
    fun `отрицательная температура читается со знаком`() {
        // 0xFFB4 = 65460 беззнаковое; как знаковое int16 — минус 76,
        // то есть минус 7,6 градуса.
        val result = ModbusChannel.parseThermocoupleRaw(0xFFB4)
        assertEquals(-7.6, result, 0.0001)
    }

    @Test
    fun `положительная температура не искажается приведением`() {
        // 0x0929 = 2345 — заведомо в пределах Short, приведение не должно
        // ничего менять для обычных положительных значений.
        val result = ModbusChannel.parseThermocoupleRaw(0x0929)
        assertEquals(234.5, result, 0.0001)
    }

    @Test
    fun `ноль читается как ноль`() {
        val result = ModbusChannel.parseThermocoupleRaw(0x0000)
        assertEquals(0.0, result, 0.0001)
    }

    @Test
    fun `граница знакового бита — минус один градус`() {
        // 0xFFF6 = 65526 беззнаковое = -10 как int16 = -1.0°C.
        val result = ModbusChannel.parseThermocoupleRaw(0xFFF6)
        assertEquals(-1.0, result, 0.0001)
    }
}
