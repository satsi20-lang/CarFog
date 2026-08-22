import 'dart:async';
import '../models/app_state.dart';
import 'cloud_service.dart';
import 'modbus_service.dart';

// Периодически опрашивает уровни канистр (DI 0-7) и обновляет
// AppNotifier.levels — от этого зависят и вкладка "Диагностика" в
// сервисном меню, и отключение недоступных ароматов на экране выбора.
// Раньше AppNotifier.updateLevels() существовал, но его никто не вызывал —
// levels навсегда оставались дефолтными (все true), поэтому ни показания
// в сервисном меню, ни фильтрация ароматов не отражали реальное железо.
class LevelService {
  static LevelService? _instance;

  final AppNotifier notifier;
  Timer? _timer;
  bool _running = false;
  bool _paused = false;

  // Последнее известное состояние каждой канистры (по реально распаянным
  // каналам, kFlavorCount) — null, пока не было ни одного успешного
  // чтения. Нужно, чтобы событие low_liquid/liquid_restored уходило один
  // раз именно в момент ПЕРЕХОДА, а не на каждом опросе (Шаг 33, задача
  // 3.1/3.2), и чтобы самое первое чтение после запуска не считалось
  // переходом — иначе при каждом включении аппарата в облако летела бы
  // пачка ложных событий по уже известному на старте состоянию (задача 3.3).
  final List<bool?> _lastKnown = List<bool?>.filled(kFlavorCount, null);

  LevelService._(this.notifier);

  static const Duration interval = Duration(seconds: 3);

  // Во время оплаты/обработки шина занята монетоприёмником и термостатом —
  // опрос уровней в это время не нужен и только создавал бы лишнюю
  // конкуренцию за общий лок (см. docs/coin_acceptor.md).
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

  static void start(AppNotifier notifier) {
    stop();
    final service = LevelService._(notifier);
    _instance = service;
    service._begin();
  }

  static void stop() {
    _instance?._end();
    _instance = null;
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
    if (_paused) return;
    _timer = Timer.periodic(interval, (_) => _tick());
    unawaited(_tick());
  }

  Future<void> _tick() async {
    if (_running) return;
    _running = true;
    try {
      final levels = await ModbusService.readLevels();
      // null = ошибка чтения (шина занята/таймаут) — не затираем последнее
      // известное состояние ложным "все канистры пусты".
      if (levels != null) {
        notifier.updateLevels(levels);
        await _reportTransitions(levels);
      }
    } finally {
      _running = false;
    }
  }

  // Каналы физически не распаяны за пределами kFlavorCount — их
  // "состояние" ничего не значит и события по ним не отправляются
  // (Шаг 33, задача 3.4).
  Future<void> _reportTransitions(List<bool> levels) async {
    for (var i = 0; i < kFlavorCount; i++) {
      final hasLiquid = levels[i];
      final was = _lastKnown[i];
      _lastKnown[i] = hasLiquid;

      if (was == null) continue; // первое чтение — исходное состояние
      if (was == hasLiquid) continue; // без изменений

      final flavor = notifier.config.flavorNames['ru']![i];
      final data = {'channel': i, 'flavor': flavor};
      await CloudService.report(
        hasLiquid ? CloudEventType.liquidRestored : CloudEventType.lowLiquid,
        data: data,
      );
    }
  }
}
