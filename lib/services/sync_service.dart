import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/app_state.dart';
import '../models/update_limits.dart';
import 'cloud_service.dart';
import 'diagnostics_service.dart';
import 'master_code_service.dart';
import 'pin_policy.dart';
import 'modbus_service.dart';
import 'remote_command_guard.dart';
import 'remote_commands.dart';
import 'update_service.dart';

// Периодический обмен с облаком: отправка накопленных событий,
// получение и выполнение команд, отчёт о результате.
class SyncService {
  static SyncService? _instance;

  final AppNotifier notifier;
  Timer? _timer;
  bool _running = false;
  bool _paused = false;

  SyncService._(this.notifier);

  // Время последнего УСПЕШНОГО опроса облака (HTTP 200, ok:true) — для сигнала
  // здоровья после обновления. null — с запуска ещё не было.
  static DateTime? lastPollOkAt;

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
      // Отложенный пакет диагностики (не ушёл из-за связи) — повторная
      // отправка; в занятых состояниях тик не выполняется вовсе.
      await DiagnosticsService.retryPending();

      // Слепок настроек (Шаг 34) — задача 2.4: если сборка почему-то
      // упала, просто не прикладываем его в этот раз, опрос команд
      // всё равно должен отработать как раньше.
      Map<String, dynamic>? configToSend;
      try {
        configToSend = await _configToSendOrNull();
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

      if (result.ok) lastPollOkAt = DateTime.now();
      for (final command in result.commands) {
        await _execute(command, serverTime: result.serverTime);
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
  Future<Map<String, dynamic>?> _configToSendOrNull() async {
    final snapshot = notifier.config.reportedSnapshot();

    // Признак "выведен из обслуживания" и активные отладочные режимы идут в
    // регулярную отправку состояния (задача "вывод аппарата из
    // обслуживания", требование 10): в веб-панели видно и без нового
    // события, а любое изменение (в том числе автосброс отладочного
    // режима через 30 минут) меняет содержимое слепка и уходит само.
    final oos = notifier.outOfService;
    snapshot['out_of_service'] = oos != null;
    if (oos != null) {
      snapshot['out_of_service_code'] = oos.code;
      snapshot['out_of_service_since'] = oos.since.toIso8601String();
    }
    // Оплата заблокирована конфигурацией (термопара/счётчик не отмечены
    // установленными) — не отказ, в постоянный признак не пишется.
    snapshot['payment_blocked_by_config'] = notifier.missingRequiredDevices;
    snapshot['debug_modes'] = await ModbusService.activeDebugModes();
    // Ввод в эксплуатацию (R2.0): мастер-код записан? PIN всё ещё слабый
    // (начальный)? Видно в панели — аппарат без записанного кода и со
    // слабым PIN считается незавершённым.
    // Обновление приложения (R2): версия, наличие резерва, итог последнего
    // обновления, «ADB по сети».
    final upd = await UpdateService.status();
    snapshot['app_version'] = upd['version_name'];
    snapshot['app_version_code'] = upd['version_code'];
    snapshot['rollback_available'] = upd['rollback_available'];
    snapshot['last_update_result'] = (upd['last'] as Map?)?['result'];
    snapshot['adb_network'] = UpdateService.adbNetwork;
    // Тестовая сборка без сигнала здоровья (только для проверки отката): в
    // панели должна быть видна, в боевых аппаратах всегда false.
    snapshot['skip_health_signal_build'] = UpdateLimits.skipHealthSignalBuild;
    snapshot['master_code_acknowledged'] = await MasterCodeService.isAcknowledged();
    snapshot['service_pin_weak'] = PinPolicy.isWeak(notifier.config.servicePin);

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

  Future<void> _execute(CloudCommand command, {DateTime? serverTime}) async {
    // PIN и прочие параметры в журнал не пишутся: только действие и id.
    debugPrint('SyncService: команда ${command.action} id=${command.id}');

    final outcome = await RemoteCommands.handle(
      command,
      notifier,
      serverTime: serverTime,
    );

    await CloudService.transport.ackCommand(
      CloudService.deviceId,
      command.id,
      outcome.ok,
      outcome.result,
    );

    await CommandGuard.record(
      action: command.action,
      ok: outcome.ok,
      result: outcome.result,
    );

    await CloudService.report(
      CloudEventType.commandExecuted,
      data: {
        'action': command.action,
        'ok': outcome.ok,
        'result': outcome.result,
      },
    );

    // Действие после ответа (перезапуск приложения): ack и событие уже
    // отправлены, журнал сбрасывается внутри.
    await outcome.afterAck?.call();
  }
}
