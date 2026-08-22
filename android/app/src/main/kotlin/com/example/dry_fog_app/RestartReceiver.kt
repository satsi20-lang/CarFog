package com.example.dry_fog_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

// Приёмник, которым DryFogApplication планирует рестарт после аварии через
// AlarmManager (Шаг 32, задача 4).
//
// Важно: AlarmManager не может запускать Activity напрямую через
// PendingIntent.getActivity() — на Android 10+ такой запуск блокируется
// ограничением на старт активности из фона (background activity start),
// потому что к моменту срабатывания будильника процесс уже мёртв
// (проверено вживую: ActivityTaskManager логировал "Background activity
// start ... allowBackgroundActivityStart: false", и активность не
// запускалась). Широковещательный приёмник, вызванный системным
// будильником, получает временное разрешение на запуск activity изнутри
// onReceive() — тот же механизм, на котором работает автозапуск через
// BOOT_COMPLETED (см. BootReceiver).
class RestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        }
        context.startActivity(launch)
    }
}
