import 'dart:async';
import '../models/app_state.dart';
import 'cloud_service.dart';
import 'modbus_service.dart';

// Сторож выходов (задача "сторож выходов"): в состояниях покоя
// периодически сверяет фактическое состояние выходов (FC01, Read Coils)
// с ожидаемым "всё выключено". Если что-то включено — немедленно
// выключает всё, перепроверяет и сообщает в облако, какой именно выход
// был найден включённым. Защита от самопроизвольного включения
// оборудования модулем — в частности, от ситуации, ради которой затевалась
// вся задача: после ночного отключения питания модуль сам поднимает ТЭН и
// оба силовых SSR, пока техник не перезапустит приложение вручную.
//
// Заодно, наравне со StartupService, поддерживает AppNotifier.busHealthy
// (задача "не брать деньги, если шина недоступна") — успешное чтение здесь
// так же подтверждает работоспособность шины, как и успешный запуск, а
// несколько подряд неудачных чтений сбрасывают признак обратно.
class OutputWatchdogService {
  static OutputWatchdogService? _instance;

  final AppNotifier notifier;
  Timer? _timer;
  bool _running = false;
  bool _paused = false;
  // Только восстановление связи: сторож выключен настройкой или состояние
  // не "покой", но клиент стоит на экране "шина недоступна" — признак
  // "шина исправна" после старта восстанавливает только сторож, поэтому
  // без этого режима экран не закрывался бы никогда.
  bool _recoveryOnly = false;
  int _consecutiveFailures = 0;

  OutputWatchdogService._(this.notifier);

  // Одна транзакция, и в состояниях покоя шина свободна — можно опрашивать
  // так же часто, как LevelService опрашивает уровни канистр.
  static const interval = Duration(seconds: 3);

  // Не сбрасываем busHealthy на первом же таймауте — единичная неудача на
  // загруженной шине бывает и в норме (см. docs/payment_terminal.md про
  // таймауты). Несколько подряд — уже потеря связи.
  static const _failuresUntilUnhealthy = 3;

  // Сколько первых выходов контролирует и гасит сторож (насосы 0-7,
  // компрессор 8, ТЭН 9) — ровно диапазон safeAllOff.
  static const _watchedOutputs = 10;

  // Активен только там, где выходы ЗАКОНОМЕРНО должны быть выключены —
  // не во время оплаты/подготовки/обработки/продувки (там включены
  // законно, задача 3.4) и не в сервисном меню (там техник управляет
  // выходами вручную на вкладке диагностики, задача 3.5).
  static bool _isIdleState(AppState s) {
    switch (s) {
      case AppState.selectLanguage:
      case AppState.standby:
      case AppState.selectFlavor:
      case AppState.finished:
      // Выведенный из обслуживания аппарат стоит с выключенными выходами
      // — если модуль что-то поднял сам, сторож это поймает и погасит.
      case AppState.outOfService:
        return true;
      default:
        return false;
    }
  }

  static void start(AppNotifier notifier) {
    stop();
    final service = OutputWatchdogService._(notifier);
    _instance = service;
    service._begin();
  }

  static void stop() {
    _instance?._end();
    _instance = null;
  }

  // Выключен настройкой (задача "починить обмен по шине", 4.1) — по
  // умолчанию false: чтение катушек мешало диагностике поломки обмена, а
  // поведение этой функции на конкретном модуле не до конца подтверждено.
  // Диагностический режим, включается явно в сервисном меню, когда обмен
  // по шине подтверждённо исправен.
  bool _isEnabledByConfig() => notifier.config.outputWatchdogEnabled;

  bool _waitingForBus() =>
      notifier.state == AppState.error && notifier.errorCode == 'bus_unavailable';

  void _begin() {
    notifier.addListener(_onNotifierChanged);
    _recompute();
    _reschedule();
  }

  void _recompute() {
    final full = _isEnabledByConfig() && _isIdleState(notifier.state);
    _recoveryOnly = !full && _waitingForBus();
    _paused = !full && !_recoveryOnly;
  }

  void _end() {
    notifier.removeListener(_onNotifierChanged);
    _timer?.cancel();
    _timer = null;
  }

  void _onNotifierChanged() {
    final wasPaused = _paused;
    final wasRecovery = _recoveryOnly;
    _recompute();
    if (wasPaused != _paused || wasRecovery != _recoveryOnly) _reschedule();
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
      final coils = await ModbusService.readCoils();
      if (coils == null) {
        _consecutiveFailures++;
        if (_consecutiveFailures == _failuresUntilUnhealthy) {
          notifier.setBusHealthy(false);
        }
        return;
      }
      _consecutiveFailures = 0;
      notifier.setBusHealthy(true);

      if (_recoveryOnly) return; // связь жива — это всё, что здесь нужно

      // Сторожу важны только выходы, которые гасит safeAllOff (0..9:
      // насосы, компрессор, ТЭН). Индикаторные светодиоды (10, 11)
      // safeAllOff не трогает намеренно: горящий красный после аварийного
      // перезапуска сыпал бы событием каждые 3 с, а погасить его сторож
      // всё равно не может.
      final onIndex = coils.take(_watchedOutputs).toList().indexWhere((v) => v);
      if (onIndex == -1) return; // всё выключено, как и ожидалось

      // Что-то включено там, где по логике аппарата включённого быть не
      // может — немедленно выключаем всё и перепроверяем (задача 3.2).
      await ModbusService.safeAllOff();
      final recheck = await ModbusService.readCoils();
      final confirmedOff = recheck != null &&
          !recheck.take(_watchedOutputs).any((v) => v);
      await CloudService.report(
        CloudEventType.hardwareError,
        data: {
          'code': 'unexpected_output_on',
          'channel': onIndex,
          'state': notifier.state.name,
          'confirmed_off': confirmedOff,
        },
      );
    } finally {
      _running = false;
    }
  }
}
