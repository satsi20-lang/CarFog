package com.example.dry_fog_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

// Автозапуск после восстановления питания: аппарат стоит на улице без
// оператора рядом, после пропадания и появления электричества приложение
// должно подняться само, без касаний экрана.
//
// Обрабатываем оба варианта события — обычный BOOT_COMPLETED и
// LOCKED_BOOT_COMPLETED (приходит раньше, до разблокировки хранилища на
// прошивках с шифрованием по файлам) — на части прошивок долетает только
// один из них. LOCKED_BOOT_COMPLETED доставляется лишь directBootAware
// компонентам, поэтому приёмник помечен таковым в манифесте.
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != ACTION_LOCKED_BOOT_COMPLETED
        ) {
            return
        }

        val launch = Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            // Причина запуска для облачного журнала (задача 6) —
            // MainActivity читает этот флаг в onCreate().
            putExtra(EXTRA_STARTED_FROM_BOOT, true)
        }
        context.startActivity(launch)
    }

    companion object {
        const val EXTRA_STARTED_FROM_BOOT = "started_from_boot"
        private const val ACTION_LOCKED_BOOT_COMPLETED = "android.intent.action.LOCKED_BOOT_COMPLETED"
    }
}
