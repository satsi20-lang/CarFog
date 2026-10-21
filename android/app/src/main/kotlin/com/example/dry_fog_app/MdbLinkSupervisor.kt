package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event
import com.example.dry_fog_app.MdbCommandQueue.Result

// Связь с терминалом Nayax в основном потоке оплаты (1.11.0, ТЗ раздел 7).
// Без Android-зависимостей: порт открывает/закрывает Io, команды идут через
// общую очередь MdbCommandQueue (одна за раз, ждать 00), время — подставные
// часы, вызывается с одного логического потока.
//
//   * Порт открывается, пока тип терминала mdb и стенд не занял порт
//     (раздел 7.2): setup → prices → enable (или disable, если оплата картой
//     сейчас не нужна: out_of_service, обслуживание — раздел 6.11).
//   * Раз в 60 с в простое — setup (раздел 7.4). Молчание или FF:
//     переоткрыть порт, setup, prices, enable. Три неудачи подряд —
//     terminal_offline, оплата картой недоступна до восстановления
//     (terminal_recovered). Нет устройства 0403:6001 — тоже terminal_offline
//     (раздел 7.3). Событие не чаще раза в 5 минут.
//   * 10 04 вне оплаты — 13 04; 10 03 вне оплаты (клиент приложил карту, не
//     выбрав запах) — 13 04 без vend и событие для подсказки (решение
//     владельца 21.10.2026). Нераспознанный кадр — в журнал и событие.
class MdbLinkSupervisor(
    private val queue: MdbCommandQueue,
    private val io: Io,
    private val note: (String) -> Unit,
    private val emit: (type: String, data: Map<String, Any?>) -> Unit,
    private val clock: () -> Long,
) {
    interface Io {
        fun devicePresent(): Boolean
        // true — порт открыт.
        fun openPort(): Boolean
        fun closePort(reason: String)
    }

    enum class State(val title: String) {
        INACTIVE("оплата картой выключена (тип терминала не mdb)"),
        SERVICE("терминал занят сервисным режимом"),
        NO_DEVICE("адаптер 0403:6001 не найден"),
        INITIALIZING("настройка терминала"),
        READY("готов"),
        RECOVERING("связь потеряна, восстановление"),
        OFFLINE("терминал недоступен"),
    }

    var state = State.INACTIVE
        private set
    private var active = false
    private var service = false
    private var desiredEnabled = false
    // Что реально отправлено и подтверждено ACK.
    var readerEnabled = false
        private set
    var inSession = false
        private set
    var setupReply: MdbCashlessProtocol.SetupReply? = null
        private set
    var consecutiveFailures = 0
        private set
    // Последнее неожиданное событие/кадр — для диагностики.
    var unexpectedFrames = 0
        private set

    // Поток оплаты (этап 3) держит сессию сам — тогда 10 03/10 04 не наши.
    var paymentOwnsSession = false

    private var portOpen = false
    private var nextAttemptAt = 0L
    private var lastPollAt = 0L
    private var pollInFlight = false
    private var initToken = 0
    private var offlineReported = false
    private var lastOfflineEventAt: Long? = null

    private val closer = MdbSessionCloser(queue, note, clock, { r ->
        if (r.ended) inSession = false
    })

    val cardAvailable: Boolean
        get() = state == State.READY && readerEnabled && !inSession

    // ---- входы ----

    fun setActive(value: Boolean) {
        if (active == value) return
        active = value
        if (!value) shutDown("тип терминала не mdb", State.INACTIVE) else wake()
    }

    // Стенд занял порт (true) или отпустил (false).
    fun setService(value: Boolean) {
        if (service == value) return
        service = value
        if (value) shutDown("порт передан стенду", State.SERVICE) else wake()
    }

    fun setDesiredEnabled(value: Boolean) {
        if (desiredEnabled == value) return
        desiredEnabled = value
        if (state == State.READY) applyReaderState()
    }

    // Адаптер появился / пропал (USB_DEVICE_ATTACHED/DETACHED).
    fun onDeviceChanged() = wake()

    fun onPortLost(reason: String) {
        if (!portOpen) return
        portOpen = false
        // Снятые с очереди команды текущей настройки не считаются отдельными неудачами.
        initToken++
        queue.clear()
        note("порт терминала потерян: $reason")
        failure("порт потерян")
    }

    fun onEvent(e: Event) {
        if (!portOpen) return
        closer.onEvent(e)
        when (e) {
            is Event.BeginSession -> {
                inSession = true
                if (!paymentOwnsSession && !closer.active) {
                    note("10 03 вне оплаты: клиент приложил карту, не выбрав запах — 13 04 без vend")
                    emit("card_tapped_without_flavor", mapOf("funds" to e.funds))
                    closer.start("10 03 вне оплаты")
                }
            }
            Event.SessionCancelRequest -> if (!paymentOwnsSession && !closer.active) {
                closer.start("10 04 вне оплаты")
            }
            Event.EndSession -> inSession = false
            is Event.Unrecognized -> {
                unexpectedFrames++
                emit("terminal_unexpected_frame", mapOf("reason" to e.reason))
            }
            else -> Unit
        }
    }

    fun tick() {
        closer.tick()
        val now = clock()
        when (state) {
            State.INACTIVE, State.SERVICE, State.INITIALIZING -> Unit
            State.NO_DEVICE, State.RECOVERING, State.OFFLINE ->
                if (now >= nextAttemptAt) tryOpen()
            State.READY -> if (!pollInFlight && !inSession && !paymentOwnsSession && !closer.active &&
                now - lastPollAt >= POLL_INTERVAL_MS) poll()
        }
    }

    // ---- внутреннее ----

    private fun wake() {
        if (!active || service) return
        if (state == State.READY || state == State.INITIALIZING) return
        nextAttemptAt = 0
        tryOpen()
    }

    private fun tryOpen() {
        if (!active || service) return
        if (!io.devicePresent()) {
            if (state != State.NO_DEVICE) note("адаптер терминала 0403:6001 не найден — оплата картой недоступна")
            state = State.NO_DEVICE
            reportOffline("no_device")
            nextAttemptAt = clock() + RETRY_OFFLINE_MS
            return
        }
        if (!portOpen) {
            portOpen = io.openPort()
            if (!portOpen) return failure("порт не открылся")
        }
        initialize()
    }

    private fun initialize() {
        // Пока идёт настройка, tick не начинает вторую (INITIALIZING).
        state = State.INITIALIZING
        val token = ++initToken
        readerEnabled = false
        queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.SETUP, "setup") { r, e ->
            if (token != initToken) return@Command
            val reply = (e as? Event.Setup)?.reply
            if (r != Result.ACK || reply == null) return@Command failure("setup: ${r.title}")
            setupReply = reply
            queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.PRICES, "prices") { r2, _ ->
                if (token != initToken) return@Command
                if (r2 != Result.ACK) return@Command failure("prices: ${r2.title}")
                val enable = desiredEnabled
                val cmd = if (enable) MdbCashlessProtocol.ENABLE else MdbCashlessProtocol.DISABLE
                queue.enqueue(MdbCommandQueue.Command(cmd, if (enable) "enable" else "disable") { r3, _ ->
                    if (token != initToken) return@Command
                    if (r3 != Result.ACK) return@Command failure("${if (enable) "enable" else "disable"}: ${r3.title}")
                    readerEnabled = enable
                    ready()
                })
            })
        })
    }

    private fun ready() {
        state = State.READY
        consecutiveFailures = 0
        lastPollAt = clock()
        note("терминал готов, приём карт ${if (readerEnabled) "включён" else "выключен"}")
        if (offlineReported) {
            offlineReported = false
            emit("terminal_recovered", emptyMap())
        }
        // Пока шла настройка, нужное состояние могло смениться.
        if (readerEnabled != desiredEnabled) applyReaderState()
    }

    private fun applyReaderState() {
        val enable = desiredEnabled
        val token = initToken
        queue.enqueue(MdbCommandQueue.Command(
            if (enable) MdbCashlessProtocol.ENABLE else MdbCashlessProtocol.DISABLE,
            if (enable) "enable" else "disable",
        ) { r, _ ->
            if (token != initToken) return@Command
            if (r == Result.ACK) readerEnabled = enable else failure("${if (enable) "enable" else "disable"}: ${r.title}")
        })
    }

    private fun poll() {
        pollInFlight = true
        lastPollAt = clock()
        val token = initToken
        queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.SETUP, "опрос связи (раз в 60 с)") { r, e ->
            pollInFlight = false
            if (token != initToken) return@Command
            if (r == Result.ACK && e is Event.Setup) {
                setupReply = e.reply
            } else {
                failure("опрос: ${r.title}")
            }
        })
    }

    // Молчание/FF/порт: переоткрыть и заново setup, prices, enable. Три подряд —
    // terminal_offline и оплата картой недоступна до восстановления.
    private fun failure(why: String) {
        consecutiveFailures++
        initToken++
        pollInFlight = false
        readerEnabled = false
        note("связь с терминалом: $why (неудач подряд: $consecutiveFailures)")
        if (portOpen) {
            portOpen = false
            queue.clear()
            io.closePort(why)
        }
        if (consecutiveFailures >= MAX_FAILURES) {
            if (state != State.OFFLINE) note("терминал недоступен после $MAX_FAILURES неудач подряд — оплата картой выключена до восстановления")
            state = State.OFFLINE
            reportOffline("no_answer")
            nextAttemptAt = clock() + RETRY_OFFLINE_MS
        } else {
            state = State.RECOVERING
            nextAttemptAt = clock() + RETRY_SOON_MS
        }
    }

    private fun shutDown(why: String, next: State) {
        initToken++
        pollInFlight = false
        readerEnabled = false
        inSession = false
        consecutiveFailures = 0
        if (closer.active) closer.abandon()
        if (portOpen) {
            portOpen = false
            queue.clear()
            io.closePort(why)
        }
        state = next
        note("терминал: ${next.title}")
    }

    // Не чаще раза в 5 минут и только при смене статуса (разделы 7.3, 7.4).
    private fun reportOffline(reason: String) {
        if (offlineReported) return
        val last = lastOfflineEventAt
        if (last != null && clock() - last < OFFLINE_EVENT_MIN_INTERVAL_MS) return
        offlineReported = true
        lastOfflineEventAt = clock()
        emit("terminal_offline", mapOf("reason" to reason))
    }

    companion object {
        const val POLL_INTERVAL_MS = 60_000L
        const val MAX_FAILURES = 3
        // Повтор после первой/второй неудачи — быстро; в offline — раз в минуту.
        const val RETRY_SOON_MS = 5_000L
        const val RETRY_OFFLINE_MS = 60_000L
        const val OFFLINE_EVENT_MIN_INTERVAL_MS = 5 * 60_000L
    }
}
