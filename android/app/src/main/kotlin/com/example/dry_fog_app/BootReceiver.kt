package com.example.dry_fog_app

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager

// Автозапуск после восстановления питания: аппарат стоит на улице без
// оператора рядом, после пропадания и появления электричества приложение
// должно подняться само, без касаний экрана.
//
// Обрабатываем оба варианта события — обычный BOOT_COMPLETED и
// LOCKED_BOOT_COMPLETED (приходит раньше, до разблокировки хранилища на
// прошивках с шифрованием по файлам) — на части прошивок долетает только
// один из них. LOCKED_BOOT_COMPLETED доставляется лишь directBootAware
// компонентам, поэтому приёмник помечен таковым в манифесте.
//
// Пока включён киоск-режим (задача 3), в автозапуске нет нужды: систем
// САМА поднимает приложение как домашний экран при загрузке — привилегированным
// путём, который НЕ подпадает под ограничение на старт активности из фона
// (проверено вживую: без этого ограничение блокирует и BOOT_COMPLETED тоже).
// Собственный запуск отсюда в этом случае просто дублировал бы работу
// системы вторым движком Flutter — пропускаем.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }

        if (isKioskHomeEnabled(context)) return

        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            // Причина запуска для облачного журнала (задача 6) —
            // MainActivity читает этот флаг в onCreate().
            putExtra(EXTRA_STARTED_FROM_BOOT, true)
        }
        context.startActivity(launch)
    }

    private fun isKioskHomeEnabled(context: Context): Boolean {
        return try {
            val alias = ComponentName(context, "${context.packageName}.KioskHomeAlias")
            val state = context.packageManager.getComponentEnabledSetting(alias)
            state == PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } catch (e: Exception) {
            false
        }
    }

    companion object {
        const val EXTRA_STARTED_FROM_BOOT = "started_from_boot"
        private const val ACTION_LOCKED_BOOT_COMPLETED = "android.intent.action.LOCKED_BOOT_COMPLETED"
    }
}
