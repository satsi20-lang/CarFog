import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/app_state.dart';
import 'cloud_service.dart';
import 'config_service.dart';
import 'modbus_service.dart';
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

  // Периодический снимок счётчика энергии (Шаг 33, задача 4) — встроен в
  // этот же тик, отдельный таймер не заводим: пауза на время приёма денег
  // и техпроцесса здесь уже есть (_isBusyState), значит и снимок сам
  // собой не будет сниматься, пока шина занята чем-то важнее.
  static const Duration energyReadingInterval = Duration(hours: 1);
  DateTime? _lastEnergyReadingAt;

  // Слепок настроек для облака (Шаг 34, задача 3) — отправляется тем же
  // опросом, но не каждый тик: только при первом опросе после запуска
  // (_lastConfigSentAt == null), при фактическом изменении содержимого
  // или раз в сутки принудительно (страховка от рассинхронизации).
  static const Duration configForceInterval = Duration(hours: 24);
  Map<String, dynamic>? _lastSentConfigSnapshot;
  DateTime? _lastConfigSentAt;

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
      await _maybeReportEnergy();
      await CloudService.flush();

      // Слепок настроек (Шаг 34) — задача 2.4: если сборка почему-то
      // упала, просто не прикладываем его в этот раз, опрос команд
      // всё равно должен отработать как раньше.
      Map<String, dynamic>? configToSend;
      try {
        configToSend = _configToSendOrNull();
      } catch (e) {
        debugPrint('SyncService: не удалось собрать слепок настроек: $e');
      }

      if (configToSend != null) {
        debugPrint('SyncService: отправляю слепок настроек: ${jsonEncode(configToSend)}');
      }

      final result = await CloudService.transport.fetchCommands(
        CloudService.deviceId,
        config: configToSend,
      );

      // configReported — сервер реально принял именно этот слепок
      // (задача 3.3: неудачная отправка не считается отправленной,
      // повторится сама на следующем опросе).
      if (configToSend != null) {
        if (result.configReported) {
          _lastSentConfigSnapshot = configToSend;
          _lastConfigSentAt = DateTime.now();
          debugPrint('SyncService: слепок настроек принят сервером');
        } else {
          debugPrint('SyncService: слепок настроек НЕ принят, повторю на следующем опросе');
        }
      }

      for (final command in result.commands) {
        await _execute(command);
      }
    } catch (e) {
      debugPrint('SyncService._tick error: $e');
    } finally {
      _running = false;
    }
  }

  // null, если слепок отправлять не нужно: настройки не менялись с
  // последней успешной отправки и сутки ещё не прошли. Сравнение — по
  // содержимому (jsonEncode), а не по ссылке на Map (задача 3.2).
  Map<String, dynamic>? _configToSendOrNull() {
    final snapshot = notifier.config.reportedSnapshot();

    final last = _lastSentConfigSnapshot;
    final sentAt = _lastConfigSentAt;
    if (last != null && sentAt != null) {
      final changed = jsonEncode(snapshot) != jsonEncode(last);
      final forceDue = DateTime.now().difference(sentAt) >= configForceInterval;
      if (!changed && !forceDue) return null;
    }
    return snapshot;
  }

  // Снимок счётчика раз в час (Шаг 33, задача 4.1). Этот метод вызывается
  // только из _tick(), которая сама не запускается в "занятых" состояниях
  // (задача 4.2) — отдельной проверки busy-state здесь не нужно. Если
  // снимок почему-то не удался (шина всё же занята чем-то ещё, ошибка
  // чтения) — время последнего успешного снимка не обновляется, и попытка
  // просто повторится на следующем тике.
  Future<void> _maybeReportEnergy() async {
    final last = _lastEnergyReadingAt;
    if (last != null && DateTime.now().difference(last) < energyReadingInterval) {
      return;
    }

    final energy = await ModbusService.readEnergy();
    if (energy == null) return;
    final monthly = await ModbusService.getMonthlyEnergy();

    _lastEnergyReadingAt = DateTime.now();
    await CloudService.report(CloudEventType.energyReading, data: {
      'voltage': energy['voltage'],
      'current': energy['current'],
      'power': energy['power'],
      'total_kwh': energy['totalEnergy'],
      'month_kwh': monthly,
    });
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
