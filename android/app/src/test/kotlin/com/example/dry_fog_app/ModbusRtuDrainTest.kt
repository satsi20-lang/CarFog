package com.example.dry_fog_app

import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertEquals
import org.junit.Test

// Запоздавший ответ на предыдущий запрос не должен дожить до следующей
// транзакции: перед каждым запросом входной буфер выбрасывается.
class ModbusRtuDrainTest {
    private val modbus = ModbusRtu()

    @Test
    fun `drops everything already buffered`() {
        val inp = ByteArrayInputStream(ByteArray(13) { it.toByte() })
        assertEquals(13, modbus.drainInput(inp))
        assertEquals(0, inp.available())
    }

    @Test
    fun `empty buffer drops nothing`() {
        assertEquals(0, modbus.drainInput(ByteArrayInputStream(ByteArray(0))))
    }

    @Test
    fun `stream that cannot skip is read instead`() {
        val inp = object : InputStream() {
            var left = 7
            override fun available() = left
            override fun skip(n: Long) = 0L
            override fun read() = if (left > 0) { left--; 1 } else -1
            override fun read(b: ByteArray): Int {
                val n = minOf(left, b.size); left -= n; return n
            }
        }
        assertEquals(7, modbus.drainInput(inp))
    }

    @Test
    fun `io error does not break the request`() {
        val inp = object : InputStream() {
            override fun available(): Int = throw IOException("gone")
            override fun read() = -1
        }
        assertEquals(0, modbus.drainInput(inp))
    }
}
