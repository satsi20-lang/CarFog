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

// Цикл чтения MDB (основной поток оплаты и стенд). Адаптер Wafer присылает
// кадры текстом, кадр кончается \r\n (подтверждено на железе: журналы
// 21.10.2026 — все ответы, включая ACK «00 \r\n» и отказ «FF \r\n»). Конец
// кадра — \n (сразу, даже если два кадра пришли одним USB-пакетом). Пауза
// GAP_MS без новых байтов — только аварийное закрытие кадра без \r\n
// («обрывок»). Пустые строки (только \r, \n, пробелы) не отдаются.
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
    // Кадр из одних \r, \n и пробелов не отдавать (1.11.5): хвост «\r\n»
    // строки, разрезанной паузой, — не событие.
    private val skipBlank: Boolean = true,
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
                val data = frame.toByteArray()
                frame.reset()
                if (!(skipBlank && isBlank(data))) onFrame(data, first, last)
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
        // Аварийная пауза (1.11.5; было 60 мс). 60 мс резали ответ setup на
        // куски (разброс байтов строки до 33 мс в журнале, иногда больше) —
        // обрывок не принимался за ответ, через 2 с таймаут и переоткрытие
        // порта (~раз в 30 мин). 500 мс < таймаута ответа 2 с; ответы с \r\n
        // закрываются сразу и паузу не ждут.
        const val GAP_MS = 500L

        fun isBlank(data: ByteArray): Boolean =
            data.all { it == CR || it == LF || it == SPACE }

        // Кадр закрыт \n, а не паузой.
        fun isComplete(data: ByteArray): Boolean = data.isNotEmpty() && data.last() == LF

        private const val CR: Byte = 0x0D
        private const val SPACE: Byte = 0x20
        const val READ_TIMEOUT_MS = 20
        private const val LF: Byte = 0x0A
    }
}
