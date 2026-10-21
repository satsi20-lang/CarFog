package com.example.dry_fog_app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MdbPortCloserTest {

    @Test
    fun callerIsNotBlockedBySlowClose() {
        // Закрытие USB «висит» 300 мс — вызывающий (главный) поток не ждёт.
        val closer = MdbPortCloser()
        val started = System.nanoTime()
        val future = closer.close(stop = {}, closePort = { Thread.sleep(300) }, reader = null)
        val callerMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("вызов занял $callerMs мс", callerMs < 100)
        assertTrue(future.get(2, TimeUnit.SECONDS))
        closer.shutdown()
    }

    @Test
    fun realReaderStopsWellWithinTimeout() {
        // Настоящий цикл чтения на порте, который просто отдаёт таймауты.
        val reader = MdbFrameReader(
            port = { _, t -> Thread.sleep(t.toLong()); 0 },
            onFrame = { _, _, _ -> },
            onError = { throw AssertionError("ошибки быть не должно") },
        )
        val t = Thread(reader::run).apply { isDaemon = true; start() }
        val closer = MdbPortCloser()
        val started = System.nanoTime()
        val stopped = closer.close(stop = reader::stop, closePort = {}, reader = t)
            .get(2, TimeUnit.SECONDS)
        val ms = (System.nanoTime() - started) / 1_000_000
        assertTrue(stopped)
        assertFalse(t.isAlive)
        assertTrue("остановка заняла $ms мс", ms < 500)
        closer.shutdown()
    }

    @Test
    fun closingPortUnblocksReadAndStopsReader() {
        // read блокирован до закрытия порта (как usb-serial): close() снимает
        // блокировку исключением, штатная остановка не считается ошибкой.
        val portClosed = CountDownLatch(1)
        val errors = mutableListOf<IOException>()
        val reader = MdbFrameReader(
            port = { _, _ -> portClosed.await(); throw IOException("порт закрыт") },
            onFrame = { _, _, _ -> },
            onError = { errors += it },
        )
        val t = Thread(reader::run).apply { isDaemon = true; start() }
        val closer = MdbPortCloser()
        assertTrue(
            closer.close(stop = reader::stop, closePort = { portClosed.countDown() }, reader = t)
                .get(2, TimeUnit.SECONDS)
        )
        assertTrue(errors.isEmpty())
        closer.shutdown()
    }

    @Test
    fun stuckReaderIsGivenUpAfterOneSecondTotal() {
        // Поток, который не реагирует ни на stop, ни на прерывание: ожидание
        // ограничено 1 с в сумме, результат false, закрывальщик не виснет.
        val release = CountDownLatch(1)
        val stuck = Thread {
            while (release.count > 0) {
                try { release.await() } catch (e: InterruptedException) { /* игнорирует */ }
            }
        }.apply { isDaemon = true; start() }
        val closer = MdbPortCloser()
        val started = System.nanoTime()
        val stopped = closer.close(stop = {}, closePort = {}, reader = stuck)
            .get(3, TimeUnit.SECONDS)
        val ms = (System.nanoTime() - started) / 1_000_000
        assertFalse(stopped)
        assertTrue("ожидание $ms мс", ms in 900..1400)
        release.countDown()
        closer.shutdown()
    }

    @Test
    fun drainWaitsForQueuedCloses() {
        val closer = MdbPortCloser()
        val order = mutableListOf<String>()
        closer.close(stop = {}, closePort = { Thread.sleep(200); synchronized(order) { order += "закрыт" } }, reader = null)
        closer.drain()
        synchronized(order) { order += "открытие" }
        assertEquals(listOf("закрыт", "открытие"), order)
        closer.shutdown()
    }
}
