import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Мост к нативной стороне киоск-режима и причины запуска (Шаг 32,
// задачи 3/6): включение/выключение роли домашнего экрана, системный
// экран выбора домашнего приложения, признак "запуск после аварии/после
// загрузки". Не ходит на Modbus-шину — обычный MethodChannel, без фоновой
// очереди.
class SystemService {
  static const _channel = MethodChannel('com.carfog.dryfog/system');

  // Включает/выключает роль домашнего экрана у приложения (activity-alias
  // на нативной стороне). Идемпотентно — безопасно вызывать при каждом
  // старте, чтобы синхронизировать состояние PackageManager с AppConfig.
  static Future<void> setKioskHomeEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setKioskHomeEnabled', {'enabled': enabled});
    } catch (e) {
      debugPrint('SystemService.setKioskHomeEnabled error: $e');
    }
  }

  // Открывает системный экран "Приложение по умолчанию → Домашний экран" —
  // единственный надёжный способ и предложить выбрать наше приложение сразу
  // после включения киоск-режима, и позже выйти из него для обслуживания.
  static Future<void> openHomeSettings() async {
    try {
      await _channel.invokeMethod('openHomeSettings');
    } catch (e) {
      debugPrint('SystemService.openHomeSettings error: $e');
    }
  }

  // 'crash' | 'boot' | 'normal'. Однократный вызов: нативная сторона сразу
  // сбрасывает признак аварии, повторный вызов в рамках этого же запуска
  // вернёт уже 'normal' для причины "авария" (но boot/normal определяются
  // без сброса состояния, так что 'boot' остаётся стабильным до перезапуска).
  static Future<String> consumeStartReason() async {
    try {
      return await _channel.invokeMethod<String>('consumeStartReason') ??
          'normal';
    } catch (e) {
      debugPrint('SystemService.consumeStartReason error: $e');
      return 'normal';
    }
  }
}
