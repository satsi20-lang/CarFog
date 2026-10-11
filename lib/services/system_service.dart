import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app_log_service.dart';

// Состояние киоска через Device Owner (KioskPolicy на нативной стороне).
class KioskPolicyState {
  final bool deviceOwner;
  final bool lockEnabled;
  final bool lockTaskActive;
  final Duration exitRemaining;

  const KioskPolicyState({
    required this.deviceOwner,
    required this.lockEnabled,
    required this.lockTaskActive,
    required this.exitRemaining,
  });

  static const none = KioskPolicyState(
    deviceOwner: false,
    lockEnabled: false,
    lockTaskActive: false,
    exitRemaining: Duration.zero,
  );

  bool get temporaryExit => exitRemaining > Duration.zero;

  // Обратный отсчёт имеет смысл, только когда блокировка включена: при
  // выключенной таймер ничего не возвращает.
  bool get showExitCountdown => lockEnabled && temporaryExit;

  // Ответ канала; любые отсутствующие/чужие поля — «нет Device Owner».
  factory KioskPolicyState.fromMap(Map? m) {
    if (m == null) return none;
    final ms = m['exit_remaining_ms'];
    return KioskPolicyState(
      deviceOwner: m['device_owner'] == true,
      lockEnabled: m['lock_enabled'] == true,
      lockTaskActive: m['lock_task_active'] == true,
      exitRemaining: Duration(milliseconds: ms is int && ms > 0 ? ms : 0),
    );
  }
}

// Мост к нативной стороне киоск-режима и причины запуска (Шаг 32,
// задачи 3/6): включение/выключение роли домашнего экрана, системный
// экран выбора домашнего приложения, признак "запуск после аварии/после
// загрузки". Не ходит на Modbus-шину — обычный MethodChannel, без фоновой
// очереди.
class SystemService {
  static const _channel = MethodChannel('com.carfog.dryfog/system');

  // Включает/выключает роль домашнего экрана у приложения (activity-alias
  // на нативной стороне). Вызывать только из явного действия техника
  // (тумблер в сервисном меню) — НЕ при каждом старте приложения: такая
  // "подстраховка" раньше была в main.dart и создавала реальную гонку между
  // несколькими экземплярами движка Flutter, самопроизвольно откатывая
  // только что включённый киоск-режим (см. историю правок main.dart).
  static Future<void> setKioskHomeEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setKioskHomeEnabled', {'enabled': enabled});
    } catch (e) {
      debugPrint('SystemService.setKioskHomeEnabled error: $e');
    }
  }

  // Открывает системный экран "Приложение по умолчанию → Домашний экран" —
  // для кнопки "Открыть системный рабочий стол" (выход из киоска для
  // обслуживания планшета).
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

  // Сведения о ТОМ, как именно был запущен этот процесс (задача
  // "приложение остаётся в фоне при холодном старте") — intent action и
  // категории, с которыми поднялась MainActivity, и был ли этот экземпляр
  // корнем задачи. Уходит в данные события app_started, чтобы отличить
  // холодный старт от программной перезагрузки прямо в облачной панели,
  // не подключаясь к планшету.
  static Future<Map<String, dynamic>> getLaunchDiagnostics() async {
    try {
      final result = await _channel.invokeMethod<Map>('getLaunchDiagnostics');
      return result?.map((k, v) => MapEntry(k as String, v)) ?? const {};
    } catch (e) {
      debugPrint('SystemService.getLaunchDiagnostics error: $e');
      return const {};
    }
  }

  // Ответ на вопрос нативной стороны перед завершением процесса
  // (restart_app): "аппарат всё ещё в покое?". Подключается из main().
  static Future<bool> Function()? idleForRestartCheck;

  // Принимать вызовы нативной стороны в Dart. Вызывается один раз из main().
  static void init() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'kioskLog') {
        AppLog.log('Kiosk', '${call.arguments}');
        return null;
      }
      if (call.method == 'isIdleForRestart') {
        final check = idleForRestartCheck;
        // Нет проверки — отказ (fail-safe): лучше не перезапускать.
        return check == null ? false : await check();
      }
      return null;
    });
  }

  // Каталог файлов приложения (постоянный журнал стартует до runApp).
  static Future<String?> getFilesDir() async {
    try {
      return await _channel.invokeMethod<String>('getFilesDir');
    } catch (e) {
      debugPrint('SystemService.getFilesDir error: $e');
      return null;
    }
  }

  // Удалённая команда restart_app (R1): нативная сторона планирует подъём
  // приложения через AlarmManager и завершает процесс. Вызывающий код ОБЯЗАН
  // сам проверить, что аппарат в покое (RemoteCommands), и отправить ack
  // ДО вызова: процесс умрёт примерно через 1,5 с.
  static Future<void> restartApp() async {
    try {
      await _channel.invokeMethod('restartApp');
    } catch (e) {
      debugPrint('SystemService.restartApp error: $e');
    }
  }

  // ---- Киоск через Device Owner ----
  // Действия возвращают 'ok', 'no_device_owner' или 'error: …'; события
  // журнала пишет нативная сторона (канал kioskLog → AppLog).

  static Future<KioskPolicyState> kioskPolicyState() async {
    try {
      return KioskPolicyState.fromMap(
        await _channel.invokeMethod<Map>('kioskPolicyState'),
      );
    } catch (e) {
      debugPrint('SystemService.kioskPolicyState error: $e');
      return KioskPolicyState.none;
    }
  }

  static Future<String> _kioskCall(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<String>(method, args) ?? 'error: null';
    } catch (e) {
      AppLog.log('Kiosk', '$method: ошибка канала: $e');
      return 'error: $e';
    }
  }

  static Future<String> kioskSetLockEnabled(bool enabled) =>
      _kioskCall('kioskSetLockEnabled', {'enabled': enabled});

  static Future<String> kioskTemporaryExit({required bool openSettings}) =>
      _kioskCall('kioskTemporaryExit', {'openSettings': openSettings});

  static Future<String> kioskClearDeviceOwner() =>
      _kioskCall('kioskClearDeviceOwner');
}
