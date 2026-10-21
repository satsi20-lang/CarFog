package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event

// Опрос адаптера стенда MDB раз в 60 с (1.10.11; через очередь команд —
// 1.10.12): пока приём включён (14 01 отправлено, 14 00 ещё нет) и сессии нет
// (вне 10 03 … 10 07), ставим в очередь setup. Ответ ждёт очередь (2 с); нет
// ответа или FF — onPollDone(false): журнал и флаг silent. setup → prices →
// enable заново сами НЕ повторяем, экран только предлагает кнопки.
// Без Android-зависимостей, один логический поток стенда.
class MdbKeepAlive(
    private val clock: () -> Long,
    private val intervalMs: Long = INTERVAL_MS,
) {
    var enabled = false
        private set
    var inSession = false
        private set
    // Последний опрос остался без ответа — экран предлагает setup/prices/enable.
    var silent = false
        private set
    private var lastPollAt = 0L
    private var awaiting = false

    // Команда ушла в адаптер и получила ACK.
    fun onAcked(data: ByteArray) {
        when {
            data.contentEquals(MdbCashlessProtocol.ENABLE) -> {
                enabled = true
                silent = false
                lastPollAt = clock()
            }
            data.contentEquals(MdbCashlessProtocol.DISABLE) -> {
                enabled = false
                inSession = false
            }
        }
    }

    fun onEvent(e: Event) {
        when (e) {
            is Event.BeginSession -> inSession = true
            Event.EndSession -> inSession = false
            is Event.Setup -> silent = false
            else -> Unit
        }
    }

    fun reset() {
        enabled = false
        inSession = false
        silent = false
        awaiting = false
    }

    // true — пора поставить setup в очередь. paused — идёт тестовая оплата.
    fun due(paused: Boolean = false): Boolean {
        if (paused || awaiting || !enabled || inSession || clock() - lastPollAt < intervalMs) return false
        lastPollAt = clock()
        awaiting = true
        return true
    }

    fun onPollDone(ok: Boolean) {
        awaiting = false
        if (!ok) silent = true
    }

    companion object {
        const val INTERVAL_MS = 60_000L
    }
}
