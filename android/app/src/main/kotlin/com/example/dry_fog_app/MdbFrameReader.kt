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

// Цикл чтения стенда MDB. Адаптер Wafer присылает кадры текстом, кадр
// кончается \r\n (подтверждено на железе, 1.10.11). Конец кадра — \n
// (сразу, даже если два кадра пришли одним USB-пакетом) либо, для кадра без
// \r\n, пауза GAP_MS без новых байтов. Паузы между кадрами на железе ~85 мс
// (пример: "00", затем "10 07") — больше GAP_MS, такие кадры не склеиваются.
// В журнале видно время первого и последнего байта кадра.
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
                // Пауза могла пройти внутри этого же чтения (таймаут чтения
                // не совпал с границей паузы) — старый кадр закрываем до
                // новых байтов.
                if (frame.size() > 0 && now - last >= gapMs) flush()
                for (i in 0 until n) {
                    if (frame.size() == 0) first = now
                    frame.write(buf[i].toInt())
                    last = now
                    if (buf[i] == LF) flush()
                }
            } else if (frame.size() > 0 && now - last >= gapMs) {
                flush()
            }
        }
        flush()
    }

    companion object {
        const val GAP_MS = 60L
        const val READ_TIMEOUT_MS = 20
        private const val LF: Byte = 0x0A
    }
}
