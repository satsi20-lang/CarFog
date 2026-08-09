import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/app_state.dart';
import 'cloud_service.dart';
import 'config_service.dart';
import 'security_service.dart';

// Периодический обмен с облаком: отправка накопленных событий,
// получение и выполнение команд, отчёт о результате.
class SyncService {
  static SyncService? _instance;

  final AppNotifier notifier;
  Timer? _timer;
  bool _running = false;
  bool _paused = false;

  SyncService._(this.notifier);

  // Интервал опроса в спокойном состоянии
  static const Duration idleInterval = Duration(seconds: 30);

  // Во время приёма денег и технологического процесса опрос
  // приостанавливается: сеть не должна мешать работе аппарата.
  static bool _isBusyState(AppState s) {
    switch (s) {
      case AppState.payment:
      case AppState.preparing:
      case AppState.compressorStartup:
      case AppState.treating:
      case AppState.shutdown:
        return true;
      default:
        return false;
    }
  }

  // ============================================================
  // УПРАВЛЕНИЕ
  // ============================================================

  static void start(AppNotifier notifier) {
    stop();
    final service = SyncService._(notifier);
    _instance = service;
    service._begin();
  }

  static void stop() {
    _instance?._end();
    _instance = null;
  }

  // Принудительная синхронизация (например, из сервисного меню)
  static Future<void> syncNow() async {
    await _instance?._tick();
  }

  void _begin() {
    notifier.addListener(_onNotifierChanged);
    _paused = _isBusyState(notifier.state);
    _reschedule();
  }

  void _end() {
    notifier.removeListener(_onNotifierChanged);
    _timer?.cancel();
    _timer = null;
  }

  void _onNotifierChanged() {
    final busy = _isBusyState(notifier.state);
    if (busy != _paused) {
      _paused = busy;
      _reschedule();
    }
  }

  void _reschedule() {
    _timer?.cancel();
    _timer = null;

    if (_paused) {
      debugPrint('SyncService: пауза (${notifier.state})');
      return;
    }

    debugPrint('SyncService: опрос каждые ${idleInterval.inSeconds} с');
    _timer = Timer.periodic(idleInterval, (_) => _tick());
    unawaited(_tick());
  }

  // ============================================================
  // ЦИКЛ ОБМЕНА
  // ============================================================

  Future<void> _tick() async {
    if (_running) return;
    if (!CloudService.isCloudEnabled) return;

    _running = true;
    try {
      await CloudService.flush();

      final commands =
          await CloudService.transport.fetchCommands(CloudService.deviceId);

      for (final command in commands) {
        await _execute(command);
      }
    } catch (e) {
      debugPrint('SyncService._tick error: $e');
    } finally {
      _running = false;
    }
  }

  // ============================================================
  // ВЫПОЛНЕНИЕ КОМАНД
  // ============================================================

  Future<void> _execute(CloudCommand command) async {
    debugPrint('SyncService: команда ${command.action} ${command.params}');

    bool ok = false;
    String? result;

    try {
      switch (command.action) {
        case 'ping':
          ok = true;
          result = 'pong';
          break;

        case 'unlock':
          await SecurityService.resetAttempts();
          ok = true;
          result = 'блокировка снята';
          break;

        case 'set_pin':
          final pin = (command.params['pin'] ?? '').toString().trim();
          if (pin.length == 4 && int.tryParse(pin) != null) {
            await notifier.saveConfig(
              notifier.config.copyWith(servicePin: pin),
            );
            await SecurityService.resetAttempts();
            ok = true;
            result = 'PIN изменён';
          } else {
            result = 'PIN должен состоять из 4 цифр';
          }
          break;

        case 'update_config':
          final updated = _applyConfig(notifier.config, command.params);
          await notifier.saveConfig(updated);
          ok = true;
          result = 'настройки применены';
          break;

        case 'factory_reset':
          await _factoryReset();
          ok = true;
          result = 'сброшено к заводским, настройки облака сохранены';
          break;

        case 'reset_session':
          notifier.resetSession();
          ok = true;
          result = 'сессия сброшена';
          break;

        default:
          result = 'неизвестная команда: ${command.action}';
      }
    } catch (e) {
      result = 'ошибка выполнения: $e';
    }

    await CloudService.transport.ackCommand(
      CloudService.deviceId,
      command.id,
      ok,
      result,
    );

    await CloudService.report(
      CloudEventType.commandExecuted,
      data: {
        'action': command.action,
        'ok': ok,
        'result': result,
      },
    );
  }

  // ============================================================
  // ПРИМЕНЕНИЕ НАСТРОЕК
  // ============================================================

  AppConfig _applyConfig(AppConfig current, Map<String, dynamic> params) {
    Map<String, List<String>>? names;
    final rawNames = params['flavorNames'];
    if (rawNames is Map) {
      names = rawNames.map(
        (k, v) => MapEntry(k.toString(), List<String>.from(v as List)),
      );
    }

    return current.copyWith(
      treatmentPriceCents: (params['treatmentPriceCents'] as num?)?.toInt(),
      treatmentDurationS: (params['treatmentDurationS'] as num?)?.toInt(),
      compressorPurgeS: (params['compressorPurgeS'] as num?)?.toInt(),
      pumpAfterHeaterS: (params['pumpAfterHeaterS'] as num?)?.toInt(),
      servicePin: params['servicePin'] as String?,
      flavorNames: names,
    );
  }

  // Сброс к заводским с сохранением подключения к облаку.
  // Без этого аппарат после сброса потерял бы связь навсегда,
  // и починить его можно было бы только на месте.
  Future<void> _factoryReset() async {
    final keep = notifier.config;

    await ConfigService.reset();
    await SecurityService.resetAttempts();

    final fresh = AppConfig(
      deviceId: keep.deviceId,
      cloudUrl: keep.cloudUrl,
      cloudAnonKey: keep.cloudAnonKey,
      cloudToken: keep.cloudToken,
      cloudEnabled: keep.cloudEnabled,
    );

    await notifier.saveConfig(fresh);
  }
}
