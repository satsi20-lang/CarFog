package com.example.dry_fog_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.carfog.dryfog/modbus"
    private var modbusChannel: ModbusChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        modbusChannel = ModbusChannel(channel)
    }

    override fun onDestroy() {
        modbusChannel = null
        super.onDestroy()
    }
}
