package com.example.dry_fog_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.carfog.dryfog/modbus"
    private val STORAGE_CHANNEL = "com.carfog.dryfog/storage"
    private val SYSTEM_CHANNEL = "com.carfog.dryfog/system"
    private var modbusChannel: ModbusChannel? = null

    // true, если этот запуск активности вызван BootReceiver'ом
    // (Шаг 32, задача 1) — читается один раз в onCreate из intent-экстры,
    // отдаётся во Flutter через SYSTEM_CHANNEL.consumeStartReason (задача 6).
    private var startedFromBoot = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startedFromBoot = intent?.getBooleanExtra(BootReceiver.EXTRA_STARTED_FROM_BOOT, false) == true
        // Терминал без оператора рядом — экран не должен гаснуть сам
        // (Шаг 32, задача 5). Таймаут экрана в настройках прошивки всё
        // равно стоит выставить в "никогда" отдельно: этот флаг перекрывает
        // не все прошивки/энергосберегающие режимы.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        requestAllFilesAccessIfNeeded()
    }

    // MANAGE_EXTERNAL_STORAGE — особое разрешение, выдаётся только через
    // системный экран настроек, обычным диалогом запросить нельзя.
    // На киоск-терминале это одноразовый шаг при первом запуске/после
    // сброса: техник подтверждает в открывшихся настройках и возвращается
    // в приложение.
    private fun requestAllFilesAccessIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        if (Environment.isExternalStorageManager()) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            } catch (e2: Exception) {
                // Прошивка не поддерживает ни один из вариантов — разрешение
                // придётся выдать вручную (adb или системные настройки).
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Modbus-обмен — блокирующий I/O (таймауты чтения, sleep для
        // межфреймовой паузы и подавления эха). Обычный MethodChannel
        // выполняет onMethodCall на UI-потоке — при нескольких вызовах
        // подряд (например safeAllOff на 12 каналов) это уводит за границу
        // ANR. Фоновая TaskQueue переносит обработку на отдельный поток.
        val taskQueue = flutterEngine.dartExecutor.binaryMessenger
            .makeBackgroundTaskQueue(BinaryMessenger.TaskQueueOptions())
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
            StandardMethodCodec.INSTANCE,
            taskQueue
        )
        modbusChannel = ModbusChannel(channel, this)

        // Корневые пути всех примонтированных томов (внутренняя память +
        // SD-карта) через официальный Android API. Нужен, потому что
        // прямой листинг /storage/ из приложения запрещён политикой
        // хранения (Permission denied), даже когда конкретный вложенный
        // путь тома читается нормально — а сама SD-карта монтируется под
        // ID тома (например /storage/DCA3-BA1A), а не под предсказуемым
        // именем вроде sdcard1.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "listVolumeRoots") {
                    result.success(listVolumeRoots())
                } else {
                    result.notImplemented()
                }
            }

        // Киоск-режим (Шаг 32, задачи 3/5/6) — не ходит на Modbus-шину,
        // короткие вызовы к PackageManager/SharedPreferences/Settings,
        // поэтому обычный MethodChannel на платформенном потоке, без
        // фоновой очереди.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKioskHomeEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setKioskHomeEnabled(enabled)
                        result.success(null)
                    }
                    "openHomeSettings" -> {
                        openHomeSettings()
                        result.success(null)
                    }
                    "consumeStartReason" -> result.success(consumeStartReason())
                    else -> result.notImplemented()
                }
            }
    }

    // Включает/выключает роль домашнего экрана у KioskHomeAlias
    // (Шаг 32, задача 3). DONT_KILL_APP обязателен — без него система
    // перезапускает процесс сразу после смены флага, что убило бы
    // приложение прямо в момент переключения тумблера в сервисном меню.
    private fun setKioskHomeEnabled(enabled: Boolean) {
        val alias = ComponentName(this, "$packageName.KioskHomeAlias")
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        packageManager.setComponentEnabledSetting(alias, state, PackageManager.DONT_KILL_APP)
    }

    // Системный экран "Приложение по умолчанию → Домашний экран". Используем
    // его и для кнопки "Открыть системный рабочий стол" (выход из киоска для
    // обслуживания), и сразу после включения тумблера киоск-режима (чтобы
    // техник выбрал наше приложение и поставил "Всегда") — в отличие от
    // ACTION_MAIN/CATEGORY_HOME он всегда даёт сменить выбор, даже если
    // "Всегда" уже было нажато раньше, и ведёт себя стабильнее на вендорских
    // прошивках, чем резолвер по умолчанию.
    private fun openHomeSettings() {
        try {
            startActivity(Intent(Settings.ACTION_HOME_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        } catch (e: Exception) {
            // Прошивка не поддерживает экран — оставляем как есть,
            // технику придётся переключать вручную через настройки Android.
        }
    }

    // Причина этого запуска приложения для облачного журнала (Шаг 32,
    // задача 6): "crash" — если предыдущий процесс упал (DryFogApplication
    // выставил и сохранил флаг через commit()), "boot" — если запущено
    // BootReceiver'ом после включения питания, иначе "normal". Флаг аварии
    // читается и сбрасывается одним вызовом (get-and-reset), как
    // getLastCoinCents в ModbusChannel — иначе следующий обычный запуск
    // снова показал бы "после сбоя".
    private fun consumeStartReason(): String {
        val prefs = getSharedPreferences(
            DryFogApplication.CRASH_PREFS,
            Context.MODE_PRIVATE
        )
        val crashed = prefs.getBoolean(DryFogApplication.KEY_RECOVERED_FROM_CRASH, false)
        if (crashed) {
            prefs.edit().putBoolean(DryFogApplication.KEY_RECOVERED_FROM_CRASH, false).apply()
            return "crash"
        }
        return if (startedFromBoot) "boot" else "normal"
    }

    // Съёмные тома (SD-карта) — первыми, встроенная память — в конце,
    // чтобы вызывающий код по умолчанию находил файлы именно на карте.
    private fun listVolumeRoots(): List<String> {
        val primary = mutableListOf<String>()
        val removable = mutableListOf<String>()
        try {
            val sm = getSystemService(Context.STORAGE_SERVICE) as StorageManager
            for (volume in sm.storageVolumes) {
                val path: String? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    volume.directory?.absolutePath
                } else {
                    // До API 30 путь официально не публикуется — getPath()
                    // скрытый метод, но стабильно присутствует на практике.
                    try {
                        volume.javaClass.getMethod("getPath").invoke(volume) as? String
                    } catch (e: Exception) {
                        null
                    }
                }
                if (path != null) {
                    if (volume.isPrimary) primary.add(path) else removable.add(path)
                }
            }
        } catch (e: Exception) {
            // Возвращаем то, что успели собрать (может быть пусто).
        }
        return removable + primary
    }

    override fun onDestroy() {
        modbusChannel = null
        super.onDestroy()
    }
}
