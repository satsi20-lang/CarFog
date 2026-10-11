package com.example.dry_fog_app

import android.app.admin.DeviceAdminReceiver
import android.content.Context
import android.content.Intent

// Приёмник администратора устройства — нужен только как точка назначения
// Device Owner (adb shell dpm set-device-owner
// ee.carfog.dryfog/com.example.dry_fog_app.CarfogAdminReceiver).
// Сама работа с политиками — в KioskPolicy.
class CarfogAdminReceiver : DeviceAdminReceiver() {
    override fun onEnabled(context: Context, intent: Intent) {
        KioskPolicy.log(context, "администратор устройства включён")
    }

    override fun onDisabled(context: Context, intent: Intent) {
        KioskPolicy.log(context, "администратор устройства отключён")
    }
}
