package com.example.dry_fog_app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.carfog.dryfog/modbus"
    private val STORAGE_CHANNEL = "com.carfog.dryfog/storage"
    private var modbusChannel: ModbusChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
