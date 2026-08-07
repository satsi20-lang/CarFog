package com.example.dry_fog_app

import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

class ModbusRtu {

    private var raf: RandomAccessFile? = null
    private var inputStream: FileInputStream? = null
    private var outputStream: FileOutputStream? = null

    // fair=true: гарантирует порядок FIFO среди ожидающих поток. Обычный
    // synchronized (или nonfair-лок) не даёт такой гарантии — быстро
    // переопрашивающий поток (например, счётчик монет) может раз за разом
    // перехватывать лок раньше редко обращающихся потоков, фактически
    // блокируя их на неопределённое время (проверено на практике: без
    // fair-лока энергия/уровни переставали отвечать вовсе, пока опрос монет
    // работал в фоне).
    private val ioLock = ReentrantLock(true)

    // Открыть порт: настроить линию через stty, затем открыть один
    // файловый дескриптор через RandomAccessFile (O_RDWR) и получить
    // из него оба потока — вместо двух независимых open() на один
    // и тот же character device.
    fun open(port: String, baud: Int): Boolean {
        return try {
            if (!configurePort(port, baud)) {
                return false
            }

            val f = RandomAccessFile(port, "rwd")
            raf = f
            inputStream = FileInputStream(f.fd)
            outputStream = FileOutputStream(f.fd)
            true
        } catch (e: Throwable) {
            // Throwable, не Exception: не даём одиночному сбою настройки/открытия
            // порта уйти выше по стеку и уронить всё приложение.
            Log.e("ModbusRtu", "open error: $e")
            false
        }
    }

    // stty может отсутствовать в PATH, доступном exec()'у приложения —
    // перебираем известные расположения бинарника по очереди.
    private fun configurePort(port: String, baud: Int): Boolean {
        val sttyCandidates = listOf("/system/bin/stty", "/system/xbin/stty", "stty")
        for (sttyPath in sttyCandidates) {
            try {
                val cmd = arrayOf(
                    sttyPath, "-F", port, baud.toString(),
                    "cs8", "-cstopb", "-parenb", "raw", "-echo"
                )
                val process = Runtime.getRuntime().exec(cmd)
                val exited = process.waitFor(2, TimeUnit.SECONDS)
                if (!exited) {
                    process.destroy()
                    Log.d("ModbusRtu", "stty '$sttyPath' -> timed out")
                    continue
                }
                val exitCode = process.exitValue()
                val stderr = process.errorStream.bufferedReader().use { it.readText() }.trim()
                Log.d("ModbusRtu", "stty '$sttyPath' -> exit=$exitCode stderr='$stderr'")
                if (exitCode == 0) return true
            } catch (e: Exception) {
                Log.d("ModbusRtu", "stty '$sttyPath' -> exec failed: $e")
            }
        }
        Log.e("ModbusRtu", "stty failed, port may be misconfigured")
        return false
    }

    fun close() {
        // inputStream/outputStream делят дескриптор с raf — закрываем
        // только raf, иначе повторное закрытие того же fd через них
        // может выбросить исключение.
        try {
            raf?.close()
        } catch (e: Exception) {
            Log.e("ModbusRtu", "close error: $e")
        }
        raf = null
        inputStream = null
        outputStream = null
    }

    fun isOpen() = inputStream != null && outputStream != null

    // FC02: Read Discrete Inputs (DI — датчики уровня, монетоприёмник)
    // timeoutMs — таймаут ожидания ответа (см. sendAndReceive/readWithTimeout);
    // по умолчанию 500мс, но опрос монетоприёмника использует укороченный,
    // чтобы не задерживать остальных на общей шине при отсутствии ответа.
    fun readDiscreteInputs(slaveId: Int, startAddr: Int, count: Int, timeoutMs: Long = 500): BooleanArray? {
        val req = buildRequest(slaveId, 0x02, startAddr, count)
        val resp = sendAndReceive(req, 3 + ((count + 7) / 8), timeoutMs) ?: return null
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
        // Ответ FC05 — эхо запроса: 6 байт данных + 2 CRC, добавляемых внутри
        // sendAndReceive. Раньше здесь передавалось 8 (уже с CRC), из-за чего
        // ожидалось 10 байт вместо реальных 8 и запись всегда считалась неудачной.
        val resp = sendAndReceive(reqWithCrc, 6) ?: return false
        return validateResponse(resp, slaveId, 0x05)
    }

