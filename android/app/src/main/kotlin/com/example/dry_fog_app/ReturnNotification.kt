package com.example.dry_fog_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build

// Уведомление «Вернуться в приложение» на время временного выхода техника
// (1.10.8). На CARFOG-100 нет панели навигации: из системных настроек
// вернуться можно только через шторку, которая во время выхода открыта.
// Нажатие запускает MainActivity с ACTION_RETURN — KioskPolicy.returnNow
// сразу возвращает блокировку.
//
// Уведомление не должно пережить окно выхода: его снимают relock, cancelExit,
// returnNow и старт процесса (KioskPolicy.syncReturnNotification), а если
// процесс умер раньше — сама система по setTimeoutAfter. Под блокировкой
// шторка отключена, так что клиент его не увидит, а нажатие только
// возвращает в приложение — выхода из киоска оно не даёт.
object ReturnNotification {
    const val ACTION_RETURN = "ee.carfog.dryfog.action.KIOSK_RETURN"
    private const val CHANNEL_ID = "kiosk_return"
    private const val NOTIFICATION_ID = 4310
    private const val REQUEST_CODE = 4310

    // false — уведомление не показано (старый Android или уведомления
    // запрещены); причину пишет вызывающий.
    fun show(ctx: Context, remainingMs: Long, title: String, action: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val nm = ctx.getSystemService(NotificationManager::class.java) ?: return false
        if (!nm.areNotificationsEnabled()) return false
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, title, NotificationManager.IMPORTANCE_LOW).apply {
                setShowBadge(false)
            }
        )
        val pending = PendingIntent.getActivity(
            ctx,
            REQUEST_CODE,
            Intent(ctx, MainActivity::class.java)
                .setAction(ACTION_RETURN)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val icon = Icon.createWithResource(ctx, R.drawable.ic_kiosk_return)
        val notification = Notification.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(icon)
            .setContentTitle(title)
            .setContentText(action)
            // Обратный отсчёт до возврата блокировки по таймеру.
            .setWhen(System.currentTimeMillis() + remainingMs)
            .setShowWhen(true)
            .setUsesChronometer(true)
            .setChronometerCountDown(true)
            .setOngoing(true)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter(remainingMs)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setCategory(Notification.CATEGORY_STATUS)
            .setContentIntent(pending)
            .addAction(Notification.Action.Builder(icon, action, pending).build())
            .build()
        nm.notify(NOTIFICATION_ID, notification)
        return true
    }

    fun cancel(ctx: Context) {
        try {
            ctx.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_ID)
        } catch (e: Throwable) {
            KioskPolicy.log(ctx, "ошибка снятия уведомления возврата: $e")
        }
    }
}
