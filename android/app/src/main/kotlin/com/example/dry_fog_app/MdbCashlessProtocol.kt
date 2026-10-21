package com.example.dry_fog_app

import java.math.BigDecimal

// Протокол кассового устройства MDB (уровень 1) через адаптер Wafer
// MDB-RS232 — только для стенда «Терминал (стенд)». Без Android-
// зависимостей, чтобы проверяться обычными JVM-тестами.
//
// Формат подтверждён на железе (1.10.11, паспорт стенда): команды шлются
// байтами; адаптер отвечает ТЕКСТОМ ASCII — hex-символы через пробел, кадр
// кончается \r\n. Ответ на нашу команду идёт без префикса ("00" — ACK,
// "01 …" — ответ на setup с контрольной суммой), события терминала — с
// префиксом 10 ("10 03 03 E8", "10 07"). Разбор консервативный: всё, что не
// совпало с паспортом точно, — «не распознано», без догадок.
object MdbCashlessProtocol {

    val SETUP = byteArrayOf(0x11, 0x00, 0x01, 0x00, 0x00, 0x00)
    val PRICES = bytes(0x11, 0x01, 0xFF, 0xFF, 0x00, 0x00)
    val ENABLE = byteArrayOf(0x14, 0x01)
    val DISABLE = byteArrayOf(0x14, 0x00)
    val READER_CANCEL = byteArrayOf(0x14, 0x02)
    val VEND_CANCEL = byteArrayOf(0x13, 0x01)
    // Ошибка выдачи: возврат денег после одобрения (товар не выдан).
    val VEND_FAILURE = byteArrayOf(0x13, 0x03)
    val SESSION_COMPLETE = byteArrayOf(0x13, 0x04)

    const val MAX_UNITS = 0xFFFF
    const val MAX_ITEM = 0xFFFF
    // Префикс событий терминала в выводе адаптера Wafer (адрес кассового
    // устройства MDB).
    const val EVENT_PREFIX = 0x10

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
    // делится на шаг терминала нацело или выходит за 0..65535 единиц — ошибка
    // с цифрами, а не округление. Наружу только IllegalArgumentException
    // (деление точное, через остаток — ArithmeticException не бывает).
    fun priceUnits(amount: String, scale: Int, decimals: Int): Int {
        require(scale in 1..255) { "масштаб $scale вне диапазона 1..255 (ответ на setup)" }
        require(decimals in 0..9) { "число знаков $decimals вне диапазона 0..9 (ответ на setup)" }
        val text = amount.trim().replace(',', '.')
        require(AMOUNT_RE.matches(text)) {
            "сумма должна быть числом вида 0.10, введено: \"${amount.trim()}\""
        }
        val value = BigDecimal(text)
        val step = BigDecimal(scale).movePointLeft(decimals)
        val stepText = "шаг терминала ${euro(step, decimals)} € (масштаб $scale, знаков $decimals)"
        val (units, rest) = value.divideAndRemainder(step)
        require(rest.signum() == 0) { "сумма $text € не делится на $stepText" }
        require(units <= BigDecimal(MAX_UNITS)) {
            "сумма $text € = ${units.toBigInteger()} ед. — вне диапазона 0..$MAX_UNITS ед.; " +
                "$stepText, максимум ${formatAmount(MAX_UNITS, scale, decimals)} €"
        }
        return units.toInt()
    }

    private val AMOUNT_RE = Regex("""\d{1,7}(\.\d{1,9})?""")

    private fun euro(v: BigDecimal, decimals: Int): String =
        v.setScale(maxOf(decimals, 2)).toPlainString()

    // Единицы терминала → сумма в евро (units × масштаб × 10^-знаков), не
    // меньше двух знаков после точки: 10 ед. при масштабе 1 и 2 знаках = "0.10".
    fun formatAmount(units: Int, scale: Int, decimals: Int): String {
        return euro(BigDecimal(units.toLong() * scale).movePointLeft(decimals), decimals)
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
    )

