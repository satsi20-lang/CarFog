package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event

// Опрос адаптера стенда MDB раз в 60 с (1.10.11): пока приём включён (мы
// отправили 14 01, а 14 00 ещё нет) и сессии нет (между 10 03 и 10 07),
// шлём setup и ждём ответ. Нет ответа — пишем в журнал и поднимаем флаг
// silent; setup → prices → enable заново сами НЕ повторяем, экран только
// предлагает сделать это кнопками. Без Android-зависимостей.
class MdbKeepAlive(
    private val clock: () -> Long,
    private val intervalMs: Long = INTERVAL_MS,
    private val replyTimeoutMs: Long = REPLY_TIMEOUT_MS,
) {
    enum class Action { NONE, SEND_SETUP, REPORT_SILENCE }

    var enabled = false
        private set
    var inSession = false
        private set
    // Последний опрос остался без ответа — экран предлагает setup/prices/enable.
    var silent = false
        private set
    private var lastPollAt = 0L
    private var awaitingSince: Long? = null

    @Synchronized
    fun onSent(data: ByteArray) {
        when {
            data.contentEquals(MdbCashlessProtocol.ENABLE) -> {
                enabled = true
                silent = false
                lastPollAt = clock()
            }
            data.contentEquals(MdbCashlessProtocol.DISABLE) -> {
                enabled = false
                inSession = false
                awaitingSince = null
            }
        }
    }

    @Synchronized
    fun onEvent(e: Event) {
        when (e) {
            is Event.BeginSession -> inSession = true
            Event.EndSession -> inSession = false
            is Event.Setup -> {
                awaitingSince = null
                silent = false
            }
            else -> Unit
        }
    }

    // Порт закрыт — всё с нуля.
    @Synchronized
    fun reset() {
        enabled = false
        inSession = false
        silent = false
        awaitingSince = null
    }

    // paused — идёт тестовая оплата (у неё свои ожидания и таймауты).
    @Synchronized
    fun tick(paused: Boolean = false): Action {
        val now = clock()
        val since = awaitingSince
        if (since != null) {
            if (now - since < replyTimeoutMs) return Action.NONE
            awaitingSince = null
            silent = true
            return Action.REPORT_SILENCE
        }
        if (paused || !enabled || inSession || now - lastPollAt < intervalMs) return Action.NONE
        lastPollAt = now
        awaitingSince = now
        return Action.SEND_SETUP
    }

    companion object {
        const val INTERVAL_MS = 60_000L
        const val REPLY_TIMEOUT_MS = 5_000L
    }
}