    // FC06: Write Single Register (используется для смены адреса счётчика DDS6619)
    fun writeSingleRegister(slaveId: Int, addr: Int, value: Int): Boolean {
        val req = byteArrayOf(
            slaveId.toByte(),
            0x06,
            (addr shr 8).toByte(), addr.toByte(),
            (value shr 8).toByte(), value.toByte()
        )
        val reqWithCrc = appendCrc(req)
        // Ответ FC06 — эхо запроса: 6 байт данных + 2 CRC (как FC05)
        val resp = sendAndReceive(reqWithCrc, 6) ?: return false
        return validateResponse(resp, slaveId, 0x06)
    }

    // FC16: Write Multiple Registers (запись float/составных значений)
    fun writeMultipleRegisters(slaveId: Int, startAddr: Int, data: ByteArray): Boolean {
        val quantity = data.size / 2
        val req = byteArrayOf(
            slaveId.toByte(),
            0x10,
            (startAddr shr 8).toByte(), startAddr.toByte(),
            (quantity shr 8).toByte(), quantity.toByte(),
            data.size.toByte()
        ) + data
        val reqWithCrc = appendCrc(req)
        // Ответ FC16 — эхо slave+fc+addr+quantity (без данных): 6 байт + 2 CRC
        val resp = sendAndReceive(reqWithCrc, 6) ?: return false
        return validateResponse(resp, slaveId, 0x10)
    }

    // FC03: Read Holding Registers (термопары)
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

    // FC04: Read Input Registers (счётчик энергии DDS6619 — живые измерения;
    // на этом устройстве FC03 отдаёт статичные конфигурационные значения,
    // а реальные показания идут именно через FC04). Логика идентична
    // readHoldingRegisters, отличается только function code.
    fun readInputRegisters(slaveId: Int, startAddr: Int, count: Int): IntArray? {
        val req = buildRequest(slaveId, 0x04, startAddr, count)
        val resp = sendAndReceive(req, 3 + count * 2) ?: return null
        if (!validateResponse(resp, slaveId, 0x04)) return null
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

    // ioLock: единая точка, через которую проходят все Modbus-транзакции
    // (readCoils/readDiscreteInputs/readHoldingRegisters/readInputRegisters/
    // writeSingleCoil/writeSingleRegister/writeMultipleRegisters). Порт RS485
    // полудуплексный и общий на всех — без блокировки конкурентные вызовы с
    // разных потоков перемешивали бы байты запросов/ответов друг друга.
    private fun sendAndReceive(request: ByteArray, expectedBytes: Int, timeoutMs: Long = 500): ByteArray? {
        ioLock.lock()
        try {
            val out = outputStream ?: return null
            if (inputStream == null) return null
            return try {
                out.write(request)
                out.flush()
                Thread.sleep(20) // межфреймовая пауза

                val resp = readWithTimeout(expectedBytes + 2, timeoutMs) // +2 CRC
                if (resp.size < expectedBytes + 2) {
                    Log.w("ModbusRtu", "short response: ${resp.size} bytes")
                    return null
                }
                if (!checkCrc(resp)) {
                    Log.w("ModbusRtu", "CRC error")
                    return null
                }
                resp
            } catch (e: Exception) {
                Log.e("ModbusRtu", "sendAndReceive error: $e")
                null
            }
        } finally {
            ioLock.unlock()
        }
    }

    // FileInputStream.read() на символьном устройстве блокируется без таймаута
    // (в отличие от jSerialComm с setComPortTimeouts), а один вызов read()
    // может вернуть лишь часть кадра, если ОС ещё не успела доставить все
    // байты разом — поэтому копим байты в цикле, пока не наберём нужное
    // количество или не истечёт таймаут.
    private fun readWithTimeout(expectedBytes: Int, timeoutMs: Long = 500): ByteArray {
        val inp = inputStream ?: return ByteArray(0)
        val deadline = System.currentTimeMillis() + timeoutMs
        val buffer = mutableListOf<Byte>()
        while (System.currentTimeMillis() < deadline) {
            val available = inp.available()
            if (available > 0) {
                val chunk = ByteArray(available)
                val read = inp.read(chunk)
                if (read > 0) buffer.addAll(chunk.take(read).toList())
                if (buffer.size >= expectedBytes) break
            } else {
                Thread.sleep(5)
            }
        }
        return buffer.toByteArray()
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
