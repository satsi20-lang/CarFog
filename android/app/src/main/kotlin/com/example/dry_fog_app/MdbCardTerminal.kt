package com.example.dry_fog_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbManager
import android.os.Build
import com.hoho.android.usbserial.driver.FtdiSerialDriver
import com.hoho.android.usbserial.driver.UsbSerialPort
import com.hoho.android.usbserial.driver.UsbSerialProber
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

// Терминал Nayax по MDB в основном потоке оплаты (1.11.0, ТЗ раздел 7).
// Тот же слой, что у стенда: MdbFrameReader (кадры \r\n), MdbCommandQueue
// (одна команда за раз, ждать 00), MdbSessionCloser, MdbPortCloser. Логика
// связи — MdbLinkSupervisor; здесь только USB, потоки и канал для Dart.
//
// Порт — только адаптер Wafer (FTDI FT232R, VID 0403 PID 6001). Разрешение
// USB должно быть выдано заранее (ТЗ раздел 3): окно разрешения в киоске
// отсюда не запрашивается — без разрешения порт не открывается, оплата
// картой недоступна, причина в журнале. Один владелец порта (раздел 7.2):
// пока стенд в сервисном режиме, этот класс порт не трогает.
//
// Вся автоматика — на одном логическом потоке mdb-card-logic.
class MdbCardTerminal(private val context: Context) : MethodChannel.MethodCallHandler {

    private val usb = context.getSystemService(Context.USB_SERVICE) as UsbManager
    // Полный журнал обмена (TX/RX) — во внешней папке приложения, рядом с
    // журналом стенда. Данных карты по MDB нет.
    private val log = MdbBenchLog(context.getExternalFilesDir(null)?.let { File(it, LOG_FILE) })