    // Ответ на настройку: 01 уровень страна(2) масштаб знаки отклик опции
    // контрольная сумма. С железа: "01 01 19 78 01 02 78 0D 1B" (EUR 1978,
    // масштаб 1, 2 знака, отклик 120 с, опции 0D, 1B = сумма первых 8 байт).
    // Без контрольной суммы или с неверной — null: масштаб из такого ответа
    // не используем.
    fun parseSetupReply(text: String): SetupReply? =
        (parseFrame(text) as? Event.Setup)?.reply

    sealed class Event {
        object Ack : Event() {
            override fun toString() = "Ack"
        }
        data class Setup(val reply: SetupReply) : Event()
        // funds/amount null — терминал не прислал сумму.
        data class BeginSession(val funds: Int?) : Event()
        object SessionCancelRequest : Event() {
            override fun toString() = "SessionCancelRequest"
        }
        data class VendApproved(val amount: Int?) : Event()
        object VendDenied : Event() {
            override fun toString() = "VendDenied"
        }
        object EndSession : Event() {
            override fun toString() = "EndSession"
        }
        object Cancelled : Event() {
            override fun toString() = "Cancelled"
        }
        data class Unrecognized(val reason: String) : Event()
    }

    // Один кадр адаптера (текст без \r\n или с ним) → событие.
    fun parseFrame(text: String): Event {
        val data = try {
            parseHex(text)
        } catch (e: IllegalArgumentException) {
            return Event.Unrecognized("не hex: ${e.message}")
        }
        val u = { i: Int -> data[i].toInt() and 0xFF }
        val word = { i: Int -> (u(i) shl 8) or u(i + 1) }
        if (u(0) == EVENT_PREFIX) {
            if (data.size < 2) return Event.Unrecognized("префикс 10 без кода события")
            val code = u(1)
            val n = data.size
            return when {
                code == 0x03 && n == 4 -> Event.BeginSession(word(2))
                code == 0x03 && n == 2 -> Event.BeginSession(null)
                code == 0x04 && n == 2 -> Event.SessionCancelRequest
                code == 0x05 && n == 4 -> Event.VendApproved(word(2))
                code == 0x05 && n == 2 -> Event.VendApproved(null)
                code == 0x06 && n == 2 -> Event.VendDenied
                code == 0x07 && n == 2 -> Event.EndSession
                code == 0x08 && n == 2 -> Event.Cancelled
                else -> Event.Unrecognized("событие 10 %02X длиной $n байт не из паспорта".format(code))
            }
        }
        if (u(0) == 0x00 && data.size == 1) return Event.Ack
        if (u(0) == 0x01) {
            if (data.size != 9) return Event.Unrecognized("ответ setup длиной ${data.size} байт, ждали 9")
            if (!hasValidChecksum(data)) {
                return Event.Unrecognized(
                    "ответ setup: контрольная сумма %02X, а сумма байтов %02X".format(u(8), checksum(data, 0, 8))
                )
            }
            if (u(4) == 0) return Event.Unrecognized("ответ setup: масштаб 0")
            return Event.Setup(
                SetupReply(
                    level = u(1),
                    country = word(2),
                    scale = u(4),
                    decimals = u(5),
                    maxResponseSec = u(6),
                    options = u(7),
                )
            )
        }
        return Event.Unrecognized("кадр %02X… не из паспорта".format(u(0)))
    }

    fun describe(event: Event): String = when (event) {
        Event.Ack -> "ACK"
        is Event.Setup -> event.reply.let {
            "ответ на setup: уровень ${it.level}, страна %04X, масштаб ${it.scale}, знаков ${it.decimals}, "
                .format(it.country) + "отклик ${it.maxResponseSec} с, опции %02X, контрольная сумма верна"
                .format(it.options)
        }
        is Event.BeginSession -> "начало сессии, доступно ${event.funds?.let { "$it ед." } ?: "— (сумма не пришла)"}"
        Event.SessionCancelRequest -> "запрос отмены сессии (нужно ответить 13 04)"
        is Event.VendApproved -> "оплата одобрена, ${event.amount?.let { "$it ед." } ?: "— (сумма не пришла)"}"
        Event.VendDenied -> "отказ в оплате"
        Event.EndSession -> "конец сессии"
        Event.Cancelled -> "отменено"
        is Event.Unrecognized -> "не распознано (${event.reason})"
    }

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
}
