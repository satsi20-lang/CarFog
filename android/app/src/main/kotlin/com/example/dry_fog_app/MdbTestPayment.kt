package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event
import java.io.IOException

// Режим «одна тестовая оплата 0,10 €» стенда MDB (1.10.11). Автомат без
// Android-зависимостей: кадры адаптера — onEvent, время — tick (каждые
// ~200 мс с фонового потока), отправка — через send.
//
// Порядок: setup → (ответ setup, 0,10 € должно быть ровно 10 ед.) → prices →
// ACK → enable → ACK → ждём 10 03 до 60 с → сразу vend 10 ед. (один раз) →
//   10 05 на 10 ед.  → 13 02 00 01, 13 04, ждём 10 07 до 10 с — успех;
//   10 05 на другую сумму или без суммы → 13 03 (возврат), 13 04 — ошибка;
//   10 06 → 13 04;  10 04 → 13 04;
//   10 03 без суммы или меньше 10 ед. → vend не шлём, 13 04.
// Любой исход заканчивается 14 00 (disable). Сумма жёстко 10 ед., повторный
// vend за запуск невозможен. Ни одного догадочного шага: всё, чего нет в
// паспорте, ведёт к отмене и 14 00.
class MdbTestPayment(
    private val send: (data: ByteArray, label: String) -> Unit,
    private val note: (String) -> Unit,
    private val clock: () -> Long,
) {
    enum class State(val title: String) {
        IDLE("не запущена"),
        WAIT_SETUP("setup: ждём ответ"),
        WAIT_PRICES_ACK("prices: ждём ACK"),
        WAIT_ENABLE_ACK("enable: ждём ACK"),
        WAIT_SESSION("приложите карту (ждём 10 03)"),
        WAIT_VEND_RESULT("vend 10 ед.: ждём ответ терминала"),
        WAIT_CANCEL_RESULT("vend отменён (13 01): ждём ответ"),
        WAIT_END_SESSION("13 04: ждём конец сессии (10 07)"),
        DONE("завершена"),
    }

    data class Outcome(val ok: Boolean, val text: String)

    var state = State.IDLE
        private set
    var outcome: Outcome? = null
        private set
    private var deadline = 0L
    private var vendSent = false
    // Деньги по vend уже решены (13 02 или 13 03 отправлены) — второй раз не шлём.
    private var vendSettled = false
    // Итог, который объявим после 10 07 (или таймаута его ожидания).
    private var pendingOk = false
    private var pendingText = ""

    val active: Boolean
        @Synchronized get() = state != State.IDLE && state != State.DONE

    @Synchronized
    fun start() {
        check(!active) { "тестовая оплата уже идёт" }
        outcome = null
        vendSent = false
        vendSettled = false
        pendingOk = false
        pendingText = ""
        note("тестовая оплата: старт (0,10 € = $UNITS ед., товар $ITEM)")
        step(MdbCashlessProtocol.SETUP, "setup", State.WAIT_SETUP, SETUP_TIMEOUT_MS)
    }

    @Synchronized
    fun onEvent(e: Event) {
        when (state) {
            State.IDLE, State.DONE -> return
            State.WAIT_SETUP -> if (e is Event.Setup) onSetup(e.reply)
            State.WAIT_PRICES_ACK -> if (e == Event.Ack) {
                step(MdbCashlessProtocol.ENABLE, "enable", State.WAIT_ENABLE_ACK, ACK_TIMEOUT_MS)
            }
            State.WAIT_ENABLE_ACK -> when {
                e == Event.Ack -> waitSession()
                e is Event.BeginSession -> onBeginSession(e)
            }
            State.WAIT_SESSION -> when (e) {
                is Event.BeginSession -> onBeginSession(e)
                Event.SessionCancelRequest -> completeSession(false, "терминал запросил отмену сессии (10 04) до оплаты")
                else -> Unit
            }
            State.WAIT_VEND_RESULT, State.WAIT_CANCEL_RESULT -> when (e) {
                // Одобрение после нашей отмены 13 01 — выдачу не подтверждаем, возврат.
                is Event.VendApproved -> if (state == State.WAIT_CANCEL_RESULT) {
                    refund(e.amount, "одобрено после отмены 13 01")
                } else onApproved(e.amount)
                Event.VendDenied -> completeSession(false,
                    if (state == State.WAIT_CANCEL_RESULT) pendingText else "терминал отказал в оплате (10 06)")
                Event.SessionCancelRequest -> completeSession(false, "терминал запросил отмену сессии (10 04)")
                Event.EndSession -> finish(false, "терминал закрыл сессию (10 07) без ответа на vend")
                is Event.BeginSession -> note("тестовая оплата: повторное 10 03 — второй vend запрещён, пропущено")
                else -> Unit
            }
            State.WAIT_END_SESSION -> when (e) {
                Event.EndSession -> finish(pendingOk, pendingText)
                // Одобрение после отказа/отмены: деньги списаны, товара нет — возврат.
                is Event.VendApproved -> if (vendSent && !vendSettled) refund(e.amount, "запоздалое одобрение")
                Event.SessionCancelRequest -> note("тестовая оплата: 10 04 — 13 04 уже отправлено, ждём 10 07")
                else -> Unit
            }
        }
    }

    @Synchronized
    fun tick() {
        if (!active || clock() < deadline) return
        expire("истекло время")
    }

    // Кнопка «Прервать»: тот же путь, что и таймаут текущего шага.
    @Synchronized
    fun abort() {
        if (active) expire("прервано кнопкой")
    }

    // Порт закрыт или адаптер выдернут — отправить уже ничего нельзя.
    @Synchronized
    fun portLost(reason: String) {
        if (!active) return
        val money = if (vendSent && !vendSettled) {
            " ВНИМАНИЕ: vend был отправлен, ответа нет — проверьте списание в кабинете Nayax."
        } else ""
        state = State.DONE
        outcome = Outcome(false, "прервано: $reason; 14 00 не отправлено (порта нет).$money")
        note("тестовая оплата: ${outcome!!.text}")
    }

    private fun expire(why: String) {
        when (state) {
            State.WAIT_SETUP -> finish(false, "нет ответа на setup за ${SETUP_TIMEOUT_MS / 1000} с ($why)")
            State.WAIT_PRICES_ACK -> finish(false, "нет ACK на prices за ${ACK_TIMEOUT_MS / 1000} с ($why)")
            State.WAIT_ENABLE_ACK -> finish(false, "нет ACK на enable за ${ACK_TIMEOUT_MS / 1000} с ($why)")
            State.WAIT_SESSION -> finish(false, "карта не приложена за ${SESSION_TIMEOUT_MS / 1000} с ($why)")
            State.WAIT_VEND_RESULT -> {
                pendingText = "нет ответа на vend ($why) — отправлена отмена 13 01; проверьте списание в кабинете Nayax"
                step(MdbCashlessProtocol.VEND_CANCEL, "отмена vend", State.WAIT_CANCEL_RESULT, CANCEL_TIMEOUT_MS)
            }
            State.WAIT_CANCEL_RESULT -> completeSession(false, pendingText)
            State.WAIT_END_SESSION -> finish(pendingOk, "$pendingText (10 07 не пришло за ${END_TIMEOUT_MS / 1000} с)")
            State.IDLE, State.DONE -> Unit
        }
    }

    private fun onSetup(r: MdbCashlessProtocol.SetupReply) {
        val units = try {
            MdbCashlessProtocol.priceUnits(AMOUNT, r.scale, r.decimals)
        } catch (e: IllegalArgumentException) {
            -1
        }
        if (units != UNITS) {
            finish(false, "по ответу setup (масштаб ${r.scale}, знаков ${r.decimals}) 0,10 € ≠ $UNITS ед. — оплата не запущена")
            return
        }
        step(MdbCashlessProtocol.PRICES, "prices", State.WAIT_PRICES_ACK, ACK_TIMEOUT_MS)
    }

    private fun waitSession() {
        state = State.WAIT_SESSION
        deadline = clock() + SESSION_TIMEOUT_MS
        note("тестовая оплата: приём включён, приложите карту (до ${SESSION_TIMEOUT_MS / 1000} с)")
    }

    private fun onBeginSession(e: Event.BeginSession) {
        val funds = e.funds
        if (funds == null || funds < UNITS) {
            completeSession(false, "в 10 03 " +
                (if (funds == null) "нет суммы" else "доступно $funds ед. < $UNITS") + " — vend не отправлен")
            return
        }
        vendSent = true
        step(MdbCashlessProtocol.vendRequest(UNITS, ITEM), "vend $UNITS ед.", State.WAIT_VEND_RESULT, VEND_TIMEOUT_MS)
    }

    private fun onApproved(amount: Int?) {
        if (amount == UNITS) {
            vendSettled = true
            if (!trySend(MdbCashlessProtocol.vendSuccess(ITEM), "успех выдачи")) return
            completeSession(true, "оплата 0,10 € ($UNITS ед.) одобрена, выдача подтверждена 13 02 00 01")
        } else {
            refund(amount, "одобрено ${amount?.let { "$it ед." } ?: "без суммы"} вместо $UNITS ед.")
        }
    }

    private fun refund(amount: Int?, why: String) {
        vendSettled = true
        if (!trySend(MdbCashlessProtocol.VEND_FAILURE, "ошибка выдачи (возврат)")) return
        val text = "$why — отправлен возврат 13 03; проверьте в кабинете Nayax" +
            (amount?.let { ", одобрено $it ед." } ?: "")
        if (state == State.WAIT_END_SESSION) {
            pendingOk = false
            pendingText = text
            note("тестовая оплата: $text")
        } else {
            completeSession(false, text)
        }
    }

    // 13 04 и ожидание 10 07; итог объявляется по 10 07 или таймауту.
    private fun completeSession(ok: Boolean, text: String) {
        pendingOk = ok
        pendingText = text
        step(MdbCashlessProtocol.SESSION_COMPLETE, "конец сессии", State.WAIT_END_SESSION, END_TIMEOUT_MS)
    }

    private fun finish(ok: Boolean, text: String) {
        state = State.DONE
        outcome = Outcome(ok, text)
        trySend(MdbCashlessProtocol.DISABLE, "disable (конец тестовой оплаты)")
        note("тестовая оплата: ${if (ok) "УСПЕХ" else "НЕ УДАЛАСЬ"} — $text")
    }

    private fun step(data: ByteArray, label: String, next: State, timeoutMs: Long) {
        if (!trySend(data, label)) return
        state = next
        deadline = clock() + timeoutMs
    }

    // false — отправка не удалась, режим уже завершён (повторять нельзя).
    private fun trySend(data: ByteArray, label: String): Boolean = try {
        send(data, "тест: $label")
        true
    } catch (e: IOException) {
        if (state != State.DONE) portLost("ошибка отправки ($label): ${e.message ?: e}")
        false
    }

    companion object {
        const val AMOUNT = "0.10"
        const val UNITS = 10
        const val ITEM = 1
        const val SETUP_TIMEOUT_MS = 5_000L
        const val ACK_TIMEOUT_MS = 3_000L
        const val SESSION_TIMEOUT_MS = 60_000L
        const val VEND_TIMEOUT_MS = 60_000L
        const val CANCEL_TIMEOUT_MS = 10_000L
        const val END_TIMEOUT_MS = 10_000L
    }
}