    private val logic = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "mdb-card-logic").apply { isDaemon = true }
    }
    private val portCloser = MdbPortCloser()

    // Поток логики.
    private var port: UsbSerialPort? = null
    private var reader: MdbFrameReader? = null
    private var readerThread: Thread? = null
    @Volatile
    private var portSession = 0L

    // События и строки журнала для Dart (забираются вызовом poll).
    private val outbox = ConcurrentLinkedQueue<Map<String, Any?>>()

    private val queue = MdbCommandQueue(
        send = { d, label -> sendNow(d, label) },
        note = ::note,
        clock = ::now,
    )
    private val supervisor = MdbLinkSupervisor(
        queue = queue,
        io = object : MdbLinkSupervisor.Io {
            override fun devicePresent() = findAdapter() != null
            override fun openPort() = openPortNow()
            override fun closePort(reason: String) = closePortNow(reason)
        },
        note = ::note,
        emit = { type, data -> outbox.add(mapOf("kind" to "event", "type" to type, "data" to data, "ts" to now())) },
        clock = ::now,
    )
    // Одна оплата картой (ТЗ раздел 6) — на той же очереди.
    private val payment = MdbCardPayment(
        queue = queue,
        note = ::note,
        emit = { type, data -> outbox.add(mapOf("kind" to "payment", "type" to type, "data" to data, "ts" to now())) },
        clock = ::now,
        setOwnsSession = { supervisor.paymentOwnsSession = it },
    ).also { p -> supervisor.onLinkDown = { p.portLost(it) } }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            val device = deviceExtra(intent) ?: return
            if (!isAdapter(device)) return
            when (intent.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> post {
                    note("адаптер терминала подключён: ${device.deviceName}")
                    supervisor.onDeviceChanged()
                }
                UsbManager.ACTION_USB_DEVICE_DETACHED -> post {
                    supervisor.onPortLost("адаптер отключён (${device.deviceName})")
                }
            }
        }
    }

    init {
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
        logic.scheduleWithFixedDelay({ guarded { supervisor.tick(); payment.tick(); queue.tick() } }, TICK_MS, TICK_MS, TimeUnit.MILLISECONDS)
    }

    fun release() {
        post { supervisor.setActive(false) }
        try {
            context.unregisterReceiver(receiver)
        } catch (e: IllegalArgumentException) {
            // Уже снят.
        }
        logic.shutdown()
        portCloser.shutdown()
    }

    // ---- владелец порта (раздел 7.2) ----

    // Стенд забирает порт: дождаться, пока основной поток его закроет.
    // Вызывать НЕ с главного потока.
    fun yieldPortToBench() {
        onLogic { supervisor.setService(true) }
        portCloser.drain()
    }

    fun takePortBack() = post { supervisor.setService(false) }

    // ---- канал для Dart ----

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "configure" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    val enabled = call.argument<Boolean>("desiredEnabled") ?: false
                    post {
                        supervisor.setDesiredEnabled(enabled)
                        supervisor.setActive(active)
                    }
                    result.success(null)
                }
                "poll" -> result.success(onLogic { status() } + mapOf("events" to drainOutbox()))
                // Экран «Приложите карту»: ждать 10 03 и сразу vend на сумму.
                "arm" -> result.success(onLogic {
                    check(supervisor.cardAvailable) { "card_unavailable:${supervisor.state.name}" }
                    val units = unitsOf(call.argument<Int>("cents") ?: 0)
                    payment.arm(
                        units,
                        (call.argument<Int>("flavorIndex") ?: 0) + 1,
                        (call.argument<Int>("refundWindowS") ?: 30) * 1000L,
                        call.argument<Boolean>("confirmEnabled") ?: true,
                    )
                    units
                })
                "updateAmount" -> result.success(onLogic {
                    val units = unitsOf(call.argument<Int>("cents") ?: 0)
                    payment.updateUnits(units)
                    units
                })
                "cancel" -> {
                    onLogic { payment.cancelByCustomer() }
                    result.success(null)
                }
                "disarm" -> {
                    onLogic { payment.disarm(call.argument<String>("reason") ?: "") }
                    result.success(null)
                }
                // Итог цикла после одобрения: 13 02 / 13 03 / ручной возврат.
                "finish" -> {
                    val ok = call.argument<Boolean>("success") ?: false
                    val reason = call.argument<String>("reason") ?: ""
                    onLogic { if (ok) payment.finishSuccess() else payment.finishFailure(reason) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("CARD", e.message ?: e.toString(), null)
        }
    }

    private fun status(): Map<String, Any?> = mapOf(
        "state" to supervisor.state.name,
        "stateTitle" to supervisor.state.title,
        "cardAvailable" to supervisor.cardAvailable,
        "readerEnabled" to supervisor.readerEnabled,
        "inSession" to supervisor.inSession,
        "consecutiveFailures" to supervisor.consecutiveFailures,
        "unexpectedFrames" to supervisor.unexpectedFrames,
        "setupScale" to supervisor.setupReply?.scale,
        "setupDecimals" to supervisor.setupReply?.decimals,
        "paymentState" to payment.state.name,
        "customerCanCancel" to payment.customerCanCancel,
    )

    // Центы → единицы терминала по ответу setup (ТЗ 4.4); не целое или
    // больше 65535 — платёж не начинать.
    private fun unitsOf(cents: Int): Int {
        val s = supervisor.setupReply ?: throw IllegalStateException("bad_amount:нет ответа setup")
        return MdbCashlessProtocol.unitsFromCents(cents, s.scale, s.decimals)
            ?: throw IllegalArgumentException("bad_amount:$cents центов не переводятся в единицы (масштаб ${s.scale}, знаков ${s.decimals})")
    }

    private fun drainOutbox(): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        while (true) out += outbox.poll() ?: break
        return out
    }

    // ---- USB (логический поток) ----

    private fun isAdapter(d: UsbDevice) = d.vendorId == VID && d.productId == PID

    private fun findAdapter(): UsbDevice? = usb.deviceList.values.firstOrNull(::isAdapter)

    private fun openPortNow(): Boolean {
        val device = findAdapter() ?: return false
        if (!usb.hasPermission(device)) {
            note("нет разрешения USB на адаптер ${device.deviceName} — окно разрешения в киоске не запрашиваем")
            return false
        }
        return try {
            // Закрытие прежнего сеанса могло ещё не доработать.
            portCloser.drain()
            val driver = UsbSerialProber.getDefaultProber().probeDevice(device) ?: FtdiSerialDriver(device)
            val connection = usb.openDevice(device) ?: throw IOException("openDevice вернул null")
            val p = driver.ports.first()
            try {
                p.open(connection)
                p.setParameters(BAUD, 8, UsbSerialPort.STOPBITS_1, UsbSerialPort.PARITY_NONE)
            } catch (e: Exception) {
                try { p.close() } catch (ignored: Exception) {}
                throw e
            }
            val mySession = ++portSession
            val r = MdbFrameReader(
                port = { buf, t -> p.read(buf, t) },
                onFrame = { d, f, l -> onFrame(d, f, l, mySession) },
                onError = { e -> post { if (mySession == portSession) supervisor.onPortLost("ошибка чтения: ${e.message ?: e}") } },
            )
            port = p
            reader = r
            readerThread = Thread(r::run, "mdb-card-reader").apply { isDaemon = true; start() }
            note("порт терминала открыт: ${device.deviceName}, $BAUD 8N1")
            true
        } catch (e: Exception) {
            note("порт терминала не открылся: ${e.message ?: e}")
            false
        }
    }

    private fun closePortNow(reason: String) {
        val p = port ?: return
        val r = reader
        val t = readerThread
        port = null
        reader = null
        readerThread = null
        portSession++
        try {
            portCloser.close(stop = { r?.stop() }, closePort = { p.close() }, reader = t)
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            r?.stop()
            try { p.close() } catch (ignored: Exception) {}
        }
        log.info(now(), "порт закрыт: $reason")
    }

    private fun sendNow(data: ByteArray, label: String) {
        val p = port ?: throw IOException("порт не открыт")
        p.write(data, WRITE_TIMEOUT_MS)
        log.tx(now(), data, label)
    }

    // Поток чтения: кадр сразу в журнал, разбор — на логическом потоке.
    private fun onFrame(data: ByteArray, firstMs: Long, lastMs: Long, frameSession: Long) {
        val e = MdbCashlessProtocol.parseFrame(String(data, Charsets.US_ASCII))
        log.rx(firstMs, lastMs, data, "разбор: " + MdbCashlessProtocol.describe(e))
        post {
            if (frameSession != portSession) return@post
            queue.onEvent(e)
            supervisor.onEvent(e)
            payment.onEvent(e)
        }
    }

    private fun note(text: String) {
        log.info(now(), text)
        outbox.add(mapOf("kind" to "log", "text" to text, "ts" to now()))
    }

    private fun post(f: () -> Unit) {
        try {
            logic.execute { guarded(f) }
        } catch (e: java.util.concurrent.RejectedExecutionException) {
            // Уже освобождён.
        }
    }

    private fun guarded(f: () -> Unit) {
        try {
            f()
        } catch (e: Exception) {
            log.info(now(), "ошибка логики терминала: ${e.message ?: e}")
        }
    }

    private fun <T> onLogic(f: () -> T): T = try {
        logic.submit(Callable { f() }).get(LOGIC_WAIT_MS, TimeUnit.MILLISECONDS)
    } catch (e: ExecutionException) {
        throw (e.cause as? Exception) ?: e
    }

    private fun deviceExtra(intent: Intent): UsbDevice? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
        }

    private fun now() = System.currentTimeMillis()

    companion object {
        const val CHANNEL = "com.carfog.dryfog/card_terminal"
        const val LOG_FILE = "mdb_terminal.log"
        const val VID = 0x0403
        const val PID = 0x6001
        private const val BAUD = 9600
        private const val WRITE_TIMEOUT_MS = 500
        private const val TICK_MS = 50L
        private const val LOGIC_WAIT_MS = 3000L
    }
}
