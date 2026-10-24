package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event
import com.example.dry_fog_app.MdbCommandQueue.Result

// Режим «одна тестовая оплата 0,10 €» стенда MDB (1.10.11, очередь команд —
// 1.10.12). Все команды — через MdbCommandQueue: одна за раз, следующая только
// после ACK 00 (или FF / таймаута 2 с) и не раньше 300 мс после него.
//
// setup → prices → enable → ждём 10 03 до 60 с → vend 10 ед. (один раз) →
//   10 05 на 10 ед. → 13 02 00 01 (ACK; FF/нет ACK — один повтор) →
//     пауза ≥ 1 с → закрытие сессии (MdbSessionCloser: 13 04, ACK, 10 07 до
//     10 с, один повтор) → 14 00;
//   10 05 на другую сумму / без суммы → 13 03 (возврат) → закрытие → 14 00;
//   10 06 / 10 04 → закрытие → 14 00;
//   vend получил FF или нет ACK → закрытие → 14 00;
//   10 03 без суммы или < 10 ед. → закрытие → 14 00.
// «УСПЕХ» — только если 10 05 на 10 ед., ACK на 13 02, ACK на 13 04 и 10 07.
// Иначе — статус по каждому шагу. Один логический поток стенда, без Android.
//
// Служебные тесты (1.10.13), тот же цикл до 10 05 на 10 ед.:
//   А «Задержка до подтверждения выдачи» (Mode.DELAY): после 10 05 ждём N с
//     (30/60/90/120) без автоматических ответов — все кадры только в журнал;
//     пришло 10 07 — ожидание прекращается («терминал закрыл сессию сам через
//     X с»); иначе 13 02 00 01 → пауза 1 с → закрытие сессии → 14 00.
//   Б «Возврат» (Mode.REFUND): после 10 05 пауза 1 с → 13 03 (ACK) → закрытие
//     сессии → 14 00; все кадры после 13 03 — в итог.
class MdbTestPayment(
    private val queue: MdbCommandQueue,
    private val note: (String) -> Unit,
    private val clock: () -> Long,
) {
    enum class Mode(val title: String) {
        NORMAL("одна тестовая оплата"),
        DELAY("тест А (задержка)"),
        REFUND("тест Б (возврат)"),
    }

    enum class State(val title: String) {
        IDLE("не запущена"),
        SETUP("setup: ждём ответ"),
        PRICES("prices: ждём ACK"),
        ENABLE("enable: ждём ACK"),
        WAIT_SESSION("приложите карту (ждём 10 03)"),
        VEND("vend 10 ед.: ждём ACK"),
        WAIT_VEND_RESULT("vend принят: ждём ответ терминала"),
        CANCEL("vend отменён (13 01): ждём ответ"),
        HOLD("тест А: ждём перед 13 02 (без ответов терминалу)"),
        REFUND_PAUSE("тест Б: пауза 1 с перед 13 03"),
        CONFIRM("13 02 00 01: ждём ACK"),
        PAUSE("пауза 1 с перед 13 04"),
        REFUND("13 03 (возврат): ждём ACK"),
        CLOSING("закрытие сессии: 13 04, ждём 10 07"),
        DISABLE("14 00: ждём ACK"),
        DONE("завершена"),
    }

    data class Outcome(
        val ok: Boolean,
        val text: String,
        // Сессия на терминале могла остаться открытой — владельцу: «нажмите done».
        val sessionMayHang: Boolean,
        // vend отправлен, а итога списания терминал не прислал (1.11.2): строку
        // на языке меню добавляет вкладка стенда — сверить в кабинете Nayax.
        val vendUnsettled: Boolean = false,
    )

    var state = State.IDLE
        private set
    var outcome: Outcome? = null
        private set
    val active: Boolean get() = state != State.IDLE && state != State.DONE

    private val closer = MdbSessionCloser(queue, note, clock, ::onSessionClosed)
    private var deadline = 0L
    private var pendingBegin: Event.BeginSession? = null
    private var sessionOpen = false
    // Итоги шагов для статуса.
    private var failure: String? = null
    private var approvedAmount: Int? = null
    private var approved = false
    private var vendSent = false
    private var moneySettled = false
    private var confirmAck: Boolean? = null
    private var refundResult: Result? = null
    private var closeReport: MdbSessionCloser.Report? = null
    private var disableResult: Result? = null
    private var portLost: String? = null
    // Служебные тесты А/Б.
    var mode = Mode.NORMAL
        private set
    private var holdMs = 0L
    private var approvedAt = 0L
    private var confirmSentAfterMs: Long? = null
    private val confirmResults = mutableListOf<Result>()
    private var closedByTerminalAfterMs: Long? = null
    private var refundSentAt: Long? = null
    // Кадры терминала во время ожидания (А) или после 13 03 (Б), с временем.
    private val observed = mutableListOf<String>()

    // Сколько осталось ждать в тесте А (для обратного отсчёта на экране).
    val holdRemainingMs: Long?
        get() = if (state == State.HOLD) maxOf(0L, deadline - clock()) else null

    fun start(mode: Mode = Mode.NORMAL, delaySec: Int = 0) {
        check(!active) { "тестовая оплата уже идёт" }
        if (mode == Mode.DELAY) {
            require(delaySec in DELAY_CHOICES) { "задержка теста А — только ${DELAY_CHOICES.joinToString("/")} с" }
        }
        this.mode = mode
        holdMs = delaySec * 1000L
        approvedAt = 0L
        confirmSentAfterMs = null
        confirmResults.clear()
        closedByTerminalAfterMs = null
        refundSentAt = null
        observed.clear()
        outcome = null
        pendingBegin = null
        sessionOpen = false
        failure = null
        approvedAmount = null
        approved = false
        vendSent = false
        moneySettled = false
        confirmAck = null
        refundResult = null
        closeReport = null
        disableResult = null
        portLost = null
        note("${mode.title}: старт (0,10 € = $UNITS ед., товар $ITEM" +
            (if (mode == Mode.DELAY) ", ожидание $delaySec с перед 13 02" else "") + ")")
        state = State.SETUP
        queue.enqueue(cmd(MdbCashlessProtocol.SETUP, "setup") { r, e ->
            if (state != State.SETUP) return@cmd
            val reply = (e as? Event.Setup)?.reply
            when {
                r != Result.ACK -> fail("setup: ${r.title}")
                reply == null -> fail("setup: ответ без данных настройки")
                unitsFor(reply) != UNITS ->
                    fail("по ответу setup (масштаб ${reply.scale}, знаков ${reply.decimals}) 0,10 € ≠ $UNITS ед.")
                else -> {
                    state = State.PRICES
                    queue.enqueue(cmd(MdbCashlessProtocol.PRICES, "prices") { r2, _ ->
                        if (state != State.PRICES) return@cmd
                        if (r2 != Result.ACK) return@cmd fail("prices: ${r2.title}")
                        state = State.ENABLE
                        queue.enqueue(cmd(MdbCashlessProtocol.ENABLE, "enable") { r3, _ ->
                            if (state != State.ENABLE) return@cmd
                            if (r3 != Result.ACK) return@cmd fail("enable: ${r3.title}")
                            waitSession()
                        })
                    })
                }
            }
        })
    }

    fun onEvent(e: Event) {
        if (!active) return
        // Тест А (ожидание) и пауза теста Б: никаких автоматических ответов —
        // иначе 10 04 в паузе закрыл бы сессию без запланированного 13 03.
        if (state == State.HOLD || state == State.REFUND_PAUSE) return onHoldEvent(e)
        if (mode == Mode.REFUND && refundSentAt != null && e != Event.Ack && e != Event.Nak) {
            observed += "+${sinceSec(refundSentAt!!)} с после 13 03: ${MdbCashlessProtocol.describe(e)}"
        }
        closer.onEvent(e)
        when (e) {
            is Event.BeginSession -> {
                sessionOpen = true
                when (state) {
                    State.ENABLE -> pendingBegin = e
                    State.WAIT_SESSION -> onBegin(e)
                    else -> if (vendSent) note("тестовая оплата: повторное 10 03 — второй vend запрещён")
                }
            }
            is Event.VendApproved -> onApproved(e.amount)
            Event.VendDenied -> if (state == State.VEND || state == State.WAIT_VEND_RESULT || state == State.CANCEL) {
                failure = failure ?: "терминал отказал в оплате (10 06)"
                closeSession("отказ 10 06")
            }
            Event.SessionCancelRequest -> if (state != State.CLOSING && state != State.DISABLE) {
                failure = failure ?: "терминал запросил отмену сессии (10 04)"
                closeSession("10 04 от терминала")
            }
            Event.EndSession -> {
                sessionOpen = false
                when (state) {
                    State.VEND, State.WAIT_VEND_RESULT, State.CANCEL, State.CONFIRM, State.PAUSE -> {
                        failure = failure ?: "терминал закрыл сессию (10 07) раньше нашего 13 04"
                        disable()
                    }
                    else -> Unit
                }
            }
            else -> Unit
        }
    }

    fun tick() {
        if (!active) return
        closer.tick()
        if (clock() < deadline) return
        when (state) {
            State.WAIT_SESSION -> {
                failure = "карта не приложена за ${SESSION_TIMEOUT_MS / 1000} с"
                if (sessionOpen) closeSession("нет 10 03") else disable()
            }
            State.WAIT_VEND_RESULT -> cancelVend("нет ответа на vend за ${VEND_TIMEOUT_MS / 1000} с")
            State.CANCEL -> closeSession("нет ответа на 13 01")
            State.PAUSE -> closeSession("после 13 02")
            State.HOLD -> {
                note("${mode.title}: ожидание ${holdMs / 1000} с прошло — 13 02 00 01")
                confirmSentAfterMs = clock() - approvedAt
                confirm(1)
            }
            State.REFUND_PAUSE -> requestRefund()
            else -> Unit
        }
    }

    // Кнопка «Прервать».
    fun abort() {
        when (state) {
            State.SETUP, State.PRICES, State.ENABLE -> fail("прервано кнопкой")
            State.WAIT_SESSION -> {
                failure = "прервано кнопкой"
                if (sessionOpen) closeSession("прервано") else disable()
            }
            State.VEND, State.WAIT_VEND_RESULT -> cancelVend("прервано кнопкой")
            // Деньги уже одобрены — прерывание лишь сокращает ожидание.
            State.HOLD -> {
                note("${mode.title}: ожидание прервано кнопкой — 13 02 00 01 сейчас")
                confirmSentAfterMs = clock() - approvedAt
                confirm(1)
            }
            else -> note("тестовая оплата: «Прервать» — уже идёт завершение (${state.title})")
        }
    }

    // Порт закрыт или адаптер выдернут — отправить уже ничего нельзя.
    fun portLost(reason: String) {
        if (!active) return
        portLost = reason
        state = State.DONE
        closer.abandon()
        finishOutcome()
    }

    private fun waitSession() {
        val early = pendingBegin
        if (early != null) {
            pendingBegin = null
            state = State.WAIT_SESSION
            onBegin(early)
            return
        }
        state = State.WAIT_SESSION
        deadline = clock() + SESSION_TIMEOUT_MS
        note("тестовая оплата: приём включён, приложите карту (до ${SESSION_TIMEOUT_MS / 1000} с)")
    }

    private fun onBegin(e: Event.BeginSession) {
        val funds = e.funds
        if (funds == null || funds < UNITS) {
            failure = "в 10 03 " + (if (funds == null) "нет суммы" else "доступно $funds ед. < $UNITS") +
                " — vend не отправлен"
            closeSession("мало средств")
            return
        }
        vendSent = true
        state = State.VEND
        queue.enqueue(cmd(MdbCashlessProtocol.vendRequest(UNITS, ITEM), "vend $UNITS ед.") { r, _ ->
            if (state != State.VEND) return@cmd
            if (r == Result.ACK) {
                state = State.WAIT_VEND_RESULT
                deadline = clock() + VEND_TIMEOUT_MS
            } else {
                failure = "vend не принят адаптером (${r.title})"
                closeSession("vend не принят")
            }
        })
    }

    private fun onApproved(amount: Int?) {
        approvedAmount = amount
        when (state) {
            State.VEND, State.WAIT_VEND_RESULT ->
                if (amount == UNITS) {
                    approved = true
                    moneySettled = true
                    approvedAt = clock()
                    when (mode) {
                        Mode.NORMAL -> confirm(1)
                        Mode.DELAY -> {
                            state = State.HOLD
                            deadline = clock() + holdMs
                            note("${mode.title}: 10 05 получено — ждём ${holdMs / 1000} с, терминалу не отвечаем")
                        }
                        Mode.REFUND -> {
                            state = State.REFUND_PAUSE
                            deadline = clock() + PAUSE_BEFORE_REFUND_MS
                        }
                    }
                } else {
                    refund("одобрено ${amount?.let { "$it ед." } ?: "без суммы"} вместо $UNITS ед.")
                }
            // После нашей отмены 13 01 или позже — выдачу не подтверждаем, возврат.
            else -> if (vendSent && !moneySettled) refund("одобрено после отмены/в завершении (${state.title})")
        }
    }

    private fun confirm(attempt: Int) {
        state = State.CONFIRM
        queue.enqueue(cmd(MdbCashlessProtocol.vendSuccess(ITEM), "13 02 00 01 (попытка $attempt)") { r, _ ->
            if (state != State.CONFIRM) return@cmd
            confirmResults += r
            when {
                r == Result.ACK -> confirmAck = true
                attempt < 2 && (r == Result.NAK || r == Result.TIMEOUT) -> return@cmd confirm(attempt + 1)
                else -> {
                    confirmAck = false
                    note("тестовая оплата: $NOT_CONFIRMED")
                }
            }
            state = State.PAUSE
            deadline = clock() + PAUSE_BEFORE_CLOSE_MS
        })
    }

    private fun refund(why: String) {
        moneySettled = true
        failure = why
        state = State.REFUND
        queue.enqueue(cmd(MdbCashlessProtocol.VEND_FAILURE, "13 03 (возврат)") { r, _ ->
            if (state != State.REFUND) return@cmd
            refundResult = r
            closeSession("после возврата")
        })
    }

    private fun onHoldEvent(e: Event) {
        val at = sinceSec(approvedAt)
        observed += "+$at с после 10 05: ${MdbCashlessProtocol.describe(e)}"
        if (e is Event.BeginSession) sessionOpen = true
        if (e == Event.EndSession) {
            sessionOpen = false
            closedByTerminalAfterMs = clock() - approvedAt
            val skipped = if (mode == Mode.REFUND) "13 03" else "13 02"
            note("${mode.title}: терминал закрыл сессию сам через $at с — $skipped не отправлен")
            disable()
        }
    }

    // Тест Б: 13 03 по плану, а не из-за ошибки.
    private fun requestRefund() {
        state = State.REFUND
        refundSentAt = clock()
        queue.enqueue(cmd(MdbCashlessProtocol.VEND_FAILURE, "13 03 (тест Б: возврат)") { r, _ ->
            if (state != State.REFUND) return@cmd
            refundResult = r
            closeSession("после 13 03")
        })
    }

    private fun sinceSec(from: Long): String =
        java.math.BigDecimal(clock() - from).movePointLeft(3).setScale(1, java.math.RoundingMode.HALF_UP).toPlainString()

    private fun cancelVend(why: String) {
        failure = "$why — отправлена отмена 13 01; проверьте списание в кабинете Nayax"
        state = State.CANCEL
        deadline = clock() + CANCEL_WAIT_MS
        queue.enqueue(cmd(MdbCashlessProtocol.VEND_CANCEL, "13 01 (отмена vend)"))
    }

    private fun closeSession(reason: String) {
        if (state == State.CLOSING || state == State.DISABLE || state == State.DONE) return
        state = State.CLOSING
        closer.start(reason)
    }

    private fun onSessionClosed(r: MdbSessionCloser.Report) {
        closeReport = r
        if (r.ended) sessionOpen = false
        if (state == State.CLOSING) disable()
    }

    private fun fail(reason: String) {
        failure = reason
        disable()
    }

    private fun disable() {
        if (state == State.DISABLE || state == State.DONE) return
        state = State.DISABLE
        queue.enqueue(cmd(MdbCashlessProtocol.DISABLE, "disable (конец тестовой оплаты)") { r, _ ->
            if (state != State.DISABLE) return@cmd
            disableResult = r
            state = State.DONE
            finishOutcome()
        })
    }

    private fun finishOutcome() {
        val close = closeReport
        val closedOk = close?.ackOk == true && close.ended
        val ok = portLost == null && approved && closedOk && when (mode) {
            Mode.REFUND -> refundResult == Result.ACK
            else -> confirmAck == true
        }
        val hang = (close?.hanging == true) || (sessionOpen && portLost == null && close == null)
        val steps = mutableListOf<String>()
        portLost?.let { steps += "прервано: $it; 14 00 не отправлено (порта нет)" }
        if (!ok) failure?.let { steps += it }
        if (mode != Mode.REFUND && approved && confirmAck == false) steps += NOT_CONFIRMED
        steps += "10 05: " + if (approvedAmount != null) "одобрено $approvedAmount ед." else "не было"
        if (mode == Mode.DELAY && approved) {
            steps += "ожидание ${holdMs / 1000} с"
            closedByTerminalAfterMs?.let { steps += "терминал закрыл сессию сам через ${sec(it)} с" }
            confirmSentAfterMs?.let { steps += "13 02 отправлен через ${sec(it)} с после 10 05" }
        }
        if (approved && mode != Mode.REFUND) steps += "13 02: " + when {
            confirmResults.isNotEmpty() -> confirmResults.joinToString(", ") { it.title }
            else -> "не отправлен"
        }
        if (mode == Mode.REFUND && approved) {
            steps += "13 03: " + (refundResult?.title ?: "не отправлен")
        } else {
            refundResult?.let { steps += "13 03: ${it.title}" }
        }
        steps += "13 04: " + when {
            close == null -> "не отправлялось"
            close.ackOk -> "ACK (попыток ${close.attempts})"
            else -> "нет ACK (попыток ${close.attempts})"
        }
        if (close != null) steps += "10 07: " + if (close.ended) "пришло" else "не пришло"
        disableResult?.let { steps += "14 00: ${it.title}" }
        if (observed.isNotEmpty()) {
            steps += (if (mode == Mode.DELAY) "кадры во время ожидания: " else "кадры после 13 03: ") +
                observed.joinToString(", ")
        } else if (mode == Mode.DELAY && approved) {
            steps += "кадров во время ожидания не было"
        } else if (mode == Mode.REFUND && refundSentAt != null) {
            steps += "кадров после 13 03 не было"
        }
        if (hang) steps += MdbSessionCloser.HANGING_TEXT
        val head = when {
            mode == Mode.REFUND && approved -> "возврат запрошен: " +
                (if (refundResult == Result.ACK) "ACK получен" else "ACK нет (${refundResult?.title ?: "не отправлен"})") +
                ". Проверьте списание на карте — "
            ok -> "УСПЕХ — "
            else -> "НЕ УДАЛАСЬ — "
        }
        val text = head + steps.joinToString("; ")
        val unsettled = vendSent && !moneySettled
        outcome = Outcome(ok, text, hang, unsettled)
        note("${mode.title}: $text" + if (unsettled) "; итог списания терминал не сообщил — сверьте в кабинете Nayax" else "")
    }

    private fun sec(ms: Long): String =
        java.math.BigDecimal(ms).movePointLeft(3).setScale(1, java.math.RoundingMode.HALF_UP).toPlainString()

    private fun cmd(data: ByteArray, label: String, onDone: (Result, Event?) -> Unit = { _, _ -> }) =
        MdbCommandQueue.Command(data, "тест: $label", onDone)

    private fun unitsFor(r: MdbCashlessProtocol.SetupReply): Int = try {
        MdbCashlessProtocol.priceUnits(AMOUNT, r.scale, r.decimals)
    } catch (e: IllegalArgumentException) {
        -1
    }

    companion object {
        const val AMOUNT = "0.10"
        const val UNITS = 10
        const val ITEM = 1
        const val SESSION_TIMEOUT_MS = 60_000L
        const val VEND_TIMEOUT_MS = 60_000L
        const val CANCEL_WAIT_MS = 10_000L
        const val PAUSE_BEFORE_CLOSE_MS = 1_000L
        const val PAUSE_BEFORE_REFUND_MS = 1_000L
        val DELAY_CHOICES = listOf(30, 60, 90, 120)
        const val NOT_CONFIRMED = "оплата одобрена, выдача НЕ подтверждена терминалом"
    }
}
