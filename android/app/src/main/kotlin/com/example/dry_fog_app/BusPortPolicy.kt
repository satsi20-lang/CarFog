package com.example.dry_fog_app

// Допустимые узлы шины RS485 — зеркало BusPortPolicy в lib/models/bus_map.dart
// (проверка и там, и здесь: нативная сторона не доверяет вызывающему).
// Запрещённые узлы нельзя открывать никогда, даже если их выбрали вручную:
// ttyS1 занят Bluetooth на Syoung SY156-A510, ttyUSB0..2 — USB-модем 4G.
object BusPortPolicy {
    private val shape = Regex("^/dev/(ttyS|ttyUSB|ttyACM)[0-9]+$")

    val forbidden: Set<String> = setOf(
        "/dev/ttyS1",
        "/dev/ttyUSB0",
        "/dev/ttyUSB1",
        "/dev/ttyUSB2",
    )

    fun isShapeValid(port: String): Boolean = shape.matches(port)

    fun isAllowed(port: String): Boolean =
        isShapeValid(port) && port !in forbidden
}
