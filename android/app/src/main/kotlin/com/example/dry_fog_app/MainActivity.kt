package com.example.dry_fog_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.carfog.dryfog/modbus"
    private var modbusChannel: ModbusChannel? = null

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
    }

    override fun onDestroy() {
        modbusChannel = null
        super.onDestroy()
    }
}
