import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/app_state.dart';
import '../models/bus_map.dart';
import '../models/out_of_service.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'modbus_service.dart';
import 'out_of_service_service.dart';

// Снимок сторожа шины с нативной стороны (BusPortRegistry.health).
class BusHealth {
  // Этот движок — владелец порта (у второго движка в том же процессе false).
  final bool owner;
  final bool open;
  // Ошибки подряд и монотонный счётчик успешных транзакций.
  final int failures;
  final int successes;
  final int reopens;
  // События переоткрытия с прошлого опроса: at (мс), ok, attempt, result, port.
  final List<Map<String, dynamic>> events;

  const BusHealth({
    required this.owner,
    required this.open,
    required this.failures,
    required this.successes,
    this.reopens = 0,
    this.events = const [],
  });

  static BusHealth? fromMap(Map<dynamic, dynamic>? m) {
    if (m == null) return null;
    final events = m['events'];
    return BusHealth(
      owner: m['owner'] == true,
      open: m['open'] == true,
      failures: (m['failures'] as num?)?.toInt() ?? 0,
      successes: (m['successes'] as num?)?.toInt() ?? 0,
      reopens: (m['reopens'] as num?)?.toInt() ?? 0,
      events: events is List
          ? [
              for (final e in events)
                if (e is Map) e.map((k, v) => MapEntry(k.toString(), v)),
            ]
          : const [],
    );
  }
}

// Сторож шины, сторона Dart (задача "устойчивость шины", 1.10.3).
// Переоткрытие порта после серии ошибок делает нативная сторона
// (BusPortRegistry/BusWatchdog) — здесь только то, что требует приложения:
//  * события переоткрытия → журнал и облако (hardware_error, code
//    'bus_reopened');
//  * шина не отвечает дольше [downAfter] → событие 'bus_down' и экран "не
//    работает" через существующий механизм вывода из обслуживания —
//    временной причиной OutOfServiceCode.busDown (без записи на диск);
//  * ответы вернулись → 'bus_recovered', признак снимается сам.
//
// Выходы здесь не трогаются: safeAllOff и сторож выходов работают как
// раньше, этот сторож ничего не включает и не выключает.
class BusWatchdogService {
  static BusWatchdogService? _instance;

  static const interval = Duration(seconds: 3);
  // Не измерено — значение из задания (60 с), подлежит пересмотру.
  static const downAfter = Duration(seconds: 60);

  final AppNotifier notifier;
  final Future<BusHealth?> Function() _poll;
  final DateTime Function() _now;
  final Future<void> Function(Map<String, dynamic> data) _report;

  Timer? _timer;
  bool _running = false;
  int? _lastSuccesses;
  DateTime? _badSince;
  bool _downReported = false;

  @visibleForTesting
  BusWatchdogService(
    this.notifier, {
    Future<BusHealth?> Function()? poll,
    DateTime Function()? now,
    Future<void> Function(Map<String, dynamic> data)? report,
  }) : _poll = poll ?? _defaultPoll,
       _now = now ?? DateTime.now,
       _report = report ?? _defaultReport;

  static Future<BusHealth?> _defaultPoll() async =>
      BusHealth.fromMap(await ModbusService.busHealth());

  static Future<void> _defaultReport(Map<String, dynamic> data) =>
      CloudService.report(CloudEventType.hardwareError, data: data);

  bool get isDown => _downReported;

  // Для пакета диагностики.
  static Map<String, dynamic> status() {
    final s = _instance;
    if (s == null) return {'running': false};
    return {
      'running': true,
      'down': s._downReported,
      'bad_since': s._badSince?.toIso8601String(),
    };
  }

  static void start(AppNotifier notifier) {
    stop();
    final s = BusWatchdogService(notifier);
    _instance = s;
    s._timer = Timer.periodic(interval, (_) => s.tick());
  }

  static void stop() {
    _instance?._timer?.cancel();
    _instance = null;
  }

  // Экран "не работает" сразу — только там, где клиент ничего не начал.
  // Во время оплаты/прогрева/обработки признак всё равно блокирует любые
  // переходы, и экран появится по их обычному завершению (как при отказе
  // с showScreen=false).
  static bool _canShowNow(AppNotifier n) {
    switch (n.state) {
      case AppState.selectLanguage:
      case AppState.standby:
      case AppState.selectFlavor:
      case AppState.finished:
        return true;
      default:
        return false;
    }
  }

  Future<void> tick() async {
    if (_running) return;
    _running = true;
    try {
      final h = await _poll();
      // Канал не ответил, либо порт у другого движка этого же процесса
      // (этот движок — уходящий): судить не о чем.
      if (h == null || !h.owner) return;

      for (final e in h.events) {
        AppLog.log(
          'Bus',
          'сторож шины: переоткрытие порта ${e['port']} '
              '(попытка ${e['attempt']}): ${e['ok'] == true ? 'удалось' : 'не удалось, ${e['result']}'}',
        );
        await _report({
          'code': 'bus_reopened',
          'port': e['port'] ?? BusParams.port,
          'ok': e['ok'] == true,
          'attempt': e['attempt'],
          'result': e['result'],
        });
      }

      final previous = _lastSuccesses;
      _lastSuccesses = h.successes;
      final progressed = previous != null && h.successes > previous;
      final firstLookOk =
          previous == null && h.successes > 0 && h.failures == 0;
      final now = _now();

      if (h.open && (progressed || firstLookOk)) {
        await _onGood(now);
      } else if (!h.open || h.failures > 0) {
        await _onBad(now, h);
      }
      // Иначе обмена с прошлого опроса не было — состояние не меняется.
    } finally {
      _running = false;
    }
  }

  Future<void> _onGood(DateTime now) async {
    final since = _badSince;
    _badSince = null;
    if (!_downReported) return;
    _downReported = false;
    final downS = since == null ? null : now.difference(since).inSeconds;
    AppLog.log('Bus', 'шина снова отвечает (не работала ${downS ?? '?'} с)');
    final cleared = OutOfServiceService.leaveTransient(
      notifier,
      code: OutOfServiceCode.busDown,
    );
    await _report({
      'code': 'bus_recovered',
      'port': BusParams.port,
      'down_s': ?downS,
      'out_of_service_cleared': cleared,
    });
  }

  Future<void> _onBad(DateTime now, BusHealth h) async {
    final since = _badSince ??= now;
    if (_downReported) return;
    final downFor = now.difference(since);
    if (downFor < downAfter) return;
    _downReported = true;
    AppLog.log(
      'Bus',
      'шина не отвечает ${downFor.inSeconds} с (порт открыт: ${h.open}, '
          'ошибок подряд: ${h.failures}, переоткрытий: ${h.reopens}) — '
          'аппарат временно не работает',
    );
    final showNow = _canShowNow(notifier);
    final entered = OutOfServiceService.enterTransient(
      notifier,
      code: OutOfServiceCode.busDown,
      details: {'port': BusParams.port},
      showScreen: showNow,
    );
    await _report({
      'code': 'bus_down',
      'port': BusParams.port,
      'down_s': downFor.inSeconds,
      'open': h.open,
      'failures': h.failures,
      'reopens': h.reopens,
      'state': notifier.state.name,
      // Признак выставлен (false — уже стоял постоянный вывод) и показан ли
      // экран сразу (иначе — по завершении текущего цикла).
      'out_of_service': entered,
      'screen_shown': entered && showNow,
    });
  }
}
