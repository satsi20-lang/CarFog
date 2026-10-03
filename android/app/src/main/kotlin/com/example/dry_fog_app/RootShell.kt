package com.example.dry_fog_app

import android.util.Log
import java.io.BufferedReader
import java.io.InputStreamReader
import java.util.concurrent.TimeUnit

// Выполнение команд от root через su (R2, удалённое обновление).
//
// su на этой прошивке (userdebug, Android 13) имеет форму `su [uid] [команда…]`,
// флаг -c НЕ поддерживается (проверено вживую: "invalid uid/gid '-c'"), поэтому
// команда запускается как `su 0 sh -c "<команда>"`.
// Всё привилегированное идёт только через этот объект: вызывающий код про
// root не знает (интерфейс PrivilegedInstaller на стороне Dart).
object RootShell {
    private const val TAG = "RootShell"

    class Result(val exitCode: Int, val output: String)

    // null — su не запустился или не уложился в таймаут.
    fun exec(command: String, timeoutMs: Long): Result? {
        return try {
            val p = ProcessBuilder("su", "0", "sh", "-c", command)
                .redirectErrorStream(true)
                .start()
            val out = StringBuilder()
            val reader = Thread {
                try {
                    BufferedReader(InputStreamReader(p.inputStream)).use { r ->
                        var line = r.readLine()
                        while (line != null) {
                            if (out.length < 8192) out.appendLine(line)
                            line = r.readLine()
                        }
                    }
                } catch (_: Throwable) {
                }
            }
            reader.isDaemon = true
            reader.start()
            if (!p.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                p.destroyForcibly()
                return null
            }
            reader.join(500)
            Result(p.exitValue(), out.toString())
        } catch (e: Throwable) {
            Log.w(TAG, "su недоступен: $e")
            null
        }
    }

    // root доступен, если su отвечает uid=0 за заданное время.
    fun isAvailable(timeoutMs: Long): Boolean {
        val r = exec("id -u", timeoutMs) ?: return false
        return r.exitCode == 0 && r.output.trim() == "0"
    }

    // Запуск скрипта, переживающего смерть приложения: nohup + setsid, ввод и
    // вывод отвязаны. Возвращает true, если запуск (но не работа скрипта!)
    // удался.
    fun runDetached(scriptPath: String, args: List<String>, timeoutMs: Long): Boolean {
        val quoted = (listOf(scriptPath) + args).joinToString(" ") { shQuote(it) }
        val r = exec(
            "nohup setsid sh $quoted > /dev/null 2>&1 < /dev/null &",
            timeoutMs
        ) ?: return false
        return r.exitCode == 0
    }

    // Безопасное цитирование аргумента для sh: в одинарных кавычках, внутри
    // одинарная кавычка заменяется на '\''.
    internal fun shQuote(s: String): String = "'" + s.replace("'", "'\\''") + "'"
}
