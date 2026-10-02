package com.example.dry_fog_app

import android.content.Context
import android.os.Process
import android.util.Log
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.channels.FileLock
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock

// context — нужен только для файла-информатора о держателе блокировки
// (см. writeLockInfo/readLockInfo); опционален, потому что сама
// эксклюзивность обеспечивается FileChannel.tryLock() ниже и от него не
// зависит. Без context (если вызывающий код его не передал) блокировка
// продолжает работать, просто сообщение об отказе не будет знать чужой PID.
class ModbusRtu(private val context: Context? = null) {

    private var raf: RandomAccessFile? = null
    private var inputStream: FileInputStream? = null
    private var outputStream: FileOutputStream? = null
    private var portLock: FileLock? = null
    private var lockInfoFile: File? = null

    // Задача "эксклюзивное открытие последовательного порта" — PID этого
    // процесса в каждой строке лога. Именно чужой PID в adb logcat выдал
    // причину часовой задержки (см. задачу про диагностику задержек), но
    // заметили не сразу — теперь он виден с первой строки.
    // try/catch — не android-рантайм (локальные JVM unit-тесты, см.
    // ModbusRtuCrcTest) не мокает Process.myPid() и бросает исключение;
    // на реальном устройстве try-ветка не участвует, эта строка вообще не
    // должна ронять конструктор ни там, ни там.
    private val pid = try {
        Process.myPid()
    } catch (e: Throwable) {
        -1
    }
    private val TAG = "ModbusRtu[pid=$pid]"

    // fair=true: гарантирует порядок FIFO среди ожидающих поток. Обычный
    // synchronized (или nonfair-лок) не даёт такой гарантии — быстро
    // переопрашивающий поток (например, счётчик монет) может раз за разом
    // перехватывать лок раньше редко обращающихся потоков, фактически
    // блокируя их на неопределённое время (проверено на практике: без
    // fair-лока энергия/уровни переставали отвечать вовсе, пока опрос монет
    // работал в фоне).
    private val ioLock = ReentrantLock(true)

    // Результат открытия порта — раньше был просто Boolean, из-за чего
    // "порт занят другим процессом" неотличимо от "порт не найден"/"нет
    // прав": оба варианта одинаково молча проваливались, и час ушёл на
    // диагностику по логу вместо одной внятной ошибки.
    sealed class OpenResult {
        object Ok : OpenResult()
        data class Busy(val holderPid: Int?) : OpenResult()
        object Failed : OpenResult()
    }

    // Открыть порт: настроить линию через stty, затем открыть один
    // файловый дескриптор через RandomAccessFile (O_RDWR), взять
    // эксклюзивную блокировку и получить из дескриптора оба потока —
    // вместо двух независимых open() на один и тот же character device.
    //
    // Эксклюзивность — FileChannel.tryLock(), не raw flock()/TIOCEXCL:
    // NDK/JNI в проекте нет вообще (весь нативный слой — чистый Kotlin
    // поверх RandomAccessFile), а добавлять его ради одного ioctl-вызова —
    // не входит в границы задачи. tryLock() на Android реализован поверх
    // того же fcntl(F_SETLK) — настоящая блокировка уровня ядра, видимая
    // другим процессам, неблокирующая (сразу null, если занято, а не
    // зависание) и снимающаяся сама при закрытии дескриптора и при гибели
    // процесса — осиротевший процесс освобождает порт, когда его убьют,
    // отдельная уборка не нужна.
    // parity: "none" (боевой режим, CWT-BK-1616) / "odd" / "even" —
    // диагностика "чётность отличается от ожидаемой" (задача "Chint
    // DDSU666: найти счётчик"). Дефолт "none" — обычный вызов open(port,
    // baud) продолжает работать как раньше, ничего не меняя для остальных
    // мест кода.
    fun open(port: String, baud: Int, parity: String = "none"): OpenResult {
        return try {
            if (!configurePort(port, baud, parity)) {
                return OpenResult.Failed
            }

            val f = RandomAccessFile(port, "rwd")

            val lock = try {
                f.channel.tryLock()
            } catch (e: Exception) {
                Log.e(TAG, "lock error: $e")
                null
            }
            if (lock == null) {
                try {
                    f.close()
                } catch (e: Exception) {
                    Log.e(TAG, "close after busy error: $e")
                }
                val holderPid = readLockInfo(port)
                Log.e(
                    TAG,
                    "port busy: $port" +
                        (if (holderPid != null) " (held by pid=$holderPid)" else " (holder pid unknown)")
                )
                return OpenResult.Busy(holderPid)
            }
            portLock = lock

            raf = f
            inputStream = FileInputStream(f.fd)
            outputStream = FileOutputStream(f.fd)
            writeLockInfo(port)
            OpenResult.Ok
        } catch (e: Throwable) {
            // Throwable, не Exception: не даём одиночному сбою настройки/открытия
            // порта уйти выше по стеку и уронить всё приложение.
            Log.e(TAG, "open error: $e")
            OpenResult.Failed
        }
    }

