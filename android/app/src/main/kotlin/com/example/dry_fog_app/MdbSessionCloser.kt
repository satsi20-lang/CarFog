package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event

// Закрытие сессии терминала (1.10.12): 13 04 через очередь (ждём ACK 00),
// затем ждём 10 07 до END_TIMEOUT_MS. Нет 10 07 (или 13 04 получил FF / нет
// ACK) — один повтор 13 04 и ещё END_TIMEOUT_MS. Снова нет — итог «сессия
// может висеть, нажмите done». Урок с железа: пока сессия не закрыта,
// терминал не читает новую карту («Cashless out of order»).
// Без Android-зависимостей, один логический поток стенда.
class MdbSessionCloser(
    private val queue: MdbCommandQueue,
    private val note: (String) -> Unit,
    private val clock: () -> Long,
    private val onFinished: (Report) -> Unit,
    private val endTimeoutMs: Long = END_TIMEOUT_MS,
) {
    data class Report(
        // Хотя бы одна попытка 13 04 получила ACK 00.
        val ackOk: Boolean,
        // Пришло 10 07.
        val ended: Boolean,
        val attempts: Int,
        val detail: String,
    ) {
        val hanging: Boolean get() = !ended
    }

    var active = false
        private set
    private var attempt = 0
    private var ackOk = false
    private var ended = false
    private var commandInFlight = false
    private var waitDeadline: Long? = null
    private val steps = mutableListOf<String>()

    fun start(reason: String) {
        if (active) return
        active = true
        attempt = 0
        ackOk = false
        ended = false
        steps.clear()
        note("закрытие сессии: $reason → 13 04")
        sendSessionComplete()
    }

    fun onEvent(e: Event) {
        if (!active || e != Event.EndSession) return
        ended = true
        steps += "10 07 получено"
        maybeFinish()
    }

    fun tick() {
        val deadline = waitDeadline ?: return
        if (!active || clock() < deadline) return
        waitDeadline = null
        steps += "10 07 не пришло за ${endTimeoutMs / 1000} с"
        if (attempt < MAX_ATTEMPTS) {
            note("закрытие сессии: 10 07 нет за ${endTimeoutMs / 1000} с — повтор 13 04")
            sendSessionComplete()
        } else {
            finish()
        }
    }

    // Порт закрыт — закрыть сессию нечем.
    fun abandon() {
        if (!active) return
        steps += "порт закрыт"
        finish()
    }

    private fun sendSessionComplete() {
        attempt++
        commandInFlight = true
        val n = attempt
        queue.enqueue(MdbCommandQueue.Command(MdbCashlessProtocol.SESSION_COMPLETE, "13 04 (попытка $n)") { r, _ ->
            commandInFlight = false
            steps += "13 04 #$n: ${r.title}"
            when (r) {
                MdbCommandQueue.Result.ACK -> {
                    ackOk = true
                    waitForEnd()
                }
                MdbCommandQueue.Result.NAK, MdbCommandQueue.Result.TIMEOUT ->
                    if (!ended && attempt < MAX_ATTEMPTS) {
                        note("закрытие сессии: 13 04 — ${r.title}, повтор")
                        sendSessionComplete()
                    } else {
                        waitForEnd()
                    }
                MdbCommandQueue.Result.SEND_FAILED, MdbCommandQueue.Result.DROPPED -> finish()
            }
        })
    }

    private fun waitForEnd() {
        if (ended) {
            maybeFinish()
            return
        }
        waitDeadline = clock() + endTimeoutMs
    }

    // 10 07 могло прийти раньше ACK на 13 04 — итог только когда ответ на 13 04 получен.
    private fun maybeFinish() {
        if (ended && !commandInFlight) finish()
    }

    private fun finish() {
        if (!active) return
        active = false
        waitDeadline = null
        val r = Report(ackOk, ended, attempt, steps.joinToString("; "))
        note("закрытие сессии: " + (if (r.ended) "сессия закрыта" else HANGING_TEXT) + " — ${r.detail}")
        onFinished(r)
    }

    companion object {
        const val END_TIMEOUT_MS = 10_000L
        const val MAX_ATTEMPTS = 2
        const val HANGING_TEXT = "сессия может висеть, нажмите done"
    }
}
