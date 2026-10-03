package com.example.dry_fog_app

import android.app.AlarmManager
import android.app.Application
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Process
import android.os.SystemClock
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

// Аварийное выключение оборудования при сбое приложения (Шаг 32, задача 4).
//
// Если приложение упадёт во время обработки, ТЭН и компрессор рискуют
// остаться включёнными — главный риск для железа и пожарной безопасности
// на неохраняемом уличном терминале. К моменту падения Flutter/Dart уже
// нерабочий, поэтому весь этот обработчик работает напрямую с объектом
// шины (ModbusChannel.activeBus), минуя MethodChannel.
class DryFogApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        installCrashHandler()
    }

    private fun installCrashHandler() {
        val previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                Log.e(TAG, "Необработанное исключение — аварийное выключение оборудования", throwable)
                emergencyShutdown()
                markCrashed()
                scheduleRestart()
            } catch (e: Throwable) {
                Log.e(TAG, "Ошибка внутри самого аварийного обработчика: $e")
            } finally {
                // Не мешаем штатной цепочке обработчиков (системный краш-репортер
                // и т.п.) — просто отдаём им управление после того, как самое
                // важное (выключение выходов, отметка причины, план рестарта)
                // уже сделано. Процесс всё равно завершится ниже.
                try {
                    previousHandler?.uncaughtException(thread, throwable)
                } catch (e: Throwable) {
                    // Игнорируем — предыдущий обработчик мог сам упасть.
                }
                Process.killProcess(Process.myPid())
                exitProcess(10)
            }
        }
    }

    // Выключает все 12 выходов DIO-модуля напрямую через уже открытый порт.
    // Порядок — сначала самые опасные каналы (ТЭН, компрессор), потом
    // насосы: если жёсткий потолок по времени обрежет обход раньше, чем он
    // дойдёт до конца, самое важное уже будет выключено. Сам обход идёт в
    // отдельном потоке с ожиданием не дольше EMERGENCY_TIMEOUT_MS — если шина
    // не отвечает (вплоть до заблокированного намертво ioLock после сбоя
    // прямо посреди Modbus-транзакции), обработчик не виснет навсегда и
    // всё равно доходит до планирования рестарта и завершения процесса.
    private fun emergencyShutdown() {
        val bus = ModbusChannel.activeBus ?: return
        val latch = CountDownLatch(1)
        val worker = Thread {
            try {
                // ТЭН, компрессор, затем насосы 0-7 — самое опасное выключается
                // первым на случай, если жёсткий потолок по времени обрежет
                // обход раньше конца. LED (10/11) сюда НЕ входят: тот же
                // принцип, что и в новом safeAllOff() (задача "свести карту
                // шины и каналов") — индикаторы под отдельным управлением,
                // не гаснут вместе с нагрузками.
                val order = listOf(9, 8) + (0..7).toList()
                for (channel in order) {
                    try {
                        bus.writeSingleCoil(ModbusChannel.SLAVE_DIO_STATIC, channel, false)
                    } catch (e: Throwable) {
                        // Продолжаем с остальными каналами, даже если один не ответил.
                    }
                }
                // Красный индикатор (11) — явный сигнал аварии технику/
                // оператору на месте. Пишем последним, после того как самое
                // опасное уже выключено, но всё ещё в пределах
                // EMERGENCY_TIMEOUT_MS.
                try {
                    bus.writeSingleCoil(ModbusChannel.SLAVE_DIO_STATIC, 11, true)
                } catch (e: Throwable) {
                    // Не критично — если шина уже не отвечает, дальше всё
                    // равно ничего не поделать здесь.
                }
            } finally {
                latch.countDown()
            }
        }
        worker.isDaemon = true
        worker.start()
        latch.await(EMERGENCY_TIMEOUT_MS, TimeUnit.MILLISECONDS)
    }

    // commit(), не apply(): процесс сейчас завершится, а нам нужна гарантия,
    // что запись реально долетела до диска, а не осталась в очереди apply().
    private fun markCrashed() {
        try {
            getSharedPreferences(CRASH_PREFS, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_RECOVERED_FROM_CRASH, true)
                .commit()
        } catch (e: Throwable) {
            Log.e(TAG, "Не удалось записать признак аварии: $e")
        }
    }

    // AlarmManager — системный планировщик, переживает смерть текущего
    // процесса (обычный Handler/postDelayed — нет). Точность не нужна, это
    // просто "через несколько секунд", поэтому неточный будильник — не
    // требует разрешения SCHEDULE_EXACT_ALARM.
    //
    // Будильник доставляется в RestartReceiver (широковещательный приёмник),
    // а не напрямую в Activity — прямой PendingIntent.getActivity() из
    // AlarmManager блокируется ограничением на старт активности из фона,
    // когда процесс, поставивший будильник, уже мёртв к моменту срабатывания
    // (см. комментарий в RestartReceiver.kt — проверено вживую).
    // internal: тот же механизм использует и удалённая команда restart_app
    // (MainActivity.restartApp) — один проверенный вживую способ поднять
    // приложение после завершения процесса.
    internal fun scheduleRestart() {
        try {
            val pending = PendingIntent.getBroadcast(
                this,
                0,
                Intent(this, RestartReceiver::class.java),
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
            )
            val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            // setAlarmClock(), не setAndAllowWhileIdle(): проверено вживую, что
            // обычный неточный будильник, доставленный даже в широковещательный
            // приёмник, всё равно блокируется ограничением на старт активности
            // из фона (callingUidProcState=RECEIVER само по себе не входит в
            // список исключений на этой прошивке). "Будильник-часы" — тот же
            // механизм, на котором работают приложения-будильники, показывающие
            // экран звонка поверх заблокированного/фонового состояния.
            alarmManager.setAlarmClock(
                AlarmManager.AlarmClockInfo(
                    System.currentTimeMillis() + RESTART_DELAY_MS,
                    pending
                ),
                pending
            )
        } catch (e: Throwable) {
            Log.e(TAG, "Не удалось запланировать рестарт: $e")
        }
    }

    // Отмена запланированного рестарта (удалённая команда restart_app:
    // состояние за время ожидания перестало быть спокойным). Тот же
    // PendingIntent (одинаковые Intent и requestCode), FLAG_NO_CREATE —
    // если будильника нет, ничего не создаём.
    internal fun cancelScheduledRestart() {
        try {
            val pending = PendingIntent.getBroadcast(
                this,
                0,
                Intent(this, RestartReceiver::class.java),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
            )
            if (pending != null) {
                val alarmManager = getSystemService(Context.ALARM_SERVICE) as AlarmManager
                alarmManager.cancel(pending)
                pending.cancel()
            }
        } catch (e: Throwable) {
            Log.e(TAG, "Не удалось отменить рестарт: $e")
        }
    }

    companion object {
        private const val TAG = "DryFogApplication"
        private const val EMERGENCY_TIMEOUT_MS = 2000L
        private const val RESTART_DELAY_MS = 3000L
        const val CRASH_PREFS = "crash_prefs"
        const val KEY_RECOVERED_FROM_CRASH = "recovered_from_crash"
    }
}
