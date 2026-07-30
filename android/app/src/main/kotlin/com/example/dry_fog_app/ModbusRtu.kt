package com.example.dry_fog_app

import com.fazecast.jSerialComm.SerialPort
import android.util.Log

class ModbusRtu(private val portName: String, private val baudRate: Int = 9600) {

    private var port: SerialPort? = null

    // Открыть порт
    fun open(): Boolean {
        return try {
            port = SerialPort.getCommPort(portName)
            port!!.baudRate = baudRate
            port!!.numDataBits = 8
            port!!.numStopBits = SerialPort.ONE_STOP_BIT
            port!!.parity = SerialPort.NO_PARITY
            port!!.setComPortTimeouts(
                SerialPort.TIMEOUT_READ_BLOCKING,
                500, 500
            )
            port!!.openPort()
        } catch (e: Throwable) {
            // Throwable, не Exception: сюда же попадает UnsatisfiedLinkError,
            // если нативная библиотека jSerialComm не загрузилась на устройстве —
            // без этого краш уходил выше catch(Exception) и убивал всё приложение.
            Log.e("ModbusRtu", "open error: $e")
            false
        }
    }

    fun close() {
        port?.closePort()
        port = null
    }

    fun isOpen() = port?.isOpen == true

    // FC02: Read Discrete Inputs (DI — датчики уровня, монетоприёмник)
    fun readDiscreteInputs(slaveId: Int, startAddr: Int, count: Int): BooleanArray? {
        val req = buildRequest(slaveId, 0x02, startAddr, count)
        val resp = sendAndReceive(req, 3 + ((count + 7) / 8)) ?: return null
        if (!validateResponse(resp, slaveId, 0x02)) return null
        val result = BooleanArray(count)
        for (i in 0 until count) {
            val byteIdx = i / 8
            val bitIdx = i % 8
            result[i] = (resp[3 + byteIdx].toInt() and (1 shl bitIdx)) != 0
        }
        return result
    }

    // FC01: Read Coils (DO — текущее состояние выходов)
    fun readCoils(slaveId: Int, startAddr: Int, count: Int): BooleanArray? {
        val req = buildRequest(slaveId, 0x01, startAddr, count)
        val resp = sendAndReceive(req, 3 + ((count + 7) / 8)) ?: return null
        if (!validateResponse(resp, slaveId, 0x01)) return null
        val result = BooleanArray(count)
        for (i in 0 until count) {
            val byteIdx = i / 8
            val bitIdx = i % 8
            result[i] = (resp[3 + byteIdx].toInt() and (1 shl bitIdx)) != 0
        }
        return result
    }

    // FC05: Write Single Coil (DO — управление выходом)
    fun writeSingleCoil(slaveId: Int, addr: Int, value: Boolean): Boolean {
        val coilVal = if (value) 0xFF00 else 0x0000
        val req = byteArrayOf(
            slaveId.toByte(),
            0x05,
            (addr shr 8).toByte(), addr.toByte(),
            (coilVal shr 8).toByte(), coilVal.toByte()
        )
        val reqWithCrc = appendCrc(req)
        val resp = sendAndReceive(reqWithCrc, 8) ?: return false
        return validateResponse(resp, slaveId, 0x05)
    }

    // FC03: Read Holding Registers (термопары, счётчик энергии)
    fun readHoldingRegisters(slaveId: Int, startAddr: Int, count: Int): IntArray? {
        val req = buildRequest(slaveId, 0x03, startAddr, count)
        val resp = sendAndReceive(req, 3 + count * 2) ?: return null
        if (!validateResponse(resp, slaveId, 0x03)) return null
        val byteCount = resp[2].toInt() and 0xFF
        if (byteCount < count * 2) return null
        return IntArray(count) { i ->
            ((resp[3 + i * 2].toInt() and 0xFF) shl 8) or
            (resp[4 + i * 2].toInt() and 0xFF)
        }
    }

    // ================================================================
    // PRIVATE
    // ================================================================

    private fun buildRequest(slaveId: Int, fc: Int, addr: Int, count: Int): ByteArray {
        val req = byteArrayOf(
            slaveId.toByte(), fc.toByte(),
            (addr shr 8).toByte(), addr.toByte(),
            (count shr 8).toByte(), count.toByte()
        )
        return appendCrc(req)
    }

    private fun sendAndReceive(request: ByteArray, expectedBytes: Int): ByteArray? {
        val p = port ?: return null
        return try {
            p.outputStream.write(request)
            p.outputStream.flush()
            Thread.sleep(20) // межфреймовая пауза
            val buf = ByteArray(expectedBytes + 2) // +2 CRC
            val read = p.inputStream.read(buf)
            if (read < expectedBytes + 2) {
                Log.w("ModbusRtu", "short response: $read bytes")
                return null
            }
            val resp = buf.copyOf(read)
            if (!checkCrc(resp)) {
                Log.w("ModbusRtu", "CRC error")
                return null
            }
            resp
        } catch (e: Exception) {
            Log.e("ModbusRtu", "sendAndReceive error: $e")
            null
        }
    }

    private fun validateResponse(resp: ByteArray, slaveId: Int, fc: Int): Boolean {
        if (resp.size < 4) return false
        if ((resp[0].toInt() and 0xFF) != slaveId) return false
        val respFc = resp[1].toInt() and 0xFF
        if (respFc == fc or 0x80) {
            Log.w("ModbusRtu", "Modbus exception: ${resp[2].toInt() and 0xFF}")
            return false
        }
        return respFc == fc
    }

    private fun appendCrc(data: ByteArray): ByteArray {
        val crc = calcCrc(data)
        return data + byteArrayOf((crc and 0xFF).toByte(), ((crc shr 8) and 0xFF).toByte())
    }

    private fun checkCrc(data: ByteArray): Boolean {
        if (data.size < 3) return false
        val payload = data.copyOf(data.size - 2)
        val expected = calcCrc(payload)
        val got = (data[data.size - 2].toInt() and 0xFF) or
                  ((data[data.size - 1].toInt() and 0xFF) shl 8)
        return expected == got
    }

    private fun calcCrc(data: ByteArray): Int {
        var crc = 0xFFFF
        for (b in data) {
            crc = crc xor (b.toInt() and 0xFF)
            repeat(8) {
                crc = if (crc and 0x0001 != 0) (crc shr 1) xor 0xA001
                      else crc shr 1
            }
        }
        return crc
    }
}
