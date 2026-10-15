package com.example.dry_fog_app

import java.math.BigDecimal

// Протокол кассового устройства MDB (уровень 1) через адаптер Wafer
// MDB-RS232 — только для стенда «Терминал (стенд)» (1.10.9). Без Android-
// зависимостей, чтобы проверяться обычными JVM-тестами.
//
// Команды шлются байтами, ответы адаптера приходят ТЕКСТОМ из hex-символов
// (инструкция Wafer, стр. 10). Разбор событий намеренно консервативный:
// распознаются только 03/05/06/07/08 точной длины (с контрольной суммой или
// без), всё остальное — «не распознано», без догадок. Формат событий на
// реальном адаптере не подтверждён.
object MdbCashlessProtocol {

    val SETUP = byteArrayOf(0x11, 0x00, 0x01, 0x00, 0x00, 0x00)
    val PRICES = bytes(0x11, 0x01, 0xFF, 0xFF, 0x00, 0x00)
    val ENABLE = byteArrayOf(0x14, 0x01)
    val DISABLE = byteArrayOf(0x14, 0x00)
    val READER_CANCEL = byteArrayOf(0x14, 0x02)
    val VEND_CANCEL = byteArrayOf(0x13, 0x01)
    val SESSION_COMPLETE = byteArrayOf(0x13, 0x04)

    const val MAX_UNITS = 0xFFFF
    const val MAX_ITEM = 0xFFFF

    fun vendRequest(units: Int, item: Int = 1): ByteArray {
        require(units in 0..MAX_UNITS) { "цена вне диапазона 0..65535 единиц" }
        require(item in 0..MAX_ITEM) { "номер товара вне диапазона 0..65535" }
        return bytes(0x13, 0x00, units shr 8, units and 0xFF, item shr 8, item and 0xFF)
    }

    fun vendSuccess(item: Int = 1): ByteArray {
        require(item in 0..MAX_ITEM) { "номер товара вне диапазона 0..65535" }
        return bytes(0x13, 0x02, item shr 8, item and 0xFF)
    }

    // 17 00 + 29 байт: 3 ASCII код производителя, 12 ASCII серийный номер,
    // 12 ASCII модель (дополняются пробелами справа), 2 байта версии.
    fun requestId(manufacturer: String, serial: String, model: String, version: Int): ByteArray {
        require(version in 0..0xFFFF) { "версия вне диапазона 0..65535" }
        val out = ByteArray(2 + 29)
        out[0] = 0x17
        out[1] = 0x00
        ascii(manufacturer, 3).copyInto(out, 2)
        ascii(serial, 12).copyInto(out, 5)
        ascii(model, 12).copyInto(out, 17)
        out[29] = (version shr 8).toByte()
        out[30] = (version and 0xFF).toByte()
        return out
    }

    private fun ascii(s: String, len: Int): ByteArray {
        require(s.length <= len) { "поле длиннее $len символов: \"$s\"" }
        require(s.all { it.code in 0x20..0x7E }) { "только печатные ASCII-символы: \"$s\"" }
        return s.padEnd(len, ' ').toByteArray(Charsets.US_ASCII)
    }

    // Сумма → единицы терминала: amount / (scale * 10^-decimals). Сумма — строка
    // («0.10» или «0,10»), чтобы не терять точность на double. Если сумма не
    // делится на единицу терминала нацело, это ошибка, а не округление.
    fun priceUnits(amount: String, scale: Int, decimals: Int): Int {
        require(scale in 1..255) { "масштаб вне диапазона 1..255" }
        require(decimals in 0..9) { "число знаков вне диапазона 0..9" }
        val value = try {
            BigDecimal(amount.trim().replace(',', '.'))
        } catch (e: NumberFormatException) {
            throw IllegalArgumentException("сумма не число: \"$amount\"")
        }
        require(value.signum() >= 0) { "сумма отрицательная" }
        val minor = value.movePointRight(decimals)
        val units = minor.divide(BigDecimal(scale))
            .let { if (it.stripTrailingZeros().scale() > 0) null else it }
            ?: throw IllegalArgumentException("сумма не кратна единице терминала")
        require(units <= BigDecimal(MAX_UNITS)) { "цена вне диапазона 0..65535 единиц" }
        return units.toInt()
    }

    // Проверка hex-ввода: пробелы допускаются, длина чётная, только 0-9 A-F.
    fun parseHex(text: String): ByteArray {
        val s = text.filterNot { it.isWhitespace() }.uppercase()
        require(s.isNotEmpty()) { "пустой ввод" }
        require(s.length % 2 == 0) { "нужна чётная длина" }
        require(s.all { it in '0'..'9' || it in 'A'..'F' }) { "только символы 0-9 A-F" }
        return ByteArray(s.length / 2) { i -> s.substring(i * 2, i * 2 + 2).toInt(16).toByte() }
    }

