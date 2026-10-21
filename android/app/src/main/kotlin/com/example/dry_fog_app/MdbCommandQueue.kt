package com.example.dry_fog_app

import com.example.dry_fog_app.MdbCashlessProtocol.Event
import java.io.IOException

// Очередь команд стенда MDB (1.10.12). Адаптер Wafer принимает одну команду
// за раз (журнал CARFOG-100, 21.10.2026 17:55: 13 02 00 01 и 13 04 с
// разницей 3 мс — один ответ FF, 10 07 не пришло). Поэтому:
//   * в полёте не больше одной команды;
//   * следующая уходит только после ответа на предыдущую — ACK 00 (для setup
//     — ответ 01 …), FF (отказ) или таймаут ACK_TIMEOUT_MS;
//   * и не раньше GAP_MS после этого ответа.
// Через очередь идут все команды: кнопки, опрос, тестовая оплата.
//
// Без Android-зависимостей и без своих потоков: вызывается только с одного
// логического потока стенда (MdbUsbBench), время — подставные часы.
class MdbCommandQueue(
    private val send: (data: ByteArray, label: String) -> Unit,
    private val note: (String) -> Unit,
    private val clock: () -> Long,
    private val ackTimeoutMs: Long = ACK_TIMEOUT_MS,
    private val gapMs: Long = GAP_MS,
) {
    enum class Result(val title: String) {
        ACK("ACK 00"),
        NAK("отказ адаптера (FF)"),
        TIMEOUT("нет ACK за 2 с"),
        SEND_FAILED("ошибка отправки"),
        DROPPED("снята с очереди (порт закрыт)"),
    }

    class Command(
        val data: ByteArray,
        val label: String,
        val onDone: (Result, Event?) -> Unit = { _, _ -> },
    ) {
        // Ответ на setup — данные настройки, а не 00.
        val acceptsSetupReply = data.contentEquals(MdbCashlessProtocol.SETUP)
    }

    // Общий слушатель итогов любых команд (стенду — какие 14 01/14 00 приняты).
    var listener: ((Command, Result) -> Unit)? = null

    private val pending = ArrayDeque<Command>()
    private var inFlight: Command? = null
    private var sentAt = 0L
    private var readyAt = 0L
    private var clearing = false

    val busy: Boolean get() = inFlight != null || pending.isNotEmpty()
    val size: Int get() = pending.size + (if (inFlight != null) 1 else 0)

    fun enqueue(cmd: Command) {
        // Порт закрывается: колбэки снятых команд не должны ничего отправить.
        if (clearing) return
        pending.addLast(cmd)
        pump()
    }

    // Кадр адаптера. true — кадр был ответом на команду в полёте.
    fun onEvent(e: Event): Boolean {
        val cmd = inFlight ?: return false
        val result = when {
            e == Event.Ack -> Result.ACK
            e is Event.Setup && cmd.acceptsSetupReply -> Result.ACK
            e == Event.Nak -> Result.NAK
            else -> return false
        }
        complete(cmd, result, e)
        return true
    }

    fun tick() {
        val cmd = inFlight
        if (cmd != null && clock() - sentAt >= ackTimeoutMs) complete(cmd, Result.TIMEOUT, null)
        pump()
    }

    // Порт закрыт: всё, что не ушло, снимается; ответа на команду в полёте не будет.
    fun clear() {
        val dropped = listOfNotNull(inFlight) + pending
        inFlight = null
        pending.clear()
        clearing = true
        try {
            for (c in dropped) c.onDone(Result.DROPPED, null)
        } finally {
            clearing = false
        }
    }

    private fun complete(cmd: Command, result: Result, e: Event?) {
        inFlight = null
        readyAt = clock() + gapMs
        if (result != Result.ACK) note("${cmd.label}: ${result.title}")
        listener?.invoke(cmd, result)
        cmd.onDone(result, e)
    }

    private fun pump() {
        if (inFlight != null || pending.isEmpty() || clock() < readyAt) return
        val cmd = pending.removeFirst()
        try {
            send(cmd.data, cmd.label)
        } catch (e: IOException) {
            readyAt = clock() + gapMs
            note("${cmd.label}: ошибка отправки: ${e.message ?: e}")
            cmd.onDone(Result.SEND_FAILED, null)
            return
        }
        inFlight = cmd
        sentAt = clock()
    }

    companion object {
        const val ACK_TIMEOUT_MS = 2_000L
        const val GAP_MS = 300L
    }
}
