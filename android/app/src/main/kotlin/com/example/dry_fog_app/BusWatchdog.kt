package com.example.dry_fog_app

// Сторож шины (задача "устойчивость шины", 1.10.3): считает ПОДРЯД идущие
// неудачные транзакции на открытом порту и решает, когда порт пора закрыть
// и открыть заново. Чистая логика без Android и без времени системы —
// время передаётся снаружи, поэтому проверяется обычным JVM-тестом.
//
// Порог и окно не измерены (замера "сколько ошибок подряд бывает на живой
// шине в норме" нет) — консервативные значения, подлежат пересмотру:
//  * 10 ошибок подряд — при опросе раз в 3 с несколькими службами это
//    примерно 10-30 с устойчивой тишины; одиночные сбои и отсутствующее
//    необязательное устройство (между ними есть успешные ответы модуля
//    ввода-вывода) счётчик сбрасывают;
//  * не больше 3 переоткрытий за 60 с — переоткрытие не должно само стать
//    нагрузкой (stty + пауза), если шина мертва физически.
class BusWatchdog(
    val failureThreshold: Int = DEFAULT_FAILURE_THRESHOLD,
    val maxReopensPerWindow: Int = DEFAULT_MAX_REOPENS_PER_WINDOW,
    val windowMs: Long = DEFAULT_WINDOW_MS,
) {
    enum class Action { NONE, REOPEN }

    var consecutiveFailures = 0
        private set

    // Монотонный счётчик успешных транзакций — Dart по его росту между
    // опросами понимает, что шина отвечает (см. BusWatchdogService).
    var successTotal = 0L
        private set

    var reopenTotal = 0
        private set

    private val reopenTimes = ArrayDeque<Long>()

    // canReopen=false — считать, но не переоткрывать (диагностический режим
    // с другой чётностью, см. BusPortRegistry).
    fun onResult(ok: Boolean, now: Long, canReopen: Boolean = true): Action {
        if (ok) {
            consecutiveFailures = 0
            successTotal++
            return Action.NONE
        }
        consecutiveFailures++
        if (consecutiveFailures < failureThreshold || !canReopen) return Action.NONE
        while (reopenTimes.isNotEmpty() && now - reopenTimes.first() >= windowMs) {
            reopenTimes.removeFirst()
        }
        if (reopenTimes.size >= maxReopensPerWindow) return Action.NONE
        reopenTimes.addLast(now)
        reopenTotal++
        // Следующее переоткрытие — только после новой серии ошибок.
        consecutiveFailures = 0
        return Action.REOPEN
    }

    // Явное открытие порта (из Dart) — серия ошибок начинается заново.
    fun onExplicitOpen() {
        consecutiveFailures = 0
    }

    companion object {
        const val DEFAULT_FAILURE_THRESHOLD = 10
        const val DEFAULT_MAX_REOPENS_PER_WINDOW = 3
        const val DEFAULT_WINDOW_MS = 60_000L
    }
}
