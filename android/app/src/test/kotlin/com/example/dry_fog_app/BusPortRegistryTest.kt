package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

// Владение портом на уровне процесса и сторож шины (задача "устойчивость
// шины", 1.10.3). Настоящий ModbusRtu требует tty и stty — здесь подделка с
// той же семантикой блокировки: второй объект на занятый порт получает
// Busy (как OverlappingFileLockException в ModbusRtu.open, см.
// ModbusRtuPortLockTest).
class BusPortRegistryTest {

    private class FakeBus(private val locks: MutableSet<String>) : SerialBus {
        var port: String? = null
        var opens = 0
        var reopens = 0
        var closes = 0
        var failReopen = false
        override var transactionListener: ((Boolean) -> Unit)? = null

        override fun open(port: String, baud: Int, parity: String): ModbusRtu.OpenResult {
            if (!locks.add(port)) return ModbusRtu.OpenResult.Busy(4242)
            this.port = port
            opens++
            return ModbusRtu.OpenResult.Ok
        }

        override fun reopen(port: String, baud: Int, parity: String, pauseMs: Long): ModbusRtu.OpenResult {
            reopens++
            close()
            return if (failReopen) ModbusRtu.OpenResult.Failed else open(port, baud, parity)
        }

        override fun close() {
            port?.let { locks.remove(it) }
            port = null
            closes++
        }

        override fun isOpen() = port != null

        fun transaction(ok: Boolean) = transactionListener?.invoke(ok)
    }

    private val locks = mutableSetOf<String>()
    private val created = mutableListOf<FakeBus>()
    private var now = 0L
    private val registry = BusPortRegistry(
        factory = { FakeBus(locks).also { created += it } },
        clock = { now },
        wallClock = { now },
        log = {},
    )
    private val engineA = Any()
    private val engineB = Any()
    private val port = "/dev/ttyS4"

    @Test
    fun `причина инцидента - второй объект на тот же порт в том же процессе получает Busy`() {
        val first = FakeBus(locks)
        val second = FakeBus(locks)
        assertEquals(ModbusRtu.OpenResult.Ok, first.open(port, 9600, "none"))
        assertTrue(second.open(port, 9600, "none") is ModbusRtu.OpenResult.Busy)
    }

    @Test
    fun `повторное открытие тем же владельцем идемпотентно`() {
        assertEquals(ModbusRtu.OpenResult.Ok, registry.open(engineA, port, 9600))
        assertEquals(ModbusRtu.OpenResult.Ok, registry.open(engineA, port, 9600))
        assertEquals(1, created.size)
        assertEquals(1, created[0].opens)
        assertEquals(0, created[0].closes)
    }

    @Test
    fun `второй движок того же процесса переиспользует открытый порт, а не получает Busy`() {
        registry.open(engineA, port, 9600)
        val result = registry.open(engineB, port, 9600)

        assertEquals(ModbusRtu.OpenResult.Ok, result)
        assertEquals("порт не пересоздаётся", 1, created.size)
        assertSame(created[0], registry.busFor(engineB))
        assertNull("прежний движок больше не командует шиной", registry.busFor(engineA))
        assertSame(created[0], registry.current)
    }

    @Test
    fun `release прежнего владельца не закрывает порт и не гасит выходы под новым`() {
        registry.open(engineA, port, 9600)
        registry.open(engineB, port, 9600)
        var allOffCalls = 0

        assertFalse(registry.release(engineA) { allOffCalls++ })
        assertEquals(0, allOffCalls)
        assertTrue(created[0].isOpen())

        assertTrue(registry.release(engineB) { allOffCalls++ })
        assertEquals("владелец при уничтожении гасит выходы как раньше", 1, allOffCalls)
        assertFalse(created[0].isOpen())
        assertNull(registry.current)
    }

    @Test
    fun `после release владельца новый движок открывает порт заново`() {
        registry.open(engineA, port, 9600)
        registry.release(engineA) {}
        assertEquals(ModbusRtu.OpenResult.Ok, registry.open(engineB, port, 9600))
        assertEquals(2, created.size)
    }

