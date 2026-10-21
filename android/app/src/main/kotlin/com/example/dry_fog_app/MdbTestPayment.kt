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
class MdbTestPayment(
    private val queue: MdbCommandQueue,
    private val note: (String) -> Unit,
    private val clock: () -> Long,
) {
    enum class State(val title: String) {
        IDLE("не запущена"),
        SETUP("setup: ждём ответ"),
        PRICES("prices: ждём ACK"),
        ENABLE("enable: ждём ACK"),
        WAIT_SESSION("приложите карту (ждём 10 03)"),
        VEND("vend 10 ед.: ждём ACK"),
        WAIT_VEND_RESULT("vend принят: ждём ответ терминала"),
        CANCEL("vend отменён (13 01): ждём ответ"),
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

    fun start() {
        check(!active) { "тестовая оплата уже идёт" }
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
        note("тестовая оплата: старт (0,10 € = $UNITS ед., товар $ITEM)")
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
                    confirm(1)
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
        val ok = portLost == null && approved && confirmAck == true &&
            close?.ackOk == true && close.ended
        val hang = (close?.hanging == true) || (sessionOpen && portLost == null && close == null)
        val steps = mutableListOf<String>()
        portLost?.let { steps += "прервано: $it; 14 00 не отправлено (порта нет)" }
        if (!ok) failure?.let { steps += it }
        if (approved && confirmAck == false) steps += NOT_CONFIRMED
        steps += "10 05: " + if (approvedAmount != null) "одобрено $approvedAmount ед." else "не было"
        if (approved) steps += "13 02: " + when (confirmAck) {
            true -> "ACK"
            false -> "нет ACK (FF/таймаут, 2 попытки)"
            null -> "не отправлено"
        }
        refundResult?.let { steps += "13 03: ${it.title}" }
        steps += "13 04: " + when {
            close == null -> "не отправлялось"
            close.ackOk -> "ACK (попыток ${close.attempts})"
            else -> "нет ACK (попыток ${close.attempts})"
        }
        if (close != null) steps += "10 07: " + if (close.ended) "пришло" else "не пришло"
        disableResult?.let { steps += "14 00: ${it.title}" }
        if (hang) steps += MdbSessionCloser.HANGING_TEXT
        if (vendSent && !moneySettled) steps += "vend был отправлен, исход неизвестен — проверьте кабинет Nayax"
        val text = (if (ok) "УСПЕХ — " else "") + steps.joinToString("; ")
        outcome = Outcome(ok, text, hang)
        note("тестовая оплата: ${if (ok) "" else "НЕ УДАЛАСЬ — "}$text")
    }

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
        const val NOT_CONFIRMED = "оплата одобрена, выдача НЕ подтверждена терминалом"
    }
}