    // Файл с PID держателя блокировки — только для текста ошибки "кем
    // занят" (задача, п.6). Сама эксклюзивность обеспечивается tryLock()
    // выше и от этого файла не зависит: если файла нет, устарел или лежит
    // мимо (context == null) — блокировка всё равно отработает, просто
    // PID в сообщении не появится. Путь зависит от имени порта, чтобы
    // разные порты (случись такое) не путали друг друга.
    private fun lockInfoPath(port: String): File? {
        val dir = context?.filesDir ?: return null
        return File(dir, "modbus_lock_${port.replace("/", "_")}.pid")
    }

    private fun writeLockInfo(port: String) {
        val file = lockInfoPath(port) ?: return
        try {
            file.writeText(pid.toString())
            lockInfoFile = file
        } catch (e: Exception) {
            Log.e(TAG, "writeLockInfo error: $e")
        }
    }

    private fun readLockInfo(port: String): Int? {
        return try {
            lockInfoPath(port)?.takeIf { it.exists() }?.readText()?.trim()?.toIntOrNull()
        } catch (e: Exception) {
            null
        }
    }

    // stty может отсутствовать в PATH, доступном exec()'у приложения —
    // перебираем известные расположения бинарника по очереди.
    private fun configurePort(port: String, baud: Int, parity: String = "none"): Boolean {
        val parityFlags = when (parity) {
            "odd" -> arrayOf("parenb", "parodd")
            "even" -> arrayOf("parenb", "-parodd")
            else -> arrayOf("-parenb")
        }
        val sttyCandidates = listOf("/system/bin/stty", "/system/xbin/stty", "stty")
        for (sttyPath in sttyCandidates) {
            try {
                val cmd = arrayOf(
                    sttyPath, "-F", port, baud.toString(),
                    "cs8", "-cstopb", *parityFlags, "raw", "-echo"
                )
                val process = Runtime.getRuntime().exec(cmd)
                val exited = process.waitFor(2, TimeUnit.SECONDS)
                if (!exited) {
                    process.destroy()
                    Log.d(TAG, "stty '$sttyPath' -> timed out")
                    continue
                }
                val exitCode = process.exitValue()
                val stderr = process.errorStream.bufferedReader().use { it.readText() }.trim()
                Log.d(TAG, "stty '$sttyPath' -> exit=$exitCode stderr='$stderr'")
                if (exitCode == 0) return true
            } catch (e: Exception) {
                Log.d(TAG, "stty '$sttyPath' -> exec failed: $e")
            }
        }
        Log.e(TAG, "stty failed, port may be misconfigured")
        return false
    }

