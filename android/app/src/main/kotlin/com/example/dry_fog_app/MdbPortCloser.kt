package com.example.dry_fog_app

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

// Закрытие порта стенда MDB вне вызывающего потока (1.10.9+45). closePort
// вызывается и с главного потока (USB_DEVICE_DETACHED в BroadcastReceiver,
// onDestroy), а закрытие USB и ожидание потока чтения там подвешивали бы UI.
// Всё делается на одном фоновом потоке по очереди, ожидание потока чтения —
// не дольше JOIN_TIMEOUT_MS. Без Android-зависимостей, проверяется JVM-тестами.
class MdbPortCloser(
    private val joinTimeoutMs: Long = JOIN_TIMEOUT_MS,
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "mdb-bench-closer").apply { isDaemon = true }
    },
) {
    // Останавливает чтение (stop — флаг цикла MdbFrameReader, выход за один
    // таймаут чтения ~20 мс), закрывает порт (прерывает блокирующий read),
    // ждёт поток чтения. Результат future и onDone: true — поток чтения
    // остановлен.
    fun close(
        stop: () -> Unit,
        closePort: () -> Unit,
        reader: Thread?,
        onDone: (stopped: Boolean) -> Unit = {},
    ): Future<Boolean> =
        executor.submit<Boolean> { waitStopped(stop, closePort, reader).also(onDone) }

    // Ожидание потока чтения в сумме не дольше joinTimeoutMs.
    private fun waitStopped(stop: () -> Unit, closePort: () -> Unit, reader: Thread?): Boolean {
        stop()
        try {
            closePort()
        } catch (e: Exception) {
            // Адаптер уже выдернут — закрывать нечего.
        }
        if (reader == null || reader === Thread.currentThread()) return true
        val interruptMs = minOf(INTERRUPT_JOIN_MS, joinTimeoutMs / 2)
        reader.join(joinTimeoutMs - interruptMs)
        if (reader.isAlive) {
            // Последнее средство: прерывание снимает ожидание, если read на
            // него реагирует. Поток — демон, процесс он не держит.
            reader.interrupt()
            reader.join(interruptMs)
        }
        return !reader.isAlive
    }

    // Дождаться уже поставленных закрытий (перед новым открытием того же
    // устройства). Вызывать только НЕ с главного потока.
    fun drain(timeoutMs: Long = joinTimeoutMs + 1000) {
        executor.submit {}.get(timeoutMs, TimeUnit.MILLISECONDS)
    }

    // Поставленные закрытия доработают, новые не принимаются.
    fun shutdown() = executor.shutdown()

    companion object {
        const val JOIN_TIMEOUT_MS = 1000L
        const val INTERRUPT_JOIN_MS = 200L
    }
}