    @Test
    fun `явное закрытие - только владельцем`() {
        registry.open(engineA, port, 9600)
        registry.open(engineB, port, 9600)
        assertFalse(registry.close(engineA))
        assertTrue(created[0].isOpen())
        assertTrue(registry.close(engineB))
        assertFalse(created[0].isOpen())
    }

    @Test
    fun `другая чётность закрывает прежний объект и открывает новый`() {
        registry.open(engineA, port, 9600)
        assertEquals(ModbusRtu.OpenResult.Ok, registry.open(engineA, port, 9600, "odd"))
        assertEquals(2, created.size)
        assertFalse(created[0].isOpen())
        assertTrue(created[1].isOpen())
    }

    @Test
    fun `10 ошибок подряд - переоткрытие, событие для журнала`() {
        registry.open(engineA, port, 9600)
        val bus = created[0]
        repeat(9) { bus.transaction(false) }
        assertEquals(0, bus.reopens)
        bus.transaction(false)
        assertEquals(1, bus.reopens)
        assertTrue("тот же объект снова открыт", bus.isOpen())
        assertSame(bus, registry.busFor(engineA))

        val health = registry.health(engineA)
        assertEquals(1, health["reopens"])
        @Suppress("UNCHECKED_CAST")
        val events = health["events"] as List<Map<String, Any?>>
        assertEquals(1, events.size)
        assertEquals(true, events[0]["ok"])
        assertEquals(port, events[0]["port"])
        @Suppress("UNCHECKED_CAST")
        assertTrue("события забираются один раз", (registry.health(engineA)["events"] as List<Any>).isEmpty())
    }

    @Test
    fun `успешный ответ сбрасывает серию`() {
        registry.open(engineA, port, 9600)
        val bus = created[0]
        repeat(9) { bus.transaction(false) }
        bus.transaction(true)
        repeat(9) { bus.transaction(false) }
        assertEquals(0, bus.reopens)
        assertEquals(1L, registry.health(engineA)["successes"])
    }

    @Test
    fun `не больше 3 переоткрытий за минуту, потом снова можно`() {
        registry.open(engineA, port, 9600)
        val bus = created[0]
        bus.failReopen = true
        repeat(100) {
            bus.transaction(false)
            now += 100
        }
        assertEquals(3, bus.reopens)
        now += 60_000
        repeat(10) { bus.transaction(false) }
        assertEquals(4, bus.reopens)
    }

    @Test
    fun `неудачное переоткрытие - порт закрыт, сторож продолжает попытки`() {
        registry.open(engineA, port, 9600)
        val bus = created[0]
        bus.failReopen = true
        repeat(10) { bus.transaction(false) }
        assertFalse(bus.isOpen())
        val health = registry.health(engineA)
        assertEquals(false, health["open"])
        assertEquals(true, health["desired"])
        @Suppress("UNCHECKED_CAST")
        assertEquals(false, (health["events"] as List<Map<String, Any?>>)[0]["ok"])

        bus.failReopen = false
        now += 60_000
        repeat(10) { bus.transaction(false) }
        assertTrue("восстановление: порт снова открыт", bus.isOpen())
    }

    @Test
    fun `диагностика с другой чётностью не переоткрывается`() {
        registry.open(engineA, port, 9600, "odd")
        val bus = created[0]
        repeat(30) { bus.transaction(false) }
        assertEquals(0, bus.reopens)
    }

    @Test
    fun `события не отдаются чужому движку`() {
        registry.open(engineA, port, 9600)
        repeat(10) { created[0].transaction(false) }
        val foreign = registry.health(engineB)
        assertEquals(false, foreign["owner"])
        @Suppress("UNCHECKED_CAST")
        assertTrue((foreign["events"] as List<Any>).isEmpty())
        @Suppress("UNCHECKED_CAST")
        assertEquals(1, (registry.health(engineA)["events"] as List<Any>).size)
    }

    @Test
    fun `транзакции старого объекта после замены не учитываются`() {
        registry.open(engineA, port, 9600)
        val old = created[0]
        registry.open(engineA, port, 9600, "odd")
        assertNull("слушатель снят при замене", old.transactionListener)
    }
}
