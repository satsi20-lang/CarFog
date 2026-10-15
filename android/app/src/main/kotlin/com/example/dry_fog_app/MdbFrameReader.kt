package com.example.dry_fog_app

import java.io.ByteArrayOutputStream
import java.io.IOException

// Обёртка над USB-портом стенда MDB — только чтение с таймаутом. Нужна,
// чтобы цикл чтения проверялся JVM-тестами на имитации порта.
fun interface MdbBytePort {
    // Возвращает число прочитанных байтов (0 — таймаут). При потере порта
    // (закрыт, адаптер выдернут) бросает IOException.
    @Throws(IOException::class)
    fun read(buf: ByteArray, timeoutMs: Int): Int
}

// Цикл чтения стенда MDB (1.10.9). Адаптер Wafer присылает ответы текстом
// без разделителей, поэтому конец сообщения — пауза GAP_MS без новых
// байтов (как в mdb_test.py v2). Два события, пришедшие подряд быстрее
// паузы, склеятся в одно сообщение — поэтому в журнале видно время
// первого и последнего байта.
class MdbFrameReader(
    private val port: MdbBytePort,
    private val onFrame: (data: ByteArray, firstMs: Long, lastMs: Long) -> Unit,
    // Вызывается один раз, если чтение оборвалось с ошибкой (не при штатной
    // остановке через stop()).
    private val onError: (IOException) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val gapMs: Long = GAP_MS,
    private val readTimeoutMs: Int = READ_TIMEOUT_MS,
) {
    @Volatile
    private var running = true

    fun stop() {
        running = false
    }

    fun run() {
        // Не меньше размера пакета USB (64 байта) — требование usb-serial-for-android.
        val buf = ByteArray(1024)
        val frame = ByteArrayOutputStream()
        var first = 0L
        var last = 0L
        fun flush() {
            if (frame.size() > 0) {
                onFrame(frame.toByteArray(), first, last)
                frame.reset()
            }
        }
        while (running) {
            val n = try {
                port.read(buf, readTimeoutMs)
            } catch (e: IOException) {
                // Принятое до обрыва не теряем.
                flush()
                if (running) onError(e)
                return
            }
            val now = clock()
            if (n > 0) {
                if (frame.size() == 0) first = now
                frame.write(buf, 0, n)
                last = now
            } else if (frame.size() > 0 && now - last >= gapMs) {
                flush()
            }
        }
        flush()
    }

    companion object {
        const val GAP_MS = 60L
        const val READ_TIMEOUT_MS = 20
    }
}
