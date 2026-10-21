package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event
import com.example.dry_fog_app.MdbCommandQueue.Result

// Одна оплата картой в основном потоке (1.11.0, ТЗ раздел 6). Чистый Kotlin
// на общем слое MDB: команды через MdbCommandQueue (одна за раз, ждать 00),
// закрытие сессии — MdbSessionCloser, время — подставные часы, один
// логический поток. Управляется из Dart (экран оплаты и итог цикла).
//
//   arm(сумма, запах)  — экран «Приложите карту»: ждём 10 03.
//   10 03, средств ≥ суммы — сразу vend на сумму (остаток после монет), один
//     раз; меньше или без суммы — 13 04, «Недостаточно средств».
//   vend: FF / нет ACK — закрытие сессии; ответ 10 05 / 10 06 до 60 с.
//   10 05, сумма совпала — «approved»: Dart пишет payment_pending и запускает
//     цикл; сессия остаётся открытой (терминал сам закрывает её через ~40 с
//     запросом 10 04 — отвечаем 13 04).
//   10 05 на другую сумму — 13 03, 13 04, ошибка. 10 06 — 13 04, «отклонён».
//   finishSuccess() — цикл прошёл: если сессия открыта — 13 02 (ACK), затем
//     13 04 и 10 07; иначе ничего.
//   finishFailure() — цикл оборвался: прошло меньше окна возврата с 10 05 и
//     сессия открыта — 13 03 (ACK, один повтор), 13 04, «refunded»; иначе —
//     «manual_refund_needed» (терминалу только 13 04 на 10 04).
class MdbCardPayment(
    private val queue: MdbCommandQueue,
    private val note: (String) -> Unit,
    private val emit: (type: String, data: Map<String, Any?>) -> Unit,
    private val clock: () -> Long,
    // Поток оплаты держит сессию — контур связи не закрывает её сам.
    private val setOwnsSession: (Boolean) -> Unit,
) {
    enum class State(val title: String) {
        IDLE("нет оплаты"),
        ARMED("ждём карту (10 03)"),
        VENDING("vend: ждём ACK"),
        WAIT_RESULT("vend принят: ждём 10 05 / 10 06"),
        CANCELLING("vend отменён (13 01): ждём ответ"),
        APPROVED("оплачено, идёт цикл"),
        FINISHING("завершение (13 02 / 13 03, 13 04)"),
    }

    var state = State.IDLE
        private set
    var units = 0
        private set
    private var item = 1
    private var refundWindowMs = 30_000L
    private var confirmEnabled = true
    private var sessionOpen = false
    var approvedAt: Long? = null
        private set
    private var deadline = 0L
    private var outcomeType: String? = null
    private val outcome = mutableMapOf<String, Any?>()

    private val closer = MdbSessionCloser(queue, note, clock, ::onSessionClosed)

    val busy: Boolean get() = state != State.IDLE
    // После 10 03 клиент отменить не может (кнопка «Отмена» скрыта).
    val customerCanCancel: Boolean get() = state == State.ARMED && !sessionOpen

    // ---- из Dart ----

    fun arm(units: Int, item: Int, refundWindowMs: Long, confirmEnabled: Boolean) {
        check(state == State.IDLE) { "оплата картой уже идёт (${state.title})" }
        require(units in 1..MdbCashlessProtocol.MAX_UNITS) { "сумма $units ед. вне 1..65535" }
        require(item in 1..8) { "номер запаха $item вне 1..8" }
        this.units = units
        this.item = item
        this.refundWindowMs = refundWindowMs
        this.confirmEnabled = confirmEnabled
        sessionOpen = false
        approvedAt = null
        outcomeType = null
        outcome.clear()
        state = State.ARMED
        setOwnsSession(true)
        note("оплата картой: ждём карту, $units ед., запах $item")
    }

    // Внесли монету до 10 03 — vend пойдёт на новый остаток.
    fun updateUnits(units: Int) {
        if (state != State.ARMED || sessionOpen) return
        require(units in 1..MdbCashlessProtocol.MAX_UNITS) { "сумма $units ед. вне 1..65535" }
        this.units = units
    }

    // Кнопка «Отмена» (только до 10 03): сброс читателя 14 02, enable остаётся.
    fun cancelByCustomer() {
        if (!customerCanCancel) return
        queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.READER_CANCEL, "14 02 (отмена клиентом)"))
        disarm("отмена клиентом")
    }

    // Ушли с экрана без карты (таймаут, монеты набрали сумму): без команд.
    // После 10 03 состояние уже не ARMED — сессию ведёт автомат до конца.
    fun disarm(why: String) {
        if (state != State.ARMED) return
        note("оплата картой: снято ожидание карты ($why)")
        state = State.IDLE
        setOwnsSession(false)
    }

    fun finishSuccess() {
        if (state != State.APPROVED) return
        state = State.FINISHING
        outcome["cycle"] = "success"
        if (!sessionOpen || closer.active) {
            outcome["confirm"] = "сессия уже закрыта терминалом"
            return complete("success")
        }
        if (!confirmEnabled) {
            outcome["confirm"] = "13 02 выключен настройкой"
            return closeThen("success")
        }
        queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.vendSuccess(item), "13 02 (выдача)") { r, _ ->
            outcome["confirm"] = r.title
            closeThen("success")
        })
    }

    fun finishFailure(reason: String) {
        if (state != State.APPROVED) return
        state = State.FINISHING
        outcome["cycle"] = "failure"
        outcome["cycle_reason"] = reason
        val elapsed = clock() - (approvedAt ?: clock())
        outcome["elapsed_s"] = elapsed / 1000
        if (elapsed < refundWindowMs && sessionOpen && !closer.active) {
            refund(1)
        } else {
            outcome["refund"] = if (elapsed >= refundWindowMs) "окно возврата прошло" else "сессия уже закрыта терминалом"
            complete("manual_refund_needed")
        }
    }

    // ---- восстановление после перезапуска (ТЗ раздел 8) ----

    // На диске осталась незакрытая запись payment_pending: деньги одобрены,
    // итога нет. До deadlineMs (10 05 + окно возврата, часы стены) ждём, пока
    // связь готова (порт открыт, setup ответил), затем 13 03 и 13 04. Не
    // успели — ручной возврат.
    private var recovery: Triple<Int, Int, Long>? = null

    fun scheduleRecovery(units: Int, item: Int, deadlineMs: Long) {
        require(units in 1..MdbCashlessProtocol.MAX_UNITS) { "сумма $units ед. вне 1..65535" }
        require(item in 1..8) { "номер запаха $item вне 1..8" }
        recovery = Triple(units, item, deadlineMs)
        note("восстановление: незакрытая оплата $units ед., возврат возможен до $deadlineMs")
    }

    val recoveryPending: Boolean get() = recovery != null

    // linkReady — контур связи в READY (setup ответил). Вызывать каждый тик.
    fun tickRecovery(linkReady: Boolean) {
        val (u, i, deadline) = recovery ?: return
        if (clock() >= deadline) {
            recovery = null
            units = u
            item = i
            outcome.clear()
            outcome["recovered"] = true
            outcome["refund"] = "окно возврата прошло до восстановления связи"
            state = State.FINISHING
            complete("manual_refund_needed")
            return
        }
        if (!linkReady || state != State.IDLE) return
        recovery = null
        units = u
        item = i
        outcome.clear()
        outcome["recovered"] = true
        // Состояние сессии на терминале после перезапуска неизвестно: считаем
        // её открытой — 13 03, затем 13 04 и ожидание 10 07 (с повтором).
        sessionOpen = true
        state = State.FINISHING
        setOwnsSession(true)
        refund(1)
    }

    // ---- кадры и время ----

    fun onEvent(e: Event) {
        if (state == State.IDLE) return
        closer.onEvent(e)
        when (e) {
            is Event.BeginSession -> {
                sessionOpen = true
                if (state == State.ARMED) onBegin(e.funds)
            }
            is Event.VendApproved -> onApproved(e.amount)
            Event.VendDenied -> if (state == State.WAIT_RESULT || state == State.VENDING || state == State.CANCELLING) {
                endWithClose(outcomeType ?: "declined", "10 06")
            }
            Event.SessionCancelRequest -> when (state) {
                State.ARMED, State.VENDING, State.WAIT_RESULT, State.CANCELLING ->
                    endWithClose(outcomeType ?: "cancelled_by_terminal", "10 04 до одобрения")
                // Терминал сам подтвердил списание (~40 с после 10 05) — 13 04.
                State.APPROVED, State.FINISHING -> if (!closer.active && sessionOpen) closer.start("10 04 после одобрения")
                State.IDLE -> Unit
            }
            Event.EndSession -> {
                sessionOpen = false
                // Терминал закрыл сессию до одобрения.
                if (state == State.WAIT_RESULT || state == State.VENDING || state == State.CANCELLING) {
                    state = State.FINISHING
                    complete(outcomeType ?: "session_ended")
                }
            }
            else -> Unit
        }
    }

    fun tick() {
        closer.tick()
        if (clock() < deadline) return
        when (state) {
            State.WAIT_RESULT -> {
                state = State.CANCELLING
                outcomeType = "vend_timeout"
                deadline = clock() + CANCEL_WAIT_MS
                queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.VEND_CANCEL, "13 01 (нет ответа на vend)"))
            }
            State.CANCELLING -> endWithClose("vend_timeout", "нет ответа на 13 01")
            else -> Unit
        }
    }

    // Порт потерян / терминал недоступен. Вызывается до очистки очереди
    // (MdbLinkSupervisor.onLinkDown): сессию закрыть уже нечем.
    fun portLost(reason: String) {
        sessionOpen = false
        when (state) {
            State.IDLE -> return
            State.ARMED -> {
                state = State.IDLE
                setOwnsSession(false)
                emit("payment_aborted", mapOf("reason" to reason, "vend_sent" to false))
            }
            State.VENDING, State.WAIT_RESULT, State.CANCELLING -> {
                state = State.IDLE
                setOwnsSession(false)
                emit("payment_aborted", mapOf("reason" to reason, "vend_sent" to true))
            }
            // Деньги одобрены: итог решит finishSuccess/finishFailure; 13 02/13 03
            // уже не отправить (сессия считается закрытой).
            State.APPROVED -> outcome["link_lost"] = reason
            State.FINISHING -> {
                outcome["link_lost"] = reason
                if (closer.active) closer.abandon() else pendingOutcome?.let { complete(it) }
            }
        }
    }

    // ---- внутреннее ----

    private fun onBegin(funds: Int?) {
        if (funds == null || funds < units) {
            note("оплата картой: в 10 03 ${funds ?: "нет суммы"} < $units ед. — 13 04, недостаточно средств")
            outcome["funds"] = funds
            endWithClose("insufficient_funds", "недостаточно средств")
            return
        }
        state = State.VENDING
        emit("vend_sent", mapOf("units" to units))
        queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.vendRequest(units, item), "vend $units ед., запах $item") { r, _ ->
            if (state != State.VENDING) return@Command
            if (r == Result.ACK) {
                state = State.WAIT_RESULT
                deadline = clock() + VEND_RESULT_TIMEOUT_MS
            } else {
                outcome["vend"] = r.title
                endWithClose("vend_failed", "vend не принят (${r.title})")
            }
        })
    }

    private fun onApproved(amount: Int?) {
        when (state) {
            State.WAIT_RESULT, State.VENDING -> if (amount == units) {
                state = State.APPROVED
                approvedAt = clock()
                note("оплата картой одобрена: $units ед.")
                emit("approved", mapOf("units" to units, "approved_at" to approvedAt))
            } else {
                outcome["approved_units"] = amount
                outcome["requested_units"] = units
                refundBeforeCycle("amount_mismatch", "13 03 (сумма не совпала)")
            }
            // Одобрение после нашей отмены 13 01 — возврат, цикл не запускаем.
            State.CANCELLING -> {
                outcome["approved_units"] = amount
                refundBeforeCycle("approved_after_cancel", "13 03 (одобрено после 13 01)")
            }
            else -> note("оплата картой: лишнее 10 05 в состоянии ${state.title} — без действий")
        }
    }

    private fun refund(attempt: Int) {
        queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.VEND_FAILURE, "13 03 (возврат, попытка $attempt)") { r, _ ->
            if (r == Result.ACK) {
                outcome["refund"] = "ACK 00"
                closeThen("refunded")
            } else if (attempt < 2 && (r == Result.NAK || r == Result.TIMEOUT)) {
                refund(attempt + 1)
            } else {
                outcome["refund"] = "${r.title} (попыток $attempt)"
                closeThen("manual_refund_needed")
            }
        })
    }

    private var pendingOutcome: String? = null

    // Исход до одобрения: закрыть сессию (13 04, 10 07), затем итог.
    private fun endWithClose(type: String, why: String) {
        state = State.FINISHING
        pendingOutcome = type
        if (sessionOpen && !closer.active) closer.start(why) else if (!closer.active) complete(type)
    }

    // 13 03 до запуска цикла (цикл не запускается), затем закрытие сессии.
    private fun refundBeforeCycle(type: String, label: String) {
        state = State.FINISHING
        pendingOutcome = type
        queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.VEND_FAILURE, label) { r, _ ->
            outcome["refund"] = r.title
            closeThen(type)
        })
    }

    private fun closeThen(type: String) {
        if (state != State.FINISHING) return
        pendingOutcome = type
        if (sessionOpen && !closer.active) closer.start("конец оплаты") else if (!closer.active) complete(type)
    }

    private fun onSessionClosed(r: MdbSessionCloser.Report) {
        if (r.ended) sessionOpen = false
        outcome["close_13_04"] = if (r.ackOk) "ACK (попыток ${r.attempts})" else "нет ACK (попыток ${r.attempts})"
        outcome["end_10_07"] = r.ended
        if (r.hanging) outcome["session_may_hang"] = true
        // В APPROVED это ответ на 10 04 терминала (~40 с) — цикл идёт дальше.
        if (state == State.FINISHING) pendingOutcome?.let { complete(it) }
    }

    private fun complete(type: String) {
        // Итог выдаётся один раз (запоздалый колбэк снятой команды — мимо).
        if (state != State.FINISHING) return
        if (closer.active) {
            pendingOutcome = type
            return
        }
        finishWith(type, emptyMap())
        state = State.IDLE
        setOwnsSession(false)
    }

    private fun finishWith(type: String, extra: Map<String, Any?>) {
        val data = LinkedHashMap<String, Any?>(outcome)
        data.putAll(extra)
        data["units"] = units
        data["item"] = item
        approvedAt?.let { data["approved_at"] = it }
        note("оплата картой: итог $type $data")
        emit(type, data)
        pendingOutcome = null
    }

    companion object {
        const val VEND_RESULT_TIMEOUT_MS = 60_000L
        const val CANCEL_WAIT_MS = 10_000L
    }
}
