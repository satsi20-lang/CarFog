package com.example.dry_fog_app

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log

// Перезапуск приложения по удалённой команде restart_app (R1).
//
// Проблема, найденная живым тестом 03.10.2026: убить процесс и поднять
// MainActivity из AlarmManager→RestartReceiver нельзя — система запрещает
// запуск активности из фона ("Abort background activity starts"), и после
// restart_app экран не возвращался (на этой прошивке киоск-режим выключен,
// "домашнее" приложение само не поднимается). Схема "Process Phoenix":
//  1. MainActivity, пока она на переднем плане, запускает ЭТУ активность в
//     отдельном процессе (:restart) — запуск от видимого окна разрешён;
//  2. она убивает основной процесс (его pid передан в экстре);
//  3. и сама, будучи на переднем плане, запускает MainActivity заново;
//  4. завершает свой процесс.
// Запасной будильник (DryFogApplication.scheduleRestart) отменяется.
class RestartActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val mainPid = intent.getIntExtra(EXTRA_MAIN_PID, -1)
        if (mainPid > 0 && mainPid != Process.myPid()) {
            Process.killProcess(mainPid)
        }
        // Дать системе убрать запись старой активности; затем поднять новую.
        Handler(Looper.getMainLooper()).postDelayed({
            try {
                startActivity(
                    Intent(this, MainActivity::class.java).addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TASK
                    )
                )
                (application as? DryFogApplication)?.cancelScheduledRestart()
            } catch (e: Throwable) {
                // Запасной будильник остаётся запланированным и сработает сам.
                Log.e(TAG, "Не удалось запустить MainActivity: $e")
            }
            finish()
            Process.killProcess(Process.myPid())
        }, RESTART_DELAY_MS)
    }

    companion object {
        private const val TAG = "RestartActivity"
        const val EXTRA_MAIN_PID = "main_pid"
        private const val RESTART_DELAY_MS = 600L
    }
}
