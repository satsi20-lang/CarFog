package com.example.dry_fog_app

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import com.hoho.android.usbserial.driver.CdcAcmSerialDriver
import com.hoho.android.usbserial.driver.Ch34xSerialDriver
import com.hoho.android.usbserial.driver.Cp21xxSerialDriver
import com.hoho.android.usbserial.driver.FtdiSerialDriver
import com.hoho.android.usbserial.driver.ProlificSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Future
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

// Стенд «Терминал (стенд)» (1.10.9): терминал Nayax по MDB через адаптер
// Wafer MDB-RS232 с USB-выходом. Только ручная проверка из сервисного меню —
// боевая оплата этим классом не пользуется. Отдельный путь от шины Modbus:
// UsbManager/UsbDeviceConnection, свой поток чтения, к ttyS4 и ioLock
// ModbusChannel не прикасается.
//
// Порт: 9600 8N1. Команды — байтами, ответы адаптера — текстом из
// hex-символов (см. MdbCashlessProtocol). Сам стенд ничего не шлёт без
// нажатия кнопки.
class MdbUsbBench(private val context: Context) : MethodChannel.MethodCallHandler {

    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    val log = MdbBenchLog(
        context.getExternalFilesDir(null)?.let { File(it, LOG_FILE) }
    )

    private val lock = Any()
    // Закрытие порта — на своём фоновом потоке (главный поток не ждёт USB).
    private val closer = MdbPortCloser()
    private var port: UsbSerialPort? = null
    private var portDevice: String? = null
    private var reader: MdbFrameReader? = null
    private var readerThread: Thread? = null
    // Ожидающее открытие после диалога разрешения: имя устройства и драйвер.
    private var pendingOpen: Pair<String, String>? = null
    // Последний разобранный ответ на setup (масштаб/знаки для vend). Живёт
    // только пока открыт порт: closePort сбрасывает, и после повторного
    // открытия vend не работает до нового ответа на setup.
    @Volatile
    private var setupReply: MdbCashlessProtocol.SetupReply? = null
    // Номер сеанса порта. Поток чтения при остановке отдаёт недочитанное
    // сообщение — ответ на setup из закрытого сеанса не должен вернуть
    // setupReply после сброса.
    @Volatile
    private var session = 0L

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val device = deviceExtra(intent)
            when (intent.action) {
                ACTION_PERMISSION -> {
                    val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    val pending = synchronized(lock) { pendingOpen.also { pendingOpen = null } }
                    log.info(now(), "разрешение на ${device?.deviceName ?: "?"}: " +
                        if (granted) "выдано" else "НЕ выдано")
                    if (granted && pending != null && device?.deviceName == pending.first) {
                        // Открытие — блокирующий USB-обмен, не на главном потоке.
                        Thread { openNow(pending.first, pending.second) }.start()
                    }
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> {
                    log.info(now(), "USB-устройство отключено: ${device?.deviceName ?: "?"}")
                    if (device != null && device.deviceName == synchronized(lock) { portDevice }) {
                        closePort("адаптер отключён на ходу")
                    }
                }
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> {
                    log.info(now(), "USB-устройство подключено: ${device?.let(::describe) ?: "?"}")
                }
            }
        }
    }

    init {
        val filter = IntentFilter().apply {
            addAction(ACTION_PERMISSION)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        }
        // NOT_EXPORTED: свой PendingIntent и защищённые системные рассылки
        // доставляются, рассылки других приложений — нет.
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }

    // Из onDestroy (главный поток): закрытие уходит в фон, не ждём.
    fun release() {
        closePort("приложение закрывает экран")
        closer.shutdown()
        try {
            context.unregisterReceiver(receiver)
        } catch (e: IllegalArgumentException) {
            // Уже снят.
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "listDevices" -> result.success(listDevices())
                "open" -> result.success(
                    open(call.argument<String>("device") ?: "", call.argument<String>("driver") ?: "auto")
                )
                "close" -> {
                    // Фоновая очередь канала, не главный поток — здесь можно
                    // дождаться закрытия, чтобы статус на экране был точным.
                    closePort("кнопка «Закрыть порт»")?.get(CLOSE_WAIT_MS, TimeUnit.MILLISECONDS)
                    result.success(null)
                }
                "status" -> result.success(status())
                "command" -> result.success(command(call))
                "vendPreview" -> result.success(vendPreview(call.argument<String>("amount") ?: ""))
                "raw" -> result.success(sendRaw(call.argument<String>("hex") ?: ""))
                "getLog" -> {
                    val since = (call.argument<Number>("since") ?: 0).toLong()
                    result.success(log.since(since).map { mapOf("seq" to it.seq, "line" to it.line) })
                }
                "allLog" -> result.success(log.all().joinToString("\n") { it.line })
                "clearLog" -> {
                    log.clear()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            // Любая ошибка (сумма не кратна шагу, нет порта, нет setup) — в
            // журнал стенда и на экран, приложение не падает.
            log.info(now(), "ошибка ${call.method}: ${e.message ?: e}")
            result.error("MDB", e.message ?: e.toString(), null)
        }
    }

    private fun listDevices(): List<Map<String, Any?>> {
        val list = usb.deviceList.values.sortedBy { it.deviceName }
        log.info(now(), "найдено USB-устройств: ${list.size}")
        return list.map { d ->
            val driver = UsbSerialProber.getDefaultProber().probeDevice(d)
            log.info(now(), "  ${describe(d)}" +
                ", драйвер: ${driver?.javaClass?.simpleName ?: "не найден"}")
            mapOf(
                "device" to d.deviceName,
                "vendorId" to d.vendorId,
                "productId" to d.productId,
                "manufacturer" to safe { d.manufacturerName },
                "product" to safe { d.productName },
                "deviceClass" to d.deviceClass,
                "interfaceClasses" to (0 until d.interfaceCount).map { d.getInterface(it).interfaceClass },
                "hasPermission" to usb.hasPermission(d),
                "driver" to driver?.javaClass?.simpleName,
            )
        }
    }

    // Возвращает "opened", "permission_requested" или бросает с текстом ошибки.
    private fun open(deviceName: String, driver: String): String {
        val device = usb.deviceList[deviceName] ?: throw IOException("устройство $deviceName не найдено")
        synchronized(lock) {
            if (port != null) throw IOException("порт уже открыт ($portDevice), сначала закройте")
        }
        if (!usb.hasPermission(device)) {
            synchronized(lock) { pendingOpen = deviceName to driver }
            val intent = Intent(ACTION_PERMISSION).setPackage(context.packageName)
            // Android 12+: система дописывает в intent EXTRA_DEVICE и
            // EXTRA_PERMISSION_GRANTED — PendingIntent обязан быть изменяемым.
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            val pi = PendingIntent.getBroadcast(context, 0, intent, flags or PendingIntent.FLAG_UPDATE_CURRENT)
            log.info(now(), "запрошено разрешение на ${describe(device)} — ждём ответа системного диалога")
            usb.requestPermission(device, pi)
            return "permission_requested"
        }
        openNow(deviceName, driver)
        return "opened"
    }

    // Только с фонового потока (канал или поток после разрешения).
    private fun openNow(deviceName: String, driverName: String) {
        try {
            // Закрытие прежнего сеанса могло ещё не доработать — не открываем
            // то же устройство поверх него.
            closer.drain()
            val device = usb.deviceList[deviceName] ?: throw IOException("устройство $deviceName пропало")
            val driver = pickDriver(device, driverName)
                ?: throw IOException("нет драйвера для ${describe(device)} (выберите драйвер вручную)")
            val connection = usb.openDevice(device) ?: throw IOException("openDevice вернул null (нет разрешения?)")
            val p = driver.ports.firstOrNull() ?: throw IOException("у драйвера нет портов")
            try {
                p.open(connection)
                p.setParameters(BAUD, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
            } catch (e: Exception) {
                try { p.close() } catch (ignored: Exception) {}
                throw e
            }
            val mySession = synchronized(lock) { ++session }
            val r = MdbFrameReader(
                port = { buf, t -> p.read(buf, t) },
                onFrame = { d, f, l -> onFrame(d, f, l, mySession) },
                onError = { e -> closePort("ошибка чтения: ${e.message ?: e}") },
            )
            synchronized(lock) {
                port = p
                portDevice = deviceName
                reader = r
                readerThread = Thread(r::run, "mdb-bench-reader").apply {
                    isDaemon = true
                    start()
                }
            }
            log.info(now(), "порт открыт: ${describe(device)}, ${driver.javaClass.simpleName}, $BAUD 8N1")
        } catch (e: Exception) {
            log.info(now(), "не удалось открыть порт: ${e.message ?: e}")
            throw e
        }
    }

    private fun pickDriver(device: UsbDevice, name: String): UsbSerialDriver? = when (name) {
        "ftdi" -> FtdiSerialDriver(device)
        "ch34x" -> Ch34xSerialDriver(device)
        "cp21xx" -> Cp21xxSerialDriver(device)
        "prolific" -> ProlificSerialDriver(device)
        "cdc" -> CdcAcmSerialDriver(device)
        else -> UsbSerialProber.getDefaultProber().probeDevice(device)
    }

    // Вызывается из потока чтения при ошибке, из приёмника при отключении
    // и из onDestroy (главный поток), кнопкой (фоновая очередь канала) —
    // повторный вызов безопасен. Состояние сбрасывается сразу, а закрытие USB
    // и ожидание потока чтения (не дольше 1 с) идут на потоке MdbPortCloser:
    // вызывающий поток не блокируется. null — порт и так был закрыт.
    private fun closePort(reason: String): Future<Boolean>? {
        val (p, r, t) = synchronized(lock) {
            val snapshot = Triple(port, reader, readerThread)
            port = null
            portDevice = null
            reader = null
            readerThread = null
            setupReply = null
            session++
            snapshot
        }
        if (p == null) return null
        return try {
            closer.close(
                stop = { r?.stop() },
                closePort = { p.close() },
                reader = t,
                onDone = { stopped ->
                    log.info(now(), "порт закрыт: $reason" +
                        if (stopped) "" else " (поток чтения не остановился за 1 с)")
                },
            )
        } catch (e: RejectedExecutionException) {
            // release() уже был: закрыть прямо здесь, без ожидания потока.
            r?.stop()
            try { p.close() } catch (ignored: Exception) {}
            null
        }
    }

    private fun onFrame(data: ByteArray, firstMs: Long, lastMs: Long, frameSession: Long) {
        val text = String(data, Charsets.US_ASCII)
        val setup = MdbCashlessProtocol.parseSetupReply(text)
        val note = if (setup != null) {
            val accepted = synchronized(lock) {
                (frameSession == session).also { if (it) setupReply = setup }
            }
            (if (accepted) "" else "[порт уже закрыт, не принят] ") +
                "ответ на setup: уровень ${setup.level}, масштаб ${setup.scale}, знаков ${setup.decimals}" +
                when (setup.checksumOk) {
                    true -> ", контрольная сумма верна"
                    false -> ", КОНТРОЛЬНАЯ СУММА НЕ СОШЛАСЬ"
                    null -> ""
                }
        } else {
            "разбор: " + MdbCashlessProtocol.describe(MdbCashlessProtocol.parseEvent(text))
        }
        log.rx(firstMs, lastMs, data, note)
    }

    private fun status(): Map<String, Any?> {
        val s = setupReply
        return synchronized(lock) {
            mapOf(
                "open" to (port != null),
                "device" to portDevice,
                "setupScale" to s?.scale,
                "setupDecimals" to s?.decimals,
                "logFile" to context.getExternalFilesDir(null)?.let { File(it, LOG_FILE).path },
            )
        }
    }

    private fun command(call: MethodCall): String {
        val name = call.argument<String>("name") ?: ""
        val item = call.argument<Int>("item") ?: 1
        val data = when (name) {
            "setup" -> MdbCashlessProtocol.SETUP
            "prices" -> MdbCashlessProtocol.PRICES
            "enable" -> MdbCashlessProtocol.ENABLE
            "disable" -> MdbCashlessProtocol.DISABLE
            "rcancel" -> MdbCashlessProtocol.READER_CANCEL
            "cancel" -> MdbCashlessProtocol.VEND_CANCEL
            "done" -> MdbCashlessProtocol.SESSION_COMPLETE
            "ok" -> MdbCashlessProtocol.vendSuccess(item)
            "id" -> MdbCashlessProtocol.requestId(ID_MANUFACTURER, ID_SERIAL, ID_MODEL, ID_VERSION)
            "vend" -> {
                // Сумма уже подтверждена в окне по ответу vendPreview: сюда
                // приходят те самые единицы и масштаб/знаки, по которым они
                // посчитаны. Если ответ на setup с тех пор сменился или
                // пропал — не отправляем.
                val s = requireSetup()
                val units = call.argument<Int>("units") ?: throw IllegalArgumentException("нет суммы в единицах")
                if (call.argument<Int>("scale") != s.scale || call.argument<Int>("decimals") != s.decimals) {
                    throw IllegalStateException(
                        "ответ на setup изменился после подтверждения — запросите оплату заново"
                    )
                }
                MdbCashlessProtocol.vendRequest(units, item)
            }
            else -> throw IllegalArgumentException("неизвестная команда $name")
        }
        val label = if (name == "vend") {
            "vend " + MdbCashlessProtocol.formatAmount(
                call.argument<Int>("units") ?: 0, call.argument<Int>("scale") ?: 1,
                call.argument<Int>("decimals") ?: 2,
            ) + " €"
        } else name
        send(data, label)
        return MdbCashlessProtocol.toHex(data)
    }

    // Без ответа на setup масштаб и знаки неизвестны — сумма ушла бы
    // неверной. Не догадываемся, а отказываем.
    private fun requireSetup(): MdbCashlessProtocol.SetupReply = setupReply
        ?: throw IllegalStateException("нет ответа на setup — сначала нажмите setup и дождитесь ответа")

    // Расчёт запроса оплаты БЕЗ отправки — для окна подтверждения. В окне
    // показывается сумма, обратно пересчитанная из единиц, которые уйдут в
    // адаптер, а не введённый текст.
    private fun vendPreview(amount: String): Map<String, Any> {
        val s = requireSetup()
        val units = MdbCashlessProtocol.priceUnits(amount, s.scale, s.decimals)
        return mapOf(
            "units" to units,
            "scale" to s.scale,
            "decimals" to s.decimals,
            "amount" to MdbCashlessProtocol.formatAmount(units, s.scale, s.decimals),
            "hex" to MdbCashlessProtocol.toHex(MdbCashlessProtocol.vendRequest(units, 1)),
        )
    }

    private fun sendRaw(hex: String): String {
        val data = MdbCashlessProtocol.parseHex(hex)
        send(data, "raw")
        return MdbCashlessProtocol.toHex(data)
    }

    private fun send(data: ByteArray, label: String) {
        val p = synchronized(lock) { port } ?: throw IOException("порт не открыт")
        try {
            p.write(data, WRITE_TIMEOUT_MS)
        } catch (e: IOException) {
            log.info(now(), "ошибка отправки $label: ${e.message ?: e}")
            throw e
        }
        log.tx(now(), data, label)
    }

    private fun describe(d: UsbDevice): String =
        "%s VID %04X PID %04X «%s / %s» класс %d".format(
            d.deviceName, d.vendorId, d.productId,
            safe { d.manufacturerName } ?: "?", safe { d.productName } ?: "?", d.deviceClass
        )

    private fun deviceExtra(intent: Intent): UsbDevice? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }

    // Имена производителя/продукта на некоторых прошивках требуют разрешения.
    private fun <T> safe(f: () -> T): T? = try { f() } catch (e: Exception) { null }

    private fun now() = System.currentTimeMillis()

    companion object {
        const val CHANNEL = "com.carfog.dryfog/mdb_bench"
        const val LOG_FILE = "mdb_bench.log"
        private const val ACTION_PERMISSION = "ee.carfog.dryfog.MDB_USB_PERMISSION"
        private const val BAUD = 9600
        private const val WRITE_TIMEOUT_MS = 500
        // Ожидание закрытия по кнопке: join потока чтения (1 с) + запас.
        private const val CLOSE_WAIT_MS = 2000L

        // Данные для 17 00 (передача ID автомата). Какие значения ждёт Nayax,
        // не подтверждено — только для проверки, что команда проходит.
        const val ID_MANUFACTURER = "CRF"
        const val ID_SERIAL = "000000000001"
        const val ID_MODEL = "DRYFOG"
        const val ID_VERSION = 0x0110
    }
}