    fun close() {
        // Снимается и сама при закрытии raf ниже (закрытие дескриптора
        // освобождает файловые блокировки), но явный release() — не
        // полагаться на побочный эффект, а зафиксировать намерение.
        try {
            portLock?.release()
        } catch (e: Exception) {
            Log.e(TAG, "lock release error: $e")
        }
        portLock = null
        // inputStream/outputStream делят дескриптор с raf — закрываем
        // только raf, иначе повторное закрытие того же fd через них
        // может выбросить исключение.
        try {
            raf?.close()
        } catch (e: Exception) {
            Log.e(TAG, "close error: $e")
        }
        raf = null
        inputStream = null
        outputStream = null
        try {
            lockInfoFile?.delete()
        } catch (e: Exception) {
            // best-effort — переживёт и мусорный файл, следующий open()
            // перезапишет его своим PID.
        }
        lockInfoFile = null
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
    // timeoutMs — явный, не значение по умолчанию (см. историю про
    // pollTerminal в ModbusChannel.kt: забытый явный таймаут на широком
    // чтении незаметно подставил 500 мс вместо нужных 150 и съедал
    // короткие импульсы под нагрузкой шины). Сторож выходов (задача
    // "сторож выходов") дорожит быстрым ответом не меньше терминала —
    // застрять на 500 мс на КАЖДОМ неотвечающем тике так же вредно.
    fun readCoils(slaveId: Int, startAddr: Int, count: Int, timeoutMs: Long = 500): BooleanArray? {
        val req = buildRequest(slaveId, 0x01, startAddr, count)
        val resp = sendAndReceive(req, 3 + ((count + 7) / 8), timeoutMs) ?: return null
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
    // timeoutMs — явный (см. комментарий у readCoils выше): вызывающие
    // (setDO, ручная запись катушки в сканере) сами выбирают короткий
    // таймаут ради быстрого отклика на живой шине. safeAllOff() больше не
    // ходит через эту функцию — см. scanWriteMultipleCoils (один кадр FC15
    // вместо серии отдельных FC05, задача "свести карту шины и каналов").
    fun writeSingleCoil(slaveId: Int, addr: Int, value: Boolean, timeoutMs: Long = 500): Boolean {
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
        val resp = sendAndReceive(reqWithCrc, 6, timeoutMs) ?: return false
        return validateResponse(resp, slaveId, 0x05)
    }

    // FC06: Write Single Register (используется для смены адреса счётчика DDS6619)
    // timeoutMs — явный, как и везде (см. историю про pollTerminal в
    // ModbusChannel.kt): забытый явный таймаут на массовом обмене
    // подставляет значение по умолчанию и может держать шину заметно дольше,
    // чем нужно. Сканеру шины (запись служебных регистров) короткий явный
    // таймаут особенно важен.
    fun writeSingleRegister(slaveId: Int, addr: Int, value: Int, timeoutMs: Long = 500): Boolean {
        val req = byteArrayOf(
            slaveId.toByte(),
            0x06,
            (addr shr 8).toByte(), addr.toByte(),
            (value shr 8).toByte(), value.toByte()
        )
        val reqWithCrc = appendCrc(req)
        // Ответ FC06 — эхо запроса: 6 байт данных + 2 CRC (как FC05)
        val resp = sendAndReceive(reqWithCrc, 6, timeoutMs) ?: return false
        return validateResponse(resp, slaveId, 0x06)
    }

    // FC16: Write Multiple Registers (запись float/составных значений)
    fun writeMultipleRegisters(
        slaveId: Int,
        startAddr: Int,
        data: ByteArray,
        timeoutMs: Long = 500,
    ): Boolean {
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
        val resp = sendAndReceive(reqWithCrc, 6, timeoutMs) ?: return false
        return validateResponse(resp, slaveId, 0x10)
    }

    // FC03: Read Holding Registers (термопары)
    fun readHoldingRegisters(
        slaveId: Int,
        startAddr: Int,
        count: Int,
        timeoutMs: Long = 500,
    ): IntArray? {
        val req = buildRequest(slaveId, 0x03, startAddr, count)
        val resp = sendAndReceive(req, 3 + count * 2, timeoutMs) ?: return null
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
    fun readInputRegisters(
        slaveId: Int,
        startAddr: Int,
        count: Int,
        timeoutMs: Long = 500,
    ): IntArray? {
        val req = buildRequest(slaveId, 0x04, startAddr, count)
        val resp = sendAndReceive(req, 3 + count * 2, timeoutMs) ?: return null
        if (!validateResponse(resp, slaveId, 0x04)) return null
        val byteCount = resp[2].toInt() and 0xFF
        if (byteCount < count * 2) return null
        return IntArray(count) { i ->
            ((resp[3 + i * 2].toInt() and 0xFF) shl 8) or
            (resp[4 + i * 2].toInt() and 0xFF)
        }
    }

    // Результат сырой транзакции для сканера шины — с разбором причины
    // неудачи. Обычные read*/write* выше для остального приложения
    // намеренно сводят любую неудачу к null/false (там это верное решение
    // — вызывающему коду важен только факт "не получилось"), но технику,
    // разбирающему незнакомое устройство, разница принципиальна: "нет
    // ответа" (адрес не занят/провод не подключён), "битый CRC" (наводка,
    // не тот адрес отозвался) и "код ошибки устройства" (адрес существует,
    // но не поддерживает именно эту функцию/регистр) — три разных вывода,
    // три разных следующих шага.
    data class ScanResult(
        val status: String, // "ok" | "no_response" | "bad_crc" | "exception"
        val exceptionCode: Int? = null,
        val data: ByteArray? = null, // только данные (без заголовка/CRC), для "ok"
    )

    // FC06 — запись одиночного регистра с разбором статуса (ok/no_response/
    // bad_crc/exception), в отличие от writeSingleRegister() (только bool).
    // Нужен визарду смены Slave ID: там принципиально различать "тишина"
    // (нормальный ответ модуля на команду фиксации настроек — он в этот
    // момент занят записью EEPROM и не обслуживает UART) от "код исключения"
    // (реальная ошибка, есть что показать оператору). Одна попытка, без
    // ретраев — как и везде при записи в сканере.
    fun scanWriteSingleRegister(
        slaveId: Int,
        addr: Int,
        value: Int,
        timeoutMs: Long,
    ): ScanResult {
        val req = appendCrc(
            byteArrayOf(
                slaveId.toByte(), 0x06.toByte(),
                (addr shr 8).toByte(), addr.toByte(),
                (value shr 8).toByte(), value.toByte(),
            )
        )
        ioLock.lock()
        try {
            val out = outputStream ?: return ScanResult("no_response")
            if (inputStream == null) return ScanResult("no_response")
            return try {
                out.write(req)
                out.flush()
                Thread.sleep(20) // межфреймовая пауза, как и в sendAndReceive

                // Успешный ответ FC06 — ровно 8 байт, эхо заголовка запроса
                // целиком (адрес+значение), без отдельного поля данных.
                val resp = readWithTimeout(8, timeoutMs)
                if (resp.size < 5) return ScanResult("no_response")
                if (!checkCrc(resp)) return ScanResult("bad_crc")
                if ((resp[0].toInt() and 0xFF) != slaveId) return ScanResult("no_response")

                val respFc = resp[1].toInt() and 0xFF
                if (respFc == (0x06 or 0x80)) {
                    return ScanResult("exception", exceptionCode = resp[2].toInt() and 0xFF)
                }
                if (respFc != 0x06 || resp.size < 8) return ScanResult("no_response")
                ScanResult("ok")
            } catch (e: Exception) {
                Log.e(TAG, "scanWriteSingleRegister error: $e")
                ScanResult("no_response")
            }
        } finally {
            ioLock.unlock()
        }
    }

    // FC15 (0x0F) — запись нескольких катушек одним кадром. Отдельно от
    // scanTransact: та функция построена под чтение (расчёт expectedDataBytes
    // и разбор ответа предполагают данные в теле ответа), а успешный ответ
    // FC15 — это эхо заголовка (адрес+количество), без данных вообще. Как и
    // остальные операции записи в сканере — ровно одна попытка, без ретраев
    // (правило проекта: повторная слепая запись способна оставить устройство
    // в состоянии, которое потом трудно разобрать).
    //
    // Несмотря на имя (изначально писалась под ручной инструмент сканера),
    // теперь используется и в ModbusChannel.safeAllOff() — единственный
    // способ выключить несколько нагрузок одним кадром вместо серии FC05.
    fun scanWriteMultipleCoils(
        slaveId: Int,
        addr: Int,
        values: List<Boolean>,
        timeoutMs: Long,
    ): ScanResult {
        val count = values.size
        val byteCount = (count + 7) / 8
        val coilBytes = ByteArray(byteCount)
        for (i in values.indices) {
            if (values[i]) {
                coilBytes[i / 8] = (coilBytes[i / 8].toInt() or (1 shl (i % 8))).toByte()
            }
        }
        val header = byteArrayOf(
            slaveId.toByte(), 0x0F.toByte(),
            (addr shr 8).toByte(), addr.toByte(),
            (count shr 8).toByte(), count.toByte(),
            byteCount.toByte(),
        )
        val req = appendCrc(header + coilBytes)
        ioLock.lock()
        try {
            val out = outputStream ?: return ScanResult("no_response")
            if (inputStream == null) return ScanResult("no_response")
            return try {
                out.write(req)
                out.flush()
                Thread.sleep(20) // межфреймовая пауза, как и в sendAndReceive

                // Успешный ответ FC15 — ровно 8 байт: адрес+фн+старт(2)+
                // количество(2)+CRC(2), без тела данных.
                val resp = readWithTimeout(8, timeoutMs)
                if (resp.size < 5) return ScanResult("no_response")
                if (!checkCrc(resp)) return ScanResult("bad_crc")
                if ((resp[0].toInt() and 0xFF) != slaveId) return ScanResult("no_response")

                val respFc = resp[1].toInt() and 0xFF
                if (respFc == (0x0F or 0x80)) {
                    return ScanResult("exception", exceptionCode = resp[2].toInt() and 0xFF)
                }
                if (respFc != 0x0F || resp.size < 8) return ScanResult("no_response")
                ScanResult("ok")
            } catch (e: Exception) {
                Log.e(TAG, "scanWriteMultipleCoils error: $e")
                ScanResult("no_response")
            }
        } finally {
            ioLock.unlock()
        }
    }

    // FC16 (0x10) — запись нескольких регистров одним кадром. Тот же принцип
    // эхо-ответа без тела, что и у scanWriteMultipleCoils (FC15) выше —
    // отдельно от обычного writeMultipleRegisters (который возвращает
    // Boolean для внутренних вызовов кода приложения): ручному инструменту
    // сканера нужно различать три исхода (нет ответа / плохой CRC / код
    // исключения устройства), а не просто успех/неудачу. Понадобилась для
    // устройств без FC06 (Chint DDSU666 — единственная функция записи у
    // него FC16, даже для одного регистра).
    fun scanWriteMultipleRegisters(
        slaveId: Int,
        addr: Int,
        values: List<Int>,
        timeoutMs: Long,
    ): ScanResult {
        val count = values.size
        val data = ByteArray(count * 2)
        for (i in values.indices) {
            data[i * 2] = (values[i] shr 8).toByte()
            data[i * 2 + 1] = values[i].toByte()
        }
        val header = byteArrayOf(
            slaveId.toByte(), 0x10.toByte(),
            (addr shr 8).toByte(), addr.toByte(),
            (count shr 8).toByte(), count.toByte(),
            data.size.toByte(),
        )
        val req = appendCrc(header + data)
        ioLock.lock()
        try {
            val out = outputStream ?: return ScanResult("no_response")
            if (inputStream == null) return ScanResult("no_response")
            return try {
                out.write(req)
                out.flush()
                Thread.sleep(20) // межфреймовая пауза, как и в sendAndReceive

                // Успешный ответ FC16 — ровно 8 байт: адрес+фн+старт(2)+
                // количество(2)+CRC(2), без тела данных (как и FC15).
                val resp = readWithTimeout(8, timeoutMs)
                if (resp.size < 5) return ScanResult("no_response")
                if (!checkCrc(resp)) return ScanResult("bad_crc")
                if ((resp[0].toInt() and 0xFF) != slaveId) return ScanResult("no_response")

                val respFc = resp[1].toInt() and 0xFF
                if (respFc == (0x10 or 0x80)) {
                    return ScanResult("exception", exceptionCode = resp[2].toInt() and 0xFF)
                }
                if (respFc != 0x10 || resp.size < 8) return ScanResult("no_response")
                ScanResult("ok")
            } catch (e: Exception) {
                Log.e(TAG, "scanWriteMultipleRegisters error: $e")
                ScanResult("no_response")
            }
        } finally {
            ioLock.unlock()
        }
    }

    // funcCode напрямую (0x01/0x02/0x03/0x04) — сканеру нужны все четыре,
    // без привязки к типу результата, который для каждой функции свой.
    fun scanTransact(
        slaveId: Int,
        funcCode: Int,
        addr: Int,
        count: Int,
        timeoutMs: Long,
    ): ScanResult {
        val req = buildRequest(slaveId, funcCode, addr, count)
        val expectedDataBytes = if (funcCode == 0x01 || funcCode == 0x02) {
            1 + ((count + 7) / 8) // 1 байт byte-count + сами биты
        } else {
            1 + count * 2 // 1 байт byte-count + сами регистры
        }
        ioLock.lock()
        try {
            val out = outputStream ?: return ScanResult("no_response")
            if (inputStream == null) return ScanResult("no_response")
            return try {
                out.write(req)
                out.flush()
                Thread.sleep(20) // межфреймовая пауза, как и в sendAndReceive

                // Ждём столько же, сколько ожидали бы от успешного ответа —
                // кадр с кодом ошибки короче (5 байт: slave+fc|0x80+code+CRC),
                // readWithTimeout всё равно вернёт раньше срока, как только
                // наберёт эти 5 байт (внутренний цикл проверяет buffer.size
                // против затребованного количества, здесь оно избыточно —
                // это ожидаемо и не мешает разбору ниже).
                val resp = readWithTimeout(2 + expectedDataBytes + 2, timeoutMs)
                if (resp.size < 5) return ScanResult("no_response")
                if (!checkCrc(resp)) return ScanResult("bad_crc")
                if ((resp[0].toInt() and 0xFF) != slaveId) return ScanResult("no_response")

                val respFc = resp[1].toInt() and 0xFF
                if (respFc == (funcCode or 0x80)) {
                    return ScanResult("exception", exceptionCode = resp[2].toInt() and 0xFF)
                }
                if (respFc != funcCode || resp.size < 2 + expectedDataBytes + 2) {
                    return ScanResult("no_response")
                }
                ScanResult("ok", data = resp.copyOfRange(3, 2 + expectedDataBytes))
            } catch (e: Exception) {
                Log.e(TAG, "scanTransact error: $e")
                ScanResult("no_response")
            }
        } finally {
            ioLock.unlock()
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
            val inp = inputStream ?: return null
            return try {
                // Запоздавший ответ на ПРЕДЫДУЩИЙ запрос (таймаут 150 мс
                // короче, чем иногда отвечает устройство) лежит в буфере и
                // был бы принят за ответ на этот — CRC у него верный, а
                // данные чужие. Перед каждым запросом буфер очищается.
                val dropped = drainInput(inp)
                if (dropped > 0) Log.w(TAG, "stale bytes dropped before request: $dropped")
                out.write(request)
                out.flush()
                Thread.sleep(20) // межфреймовая пауза

                val resp = readWithTimeout(expectedBytes + 2, timeoutMs) // +2 CRC
                if (resp.size < expectedBytes + 2) {
                    Log.w(TAG, "short response: ${resp.size} bytes")
                    return null
                }
                if (!checkCrc(resp)) {
                    Log.w(TAG, "CRC error")
                    return null
                }
                resp
            } catch (e: Exception) {
                Log.e(TAG, "sendAndReceive error: $e")
                null
            }
        } finally {
            ioLock.unlock()
        }
    }

    // Выбрасывает всё, что уже лежит во входном буфере. Возвращает число
    // выброшенных байт. internal — для юнит-теста.
    internal fun drainInput(inp: java.io.InputStream): Int {
        var total = 0
        try {
            while (true) {
                val available = inp.available()
                if (available <= 0) break
                val skipped = inp.skip(available.toLong()).toInt()
                if (skipped <= 0) {
                    val read = inp.read(ByteArray(available))
                    if (read <= 0) break
                    total += read
                } else {
                    total += skipped
                }
            }
        } catch (e: java.io.IOException) {
            // чтение буфера не удалось — запрос всё равно отправляется
        }
        return total
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
            Log.w(TAG, "Modbus exception: ${resp[2].toInt() and 0xFF}")
            return false
        }
        return respFc == fc
    }

    private fun appendCrc(data: ByteArray): ByteArray {
        val crc = calcCrc(data)
        return data + byteArrayOf((crc and 0xFF).toByte(), ((crc shr 8) and 0xFF).toByte())
    }

    // internal, не private — доступ нужен юнит-тестам (src/test, тот же
    // модуль). Публичный API снаружи модуля не расширяет.
    internal fun checkCrc(data: ByteArray): Boolean {
        if (data.size < 3) return false
        val payload = data.copyOf(data.size - 2)
        val expected = calcCrc(payload)
        val got = (data[data.size - 2].toInt() and 0xFF) or
                  ((data[data.size - 1].toInt() and 0xFF) shl 8)
        return expected == got
    }

    internal fun calcCrc(data: ByteArray): Int {
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
