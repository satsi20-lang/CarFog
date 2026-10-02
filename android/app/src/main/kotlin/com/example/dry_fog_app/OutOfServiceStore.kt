package com.example.dry_fog_app

import android.util.Log
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.util.zip.CRC32

// Долговременное хранилище признака "аппарат выведен из обслуживания"
// (задача "вывод аппарата из обслуживания"). Пережить обязано и
// перезапуск приложения, и пропадание питания — иначе скачок напряжения
// снимал бы блокировку, и аппарат снова брал бы деньги при сгоревшем
// предохранителе ТЭНа.
//
// Почему не SharedPreferences: apply() пишет на диск асинхронно (окно
// потери именно в тот момент, когда питание пропадает), а XML-файл с
// испорченным содержимым Android молча читает как ПУСТОЙ — это выглядело
// бы как "чистое первое включение", то есть fail-open. Здесь свой файл:
//   1. тело пишется во временный файл, fsync;
//   2. rename поверх основного (атомарный на ext4/f2fs — на диске всегда
//      либо старая запись целиком, либо новая целиком);
//   3. fsync каталога, чтобы сам rename пережил обрыв питания.
// Формат файла: "<crc32 hex>\n<json>" — по контрольной сумме отличаем
// повреждённую запись (fail-closed при старте) от отсутствующей (чистое
// первое включение — рабочее состояние, не ошибка).
//
// dir передаётся снаружи (filesDir приложения), а не берётся из Context —
// чтобы класс проверялся обычным JVM unit-тестом без Android.
class OutOfServiceStore(
    private val dir: File,
    // Проверка, что содержимое — разбираемый JSON, и журнал. По умолчанию
    // настоящие org.json/Log; в JVM-тесте подставляются простые лямбды
    // (заглушки android.jar там не работают как настоящие).
    private val isValidJson: (String) -> Boolean = {
        try {
            JSONObject(it)
            true
        } catch (e: Exception) {
            false
        }
    },
    private val log: (String) -> Unit = { Log.e(TAG, it) },
) {

    enum class Status { NONE, OK, CORRUPT }

    data class ReadResult(val status: Status, val json: String?)

    private val main get() = File(dir, FILE_NAME)
    private val tmp get() = File(dir, TMP_NAME)

    // Синхронная запись: возвращает true только когда данные и переименование
    // подтверждены fsync. Любая ошибка — false (вызывающий код повторяет, но
    // блокирует аппарат в памяти независимо от результата).
    fun write(json: String): Boolean {
        return try {
            val payload = json.toByteArray(Charsets.UTF_8)
            val body = (checksum(payload) + "\n").toByteArray(Charsets.UTF_8) + payload
            FileOutputStream(tmp).use { out ->
                out.write(body)
                out.flush()
                out.fd.sync()
            }
            if (!tmp.renameTo(main)) {
                log("rename не удался")
                return false
            }
            syncDir()
            true
        } catch (e: Throwable) {
            log("write не удался: $e")
            false
        }
    }

    // NONE — записи нет совсем (чистое первое включение). OK — запись цела.
    // CORRUPT — запись есть, но не читается/не сходится контрольная сумма/не
    // разбирается JSON, либо найден недописанный временный файл без
    // основного (оборвали питание посреди записи самого вывода из
    // обслуживания — безопаснее считать аппарат выведенным).
    fun read(): ReadResult {
        return try {
            val f = main
            if (!f.exists()) {
                // Недописанная запись при отсутствующем основном файле — нельзя
                // считать это чистым стартом.
                return if (tmp.exists()) ReadResult(Status.CORRUPT, null)
                else ReadResult(Status.NONE, null)
            }
            val bytes = f.readBytes()
            val nl = bytes.indexOf('\n'.code.toByte())
            if (nl <= 0) return ReadResult(Status.CORRUPT, null)
            val crcHex = String(bytes, 0, nl, Charsets.UTF_8)
            val payload = bytes.copyOfRange(nl + 1, bytes.size)
            if (checksum(payload) != crcHex) return ReadResult(Status.CORRUPT, null)
            val json = String(payload, Charsets.UTF_8)
            if (!isValidJson(json)) return ReadResult(Status.CORRUPT, null)
            // Основной цел, а рядом лежит недописанный временный (обновляли
            // запись и оборвали) — основной остаётся валидным, мусор убираем.
            if (tmp.exists()) tmp.delete()
            ReadResult(Status.OK, json)
        } catch (e: Throwable) {
            log("read не удался: $e")
            ReadResult(Status.CORRUPT, null)
        }
    }

    // Снятие блокировки. true — файла после операции действительно нет.
    fun clear(): Boolean {
        return try {
            val f = main
            if (f.exists()) f.delete()
            if (tmp.exists()) tmp.delete()
            syncDir()
            !f.exists() && !tmp.exists()
        } catch (e: Throwable) {
            log("clear не удался: $e")
            false
        }
    }

    // fsync каталога — чтобы rename/delete пережили обрыв питания. На
    // старых/нестандартных файловых системах может быть недоступен — это
    // best-effort поверх уже подтверждённого fsync файла.
    private fun syncDir() {
        try {
            val fd = android.system.Os.open(dir.absolutePath, android.system.OsConstants.O_RDONLY, 0)
            try {
                android.system.Os.fsync(fd)
            } finally {
                android.system.Os.close(fd)
            }
        } catch (e: Throwable) {
            log("fsync каталога недоступен: $e")
        }
    }

    companion object {
        private const val TAG = "OutOfServiceStore"
        const val FILE_NAME = "out_of_service.state"
        const val TMP_NAME = "out_of_service.state.tmp"

        fun checksum(payload: ByteArray): String {
            val c = CRC32()
            c.update(payload)
            return java.lang.Long.toHexString(c.value)
        }
    }
}