    fun toHex(data: ByteArray, sep: String = " "): String =
        data.joinToString(sep) { "%02X".format(it.toInt() and 0xFF) }

    // Контрольная сумма MDB: сумма байтов по модулю 256.
    fun checksum(data: ByteArray, from: Int = 0, to: Int = data.size): Int {
        var sum = 0
        for (i in from until to) sum += data[i].toInt() and 0xFF
        return sum and 0xFF
    }

    fun hasValidChecksum(data: ByteArray): Boolean =
        data.size >= 2 && checksum(data, 0, data.size - 1) == (data.last().toInt() and 0xFF)

    data class SetupReply(
        val level: Int,
        val country: Int,
        val scale: Int,
        val decimals: Int,
        val maxResponseSec: Int,
        val options: Int,
        // null — контрольной суммы в ответе нет; true/false — сошлась ли.
        val checksumOk: Boolean?,
    )

    // Ответ на настройку: 01 уровень страна(2) масштаб десятичные отклик
    // опции [контрольная сумма]. Пример из инструкции: 010109720102070D94.
    fun parseSetupReply(text: String): SetupReply? {
        val data = try { parseHex(text) } catch (e: IllegalArgumentException) { return null }
        if (data.size !in 8..9 || data[0].toInt() != 0x01) return null
        val u = { i: Int -> data[i].toInt() and 0xFF }
        return SetupReply(
            level = u(1),
            country = (u(2) shl 8) or u(3),
            // Масштаб 0 по стандарту не бывает; не подменяем его единицей,
            // а считаем ответ неразобранным.
            scale = u(4).takeIf { it != 0 } ?: return null,
            decimals = u(5),
            maxResponseSec = u(6),
            options = u(7),
            checksumOk = if (data.size == 9) hasValidChecksum(data) else null,
        )
    }

    sealed class Event {
        abstract val checksumOk: Boolean?
        data class BeginSession(val funds: Int, override val checksumOk: Boolean?) : Event()
        data class VendApproved(val amount: Int, override val checksumOk: Boolean?) : Event()
        data class VendDenied(override val checksumOk: Boolean?) : Event()
        data class EndSession(override val checksumOk: Boolean?) : Event()
        data class Cancelled(override val checksumOk: Boolean?) : Event()
        data class Unrecognized(val reason: String) : Event() {
            override val checksumOk: Boolean? = null
        }
    }

    // Длина события БЕЗ контрольной суммы по первому байту.
    private val EVENT_LEN = mapOf(0x03 to 3, 0x05 to 3, 0x06 to 1, 0x07 to 1, 0x08 to 1)

    fun parseEvent(text: String): Event {
        val data = try {
            parseHex(text)
        } catch (e: IllegalArgumentException) {
            return Event.Unrecognized("не hex: ${e.message}")
        }
        val code = data[0].toInt() and 0xFF
        val len = EVENT_LEN[code] ?: return Event.Unrecognized("код %02X не из списка 03/05/06/07/08".format(code))
        val checksumOk = when (data.size) {
            len -> null
            // Лишний байт принимаем только как контрольную сумму, и только если сошлась.
            len + 1 -> if (hasValidChecksum(data)) true else
                return Event.Unrecognized("лишний байт не совпал с контрольной суммой")
            else -> return Event.Unrecognized("длина ${data.size} байт не подходит к коду %02X".format(code))
        }
        val word = { ((data[1].toInt() and 0xFF) shl 8) or (data[2].toInt() and 0xFF) }
        return when (code) {
            0x03 -> Event.BeginSession(word(), checksumOk)
            0x05 -> Event.VendApproved(word(), checksumOk)
            0x06 -> Event.VendDenied(checksumOk)
            0x07 -> Event.EndSession(checksumOk)
            else -> Event.Cancelled(checksumOk)
        }
    }

    fun describe(event: Event): String {
        val chk = when (event.checksumOk) {
            true -> ", контрольная сумма верна"
            else -> ""
        }
        return when (event) {
            is Event.BeginSession -> "начало сессии, доступно ${event.funds} ед.$chk"
            is Event.VendApproved -> "оплата одобрена, ${event.amount} ед.$chk"
            is Event.VendDenied -> "отказ в оплате$chk"
            is Event.EndSession -> "конец сессии$chk"
            is Event.Cancelled -> "отменено$chk"
            is Event.Unrecognized -> "не распознано (${event.reason})"
        }
    }

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
}
