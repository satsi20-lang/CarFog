package com.example.dry_fog_app

import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class ModbusChannel(private val channel: MethodChannel) :
    MethodChannel.MethodCallHandler {

    private var modbus: ModbusRtu? = null

    // Slave IDs согласно схеме проекта
    private val SLAVE_DIO = 1        // MBSL16DI16DO
    private val SLAVE_THERMO = 2     // HLS-KWL-4TC
    private val SLAVE_ENERGY = 3     // DDS6619-039

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "open" -> {
                val port = call.argument<String>("port") ?: "/dev/ttyS5"
                val baud = call.argument<Int>("baud") ?: 9600
                modbus = ModbusRtu()
                result.success(modbus!!.open(port, baud))
            }

            "close" -> {
                modbus?.close()
                modbus = null
                result.success(null)
            }

            "isOpen" -> result.success(modbus?.isOpen() == true)

            // Читает все 8 DI датчиков уровня (каналы 0-7)
            "readLevels" -> {
                val di = modbus?.readDiscreteInputs(SLAVE_DIO, 0, 8)
                if (di == null) result.error("MODBUS", "readLevels failed", null)
                else result.success(di.map { it })
            }

            // Читает DI монетоприёмника (канал 8)
            "readCoin" -> {
                val di = modbus?.readDiscreteInputs(SLAVE_DIO, 8, 1)
                if (di == null) result.error("MODBUS", "readCoin failed", null)
                else result.success(di[0])
            }

            // Устанавливает один DO (0-based: насос 0-7, компрессор 8, ТЭН 9, LED зел 10, LED кр 11)
            "setDO" -> {
                val ch = call.argument<Int>("channel") ?: return result.error("ARG", "no channel", null)
                val on = call.argument<Boolean>("value") ?: false
                val ok = modbus?.writeSingleCoil(SLAVE_DIO, ch, on) == true
                result.success(ok)
            }

            // Выключает ВСЕ выходы (safe_all_off)
            "safeAllOff" -> {
                var ok = true
                for (ch in 0..11) {
                    if (modbus?.writeSingleCoil(SLAVE_DIO, ch, false) != true) ok = false
                }
                result.success(ok)
            }

            // Читает температуру термопары (канал 0-3, возвращает °C × 10)
            "readTemperature" -> {
                val ch = call.argument<Int>("channel") ?: 0
                val regs = modbus?.readHoldingRegisters(SLAVE_THERMO, ch, 1)
                if (regs == null) result.error("MODBUS", "readTemperature failed", null)
                else result.success(regs[0].toDouble() / 10.0)
            }

            else -> result.notImplemented()
        }
    }
}
