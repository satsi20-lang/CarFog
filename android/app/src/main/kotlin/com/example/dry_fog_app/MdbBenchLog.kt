package com.example.dry_fog_app

import java.io.File
import java.io.FileWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

// Журнал обмена стенда MDB (1.10.9): кольцевой буфер в памяти + дозапись
// тех же строк в файл (mdb_bench.log во внешней папке приложения, чтобы
// забрать по adb pull). В облако не уходит. Без Android-зависимостей.
class MdbBenchLog(
    private val file: File?,
    private val capacity: Int = CAPACITY,
    private val maxFileBytes: Long = MAX_FILE_BYTES,
) {
    data class Entry(val seq: Long, val line: String)

    private val entries = ArrayDeque<Entry>()
    private var nextSeq = 1L
    private val timeFmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.ROOT)

    @Synchronized
    fun add(line: String): Entry {
        val e = Entry(nextSeq++, line)
        entries.addLast(e)
        while (entries.size > capacity) entries.removeFirst()
        appendToFile(line)
        return e
    }

    @Synchronized
    fun since(seq: Long): List<Entry> = entries.filter { it.seq > seq }

    @Synchronized
    fun all(): List<Entry> = entries.toList()

    // Чистит только экран (буфер в памяти); файл остаётся как был.
    @Synchronized
    fun clear() = entries.clear()

    fun time(ms: Long): String = synchronized(timeFmt) { timeFmt.format(Date(ms)) }

    fun info(ms: Long, text: String) = add("${time(ms)} ** $text")

    fun tx(ms: Long, data: ByteArray, label: String) = add(
        "${time(ms)} -> hex: ${MdbCashlessProtocol.toHex(data)} | ascii: ${printable(data)}" +
            " | байты: ${MdbCashlessProtocol.toHex(data)} | $label"
    )

    // Адаптер присылает текст из hex-символов: hex — это расшифровка текста
    // (если он hex), ascii — сам текст, байты — что пришло по проводу.
    fun rx(firstMs: Long, lastMs: Long, data: ByteArray, note: String) {
        val text = String(data, Charsets.US_ASCII)
        val decoded = try {
            MdbCashlessProtocol.toHex(MdbCashlessProtocol.parseHex(text))
        } catch (e: IllegalArgumentException) {
            "— (не hex)"
        }
        add(
            "${time(lastMs)} <- hex: $decoded | ascii: ${printable(data)}" +
                " | байты: ${MdbCashlessProtocol.toHex(data)}" +
                " | первый байт ${time(firstMs)}, +${lastMs - firstMs} мс | $note"
        )
    }

    private fun appendToFile(line: String) {
        val f = file ?: return
        try {
            if (f.length() > maxFileBytes) {
                val old = File(f.path + ".1")
                old.delete()
                f.renameTo(old)
            }
            FileWriter(f, true).use { it.write(line + "\n") }
        } catch (e: Exception) {
            // Файл — дополнение к журналу в памяти; его отказ стенд не останавливает.
        }
    }

    companion object {
        const val CAPACITY = 2000
        const val MAX_FILE_BYTES = 5L * 1024 * 1024

        fun printable(data: ByteArray): String =
            data.joinToString("") { b ->
                val c = b.toInt() and 0xFF
                if (c in 0x20..0x7E) c.toChar().toString() else "."
            }
    }
}
