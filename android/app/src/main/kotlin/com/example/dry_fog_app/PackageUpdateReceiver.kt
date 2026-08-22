package com.example.dry_fog_app

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import org.json.JSONObject

// Android сбрасывает вручную выставленные PackageManager.
// setComponentEnabledSetting() обратно к значению из манифеста при замене
// APK (для KioskHomeAlias это android:enabled="false") — проверено вживую:
// adb install -r сбросил включённый киоск-режим, хотя AppConfig на диске
// всё ещё говорил "включено" (RoleControllerService в логе: "Removing
// package that no longer qualifies for the role... HOME"). Это будет
// происходить при каждом будущем обновлении приложения на аппарате, не
// только при разработке.
//
// MY_PACKAGE_REPLACED доставляется приложению ровно один раз, сразу после
// того как система заменила его APK — единственное подходящее место
// восстановить роль домашнего экрана. Обычный запуск (MainActivity/main())
// для этого специально НЕ используется — там та же реконструкция раньше
// приводила к гонке между несколькими экземплярами движка Flutter
// (обычный запуск, через роль Home, через BootReceiver) и самопроизвольно
// откатывала только что включённый тумблер (см. main.dart).
class PackageUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return

        val enabled = readKioskModeEnabled(context) ?: return
        val alias = ComponentName(context, "${context.packageName}.KioskHomeAlias")
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        try {
            context.packageManager.setComponentEnabledSetting(alias, state, PackageManager.DONT_KILL_APP)
        } catch (e: Exception) {
            // Ничего не поделать без Flutter/UI в этой точке — максимум,
            // что можно, техник переключит тумблер вручную при следующем
            // визите в сервисное меню.
        }
    }

    // Читает kioskModeEnabled напрямую из файла плагина shared_preferences —
    // движок Flutter в момент MY_PACKAGE_REPLACED ещё не запущен.
    private fun readKioskModeEnabled(context: Context): Boolean? {
        return try {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            val json = prefs.getString("flutter.app_config", null) ?: return null
            JSONObject(json).optBoolean("kioskModeEnabled", false)
        } catch (e: Exception) {
            null
        }
    }
}
