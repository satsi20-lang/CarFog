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
//
// С задачи "терминал" этот же тик заодно фоново следит за платёжным
// терминалом вне экрана оплаты (задача 5) — читает те же 16 входов одной
// транзакцией (задача 1), лишней нагрузки на шину это не добавляет.
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

  // То же самое, но для платёжного терминала вне экрана оплаты — своя,
  // отдельная от payment.dart/вкладки "Датчики" база: те опрашивают канал
  // куда чаще и для других целей (реальный приём оплаты, калибровка), не
  // нужно путать их историю с фоновой проверкой "не приложили ли карту
  // не вовремя".
  bool? _terminalLastAmbient;
  DateTime? _terminalLastAmbientEventAt;

  LevelService._(this.notifier);

  static const Duration interval = Duration(seconds: 3);

  // Уровни канистр по-прежнему не обновляются во время оплаты/обработки —
  // клиенту это не показывается, а частое чтение конкурирует за шину с
  // монетоприёмником/термостатом (см. docs/coin_acceptor.md). Терминал
  // (ниже) от этого списка не зависит — его как раз обязательно проверять
  // и во время обработки, см. _isFullyPausedState.
  static bool _isLevelBusyState(AppState s) {
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

  // Сам опрос (тик целиком) ставится на паузу гораздо реже — терминал
  // нужно слушать и во время обработки: клиент может по ошибке приложить
  // карту, пока идёт treating (Шаг "терминал", задача 5). Паузим только
  // на экране оплаты (там канал терминала уже слушает свой отдельный,
  // более быстрый опрос — см. payment.dart) и в сервисном меню (там
  // срабатывание почти наверняка техник тестирует терминал на вкладке
  // "Датчики", а не клиент случайно приложил карту).
  static bool _isFullyPausedState(AppState s) {
    return s == AppState.payment ||
        s == AppState.serviceMenu ||
        s == AppState.servicePinEntry;
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
    _paused = _isFullyPausedState(notifier.state);
    _reschedule();
  }

  void _end() {
    notifier.removeListener(_onNotifierChanged);
    _timer?.cancel();
    _timer = null;
  }

  void _onNotifierChanged() {
    final paused = _isFullyPausedState(notifier.state);
    if (paused != _paused) {
      // Выход из паузы (обычно — уход с экрана оплаты). Терминал держит
      // линию высокой ещё какое-то время после уже принятой там оплаты
      // (измерено — около секунды), а этот тик мог всё это время стоять
      // и не знать о том фронте. Без сброса первый же возобновлённый тик
      // увидел бы "было низко (устарело) → сейчас высоко" и отрапортовал
      // бы уже учтённую оплату как unexpected_payment. Сброс в null
      // переиспользует существующую логику калибровки первого чтения
      // (см. _checkTerminalAmbient) — тик просто заново узнаёт текущее
      // состояние, не считая его переходом.
      if (_paused && !paused) {
        _terminalLastAmbient = null;
      }
      _paused = paused;
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
      final all = await ModbusService.readAllInputs();
      // null = ошибка чтения (шина занята/таймаут) — не затираем последнее
      // известное состояние ложным "все канистры пусты".
      if (all == null) return;

      if (!_isLevelBusyState(notifier.state) && all.length >= 8) {
        final levels = all.sublist(0, 8);
        notifier.updateLevels(levels);
        await _reportLevelTransitions(levels);
      }

      await _checkTerminalAmbient(all);
    } finally {
      _running = false;
    }
  }

  // Каналы физически не распаяны за пределами kFlavorCount — их
  // "состояние" ничего не значит и события по ним не отправляются
  // (Шаг 33, задача 3.4).
  Future<void> _reportLevelTransitions(List<bool> levels) async {
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

  // Терминал сработал вне экрана оплаты (и вне сервисного меню) — клиент
  // почти наверняка не ожидал этого сам: деньги спишутся, услуга не будет
  // оказана. При 3-секундном интервале опроса это грубее, чем точный
  // опрос на экране оплаты, и совсем короткий импульс теоретически может
  // проскочить между тиками — так и было принято в задаче 5 ("благодаря
  // задаче 1 это не стоит дополнительных обращений к шине", то есть без
  // отдельного быстрого опроса специально под этот случай). Реагируем
  // только на появление сигнала (не на его снятие) — направление фронта
  // для тревоги неважно, важен сам факт срабатывания.
  Future<void> _checkTerminalAmbient(List<bool> all) async {
    final cfg = notifier.config;
    if (!cfg.paymentTerminalEnabled) return;
    final idx = cfg.paymentTerminalChannel;
    if (idx < 0 || idx >= all.length) return;

    final value = all[idx];
    final last = _terminalLastAmbient;
    _terminalLastAmbient = value;
    if (last == null || last == value || !value) return;

    final now = DateTime.now();
    final since = _terminalLastAmbientEventAt;
    if (since != null &&
        now.difference(since) <
            Duration(milliseconds: cfg.paymentTerminalGuardMs)) {
      return;
    }
    _terminalLastAmbientEventAt = now;

    await CloudService.report(
      CloudEventType.unexpectedPayment,
      data: {'state': notifier.state.name},
    );
  }
}
