package com.example.dry_fog_app

import android.content.Context
import android.os.SystemClock
import android.util.Log

// То, что реестру нужно от объекта порта. ModbusRtu реализует; в JVM-тестах
// — подделка без tty и stty.
interface SerialBus {
    fun open(port: String, baud: Int, parity: String = "none"): ModbusRtu.OpenResult

    // Закрыть, выждать паузу и открыть снова на тех же параметрах — тем же
    // объектом (ссылки на него у других потоков остаются рабочими).
    fun reopen(port: String, baud: Int, parity: String, pauseMs: Long): ModbusRtu.OpenResult

    fun close()

    fun isOpen(): Boolean

    // Итог каждой обычной транзакции: true — пришёл кадр с верным CRC.
    var transactionListener: ((Boolean) -> Unit)?
}

// Владение портом шины на уровне ПРОЦЕССА (задача "устойчивость шины",
// 1.10.3). Раньше порт принадлежал экземпляру ModbusChannel, то есть
// конкретному движку Flutter. Блокировка же порта (FileChannel.tryLock в
// ModbusRtu.open) действует на весь процесс: JVM ведёт общую таблицу
// блокировок и второй tryLock того же файла из того же процесса получает
// OverlappingFileLockException (см. ModbusRtuPortLockTest). Как только в
// процессе одновременно жили два движка (вторая MainActivity при запуске
// через HOME, пересоздание активности), второй получал PORT_BUSY с PID
// своего же процесса и оставался без шины, пока первый не умрёт.
//
// Теперь объект порта один на процесс:
//  * повторное открытие того же порта с теми же параметрами — не ошибка:
//    уже открытый объект переиспользуется, владельцем становится
//    вызвавший канал (новый движок — тот, что на экране);
//  * прежний владелец теряет доступ (busFor → null): два движка не
//    командуют выходами одновременно, а его release() при уничтожении не
//    закрывает порт и не гасит выходы под новым владельцем;
//  * сторож шины (BusWatchdog) переоткрывает порт после серии ошибок.
class BusPortRegistry<B : SerialBus>(
    private val factory: () -> B,
    private val clock: () -> Long,
    private val wallClock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit,
    private val watchdog: BusWatchdog = BusWatchdog(),
    private val reopenPauseMs: Long = DEFAULT_REOPEN_PAUSE_MS,
) {
    data class Params(val port: String, val baud: Int, val parity: String)

    @Volatile
    private var bus: B? = null

    @Volatile
    private var owner: Any? = null

    private var params: Params? = null

    // События переоткрытия для журнала и облака — забирает Dart владельца
    // (health). Ограничено: если Dart долго не забирает, старые теряются.
    private val events = ArrayDeque<Map<String, Any?>>()

    // Открытый объект порта независимо от владельца — только для
    // аварийного обработчика (DryFogApplication), когда Dart уже мёртв.
    val current: B? get() = bus

    // Порт для канала: только текущему владельцу.
    fun busFor(who: Any): B? = if (owner === who) bus else null

    fun isOwner(who: Any): Boolean = owner === who

    @Synchronized
    fun open(who: Any, port: String, baud: Int, parity: String = "none"): ModbusRtu.OpenResult {
        val wanted = Params(port, baud, parity)
        val existing = bus
        if (existing != null && existing.isOpen() && params == wanted) {
            if (owner !== who) {
                log("open: $port уже открыт этим процессом — переиспользую, владение передано новому каналу")
            }
            owner = who
            watchdog.onExplicitOpen()
            return ModbusRtu.OpenResult.Ok
        }
        if (existing != null) {
            log("open: закрываю прежний объект порта перед открытием $wanted")
            existing.transactionListener = null
            existing.close()
            bus = null
            params = null
        }
        owner = who
        val created = factory()
        val result = created.open(port, baud, parity)
        if (result is ModbusRtu.OpenResult.Ok) {
            created.transactionListener = { ok -> onTransaction(created, ok) }
            bus = created
            params = wanted
            watchdog.onExplicitOpen()
        } else {
            created.close()
        }
        return result
    }

    // Явное закрытие — только владельцем. false: вызывающий не владелец,
    // порт не тронут.
    @Synchronized
    fun close(who: Any): Boolean {
        if (owner !== who) return false
        bus?.let {
            it.transactionListener = null
            it.close()
        }
        bus = null
        params = null
        return true
    }

    // Уничтожение движка-владельца: beforeClose (выключение выходов) и
    // закрытие. Не владелец — ничего не делает (порт уже у нового движка).
    @Synchronized
    fun release(who: Any, beforeClose: (B) -> Unit): Boolean {
        if (owner !== who) return false
        bus?.let {
            try {
                beforeClose(it)
            } finally {
                it.transactionListener = null
                it.close()
            }
        }
        bus = null
        params = null
        owner = null
        return true
    }

    private fun onTransaction(source: B, ok: Boolean) {
        val action = synchronized(this) {
            if (source !== bus) return
            // Диагностика с другой чётностью (openWithParity) — ошибки на ней
            // ожидаемы, переоткрывать на тех же параметрах бессмысленно.
            watchdog.onResult(ok, clock(), canReopen = params?.parity == "none")
        }
        if (action == BusWatchdog.Action.REOPEN) reopen(source)
    }

    @Synchronized
    private fun reopen(source: B) {
        if (source !== bus) return
        val p = params ?: return
        log(
            "сторож шины: ${watchdog.failureThreshold} ошибок подряд, порт ${p.port} " +
                "якобы открыт (${source.isOpen()}) — переоткрываю (попытка ${watchdog.reopenTotal})"
        )
        val result = try {
            source.reopen(p.port, p.baud, p.parity, reopenPauseMs)
        } catch (e: Throwable) {
            log("сторож шины: переоткрытие упало: $e")
            ModbusRtu.OpenResult.Failed
        }
        val ok = result is ModbusRtu.OpenResult.Ok
        log("сторож шины: переоткрытие ${if (ok) "удалось" else "не удалось ($result)"}")
        events.addLast(
            mapOf(
                "at" to wallClock(),
                "ok" to ok,
                "port" to p.port,
                "attempt" to watchdog.reopenTotal,
                "result" to when (result) {
                    is ModbusRtu.OpenResult.Ok -> "ok"
                    is ModbusRtu.OpenResult.Busy -> "busy"
                    is ModbusRtu.OpenResult.Failed -> "failed"
                },
            )
        )
        while (events.size > MAX_EVENTS) events.removeFirst()
    }

    // Состояние для Dart (BusWatchdogService). События забирает только
    // владелец — чтобы старый движок не съел их у нового.
    @Synchronized
    fun health(who: Any): Map<String, Any?> {
        val mine = owner === who
        val drained = if (mine) events.toList().also { events.clear() } else emptyList()
        return mapOf(
            "owner" to mine,
            "desired" to (params != null),
            "open" to (bus?.isOpen() == true),
            "failures" to watchdog.consecutiveFailures,
            "successes" to watchdog.successTotal,
            "reopens" to watchdog.reopenTotal,
            "events" to drained,
        )
    }

    companion object {
        const val DEFAULT_REOPEN_PAUSE_MS = 500L
        const val MAX_EVENTS = 20
    }
}

// Единственный реестр процесса.
object ProcessBus {
    @Volatile
    private var appContext: Context? = null

    fun init(context: Context) {
        if (appContext == null) appContext = context.applicationContext
    }

    val registry: BusPortRegistry<ModbusRtu> by lazy {
        BusPortRegistry(
            factory = { ModbusRtu(appContext) },
            clock = { SystemClock.elapsedRealtime() },
            log = { Log.w("BusPortRegistry", it) },
        )
    }
}
