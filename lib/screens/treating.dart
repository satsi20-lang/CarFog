import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/bus_map.dart';
import '../models/out_of_service.dart';
import '../services/cloud_service.dart';
import '../services/cycle_energy_service.dart';
import '../services/heater_safety_monitor.dart';
import '../services/heater_shutdown_service.dart';
import '../services/modbus_service.dart';
import '../services/out_of_service_service.dart';
import '../services/session_service.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';

const Map<String, Map<String, String>> i18n = {
  'ru': {
    'compressor_title': 'ЗАПУСК КОМПРЕССОРА',
    'compressor_sub': 'Пожалуйста, подождите',
    'treating_title': 'ИДЁТ ОБРАБОТКА САЛОНА',
    'treating_sub': 'Распыление аромата — дождитесь окончания процедуры',
    'warning_title': 'ФИНАЛ СЕССИИ!',
    'warning_sub': 'Готовьтесь забрать шланг',
    'shutdown_title': 'ЗАВЕРШЕНИЕ ПРОЦЕДУРЫ',
    'shutdown_sub': 'Продувка системы, пожалуйста подождите',
    'flavor': 'Аромат',
    'seconds': 'с',
    'cancel': 'Отмена',
    'cancel_title': 'Остановить процедуру?',
    'cancel_body': 'Оплата не возвращается автоматически. Процедура будет прервана.',
    'cancel_yes': 'Остановить',
    'cancel_no': 'Продолжить',
  },
  'en': {
    'compressor_title': 'STARTING COMPRESSOR',
    'compressor_sub': 'Please wait',
    'treating_title': 'TREATING VEHICLE INTERIOR',
    'treating_sub': 'Fragrance is being sprayed — please wait',
    'warning_title': 'SESSION ENDING!',
    'warning_sub': 'Get ready to remove the hose',
    'shutdown_title': 'FINISHING UP',
    'shutdown_sub': 'Purging the system, please wait',
    'flavor': 'Fragrance',
    'seconds': 's',
    'cancel': 'Cancel',
    'cancel_title': 'Stop the procedure?',
    'cancel_body': 'Payment is not refunded automatically. The procedure will be interrupted.',
    'cancel_yes': 'Stop',
    'cancel_no': 'Continue',
  },
  'et': {
    'compressor_title': 'KOMPRESSORI KÄIVITAMINE',
    'compressor_sub': 'Palun oota',
    'treating_title': 'SALONGI TÖÖTLEMINE KÄIB',
    'treating_sub': 'Lõhna pihustamine käib — palun oota',
    'warning_title': 'SEANSS LÕPEB!',
    'warning_sub': 'Valmistu vooliku eemaldamiseks',
    'shutdown_title': 'LÕPETAMINE',
    'shutdown_sub': 'Süsteemi puhastamine, palun oota',
    'flavor': 'Lõhn',
    'seconds': 's',
    'cancel': 'Tühista',
    'cancel_title': 'Peata protseduur?',
    'cancel_body': 'Makset ei tagastata automaatselt. Protseduur katkestatakse.',
    'cancel_yes': 'Peata',
    'cancel_no': 'Jätka',
  },
};

// Внутренние подэтапы одного экрана
enum _Phase { compressor, treating, shutdown }

class TreatingScreen extends StatefulWidget {
  const TreatingScreen({super.key});

  @override
  State<TreatingScreen> createState() => _TreatingScreenState();
}

class _TreatingScreenState extends State<TreatingScreen>
    with SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.compressor;
  int _secondsLeft = 5; // компрессор — 5 сек
  Timer? _timer;
  bool _isBlinking = false;

  // Физическое мигание красной LED (реле DO11) на последних секундах —
  // отдельно от _blinkController, который отвечает только за анимацию фона.
  Timer? _ledBlinkTimer;
  bool _ledOn = false;

  // Термостат испарителя: поддерживает температуру гистерезисом
  // HeaterThresholds.maintainLowC..maintainHighC (bus_map.dart) на всё
  // время экрана (компрессор/обработка/продувка), пока явно не отменён —
  // см. _nextPhase() (treating→shutdown) и dispose().
  Timer? _heaterTimer;
  double _currentTemp = 0.0;
  // Известное состояние реле ТЭНа (null — ещё не решали) и время
  // последнего РЕАЛЬНОГО переключения — вместе с
  // HeaterThresholds.maintainMinToggleInterval не дают гистерезису
  // дёргать реле чаще разумного на границе коридора (задача "контроль
  // цикла по электросчётчику", правка температурного режима, п.6).
  bool? _heaterOn;
  DateTime? _lastHeaterToggleAt;
  int _heaterToggleCount = 0;

  // Детекторы отказа датчика температуры при включённом ТЭНе (задача
  // "детектор отказа датчика температуры"). В режиме обработки с жидкостью
  // работают только out_of_range и stale: температура на плато при
  // включённом ТЭНе здесь не измерялась, поэтому no_rise и energy_budget
  // (рассчитанные на сухой прогрев) отключены.
  final HeaterSafetyMonitor _monitor = HeaterSafetyMonitor(
    checkNoRise: false,
    checkEnergy: false,
  );
  bool _faulted = false;
  bool _cancelling = false;

  // Термостат вправе управлять реле только пока этот флаг поднят. Снимается
  // ПЕРВЫМ делом при конце обработки/отказе: тик, который уже ждал ответа
  // термопары, после await проверяет флаг и не включает ТЭН обратно
  // поверх явного выключения (гонка в конце обработки).
  bool _thermostatActive = true;

  late AnimationController _blinkController;
  late Animation<Color?> _bgColorAnim;

  static const int _warningThreshold = 10;

  int get _treatmentDuration =>
      context.read<AppNotifier>().config.treatmentDurationS;
  int get _compressorDelay =>
      context.read<AppNotifier>().config.compressorPurgeS;
  int get _shutdownDelay => context.read<AppNotifier>().config.pumpAfterHeaterS;
  int get _flavorIndex => context.read<AppNotifier>().selectedFlavor ?? 0;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _bgColorAnim = ColorTween(
      begin: const Color(0xFF1A1A1A),
      end: const Color(0xFFFF0000),
    ).animate(_blinkController);

    // Компрессор включаем сразу — пока идёт 5-секундный отсчёт набора
    // давления на экране, реле уже физически включено.
    unawaited(ModbusService.setCompressor(true));

    _startPhase(_Phase.compressor, _compressorDelay);

    // ТЭН физически включён ещё с прогрева (preparing.dart оставляет его
    // включённым) — контроль датчика продолжается без разрыва.
    _monitor.heaterCommanded(true);

    _heaterTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_faulted) return;
      final temp = await ModbusService.readTemperature();
      if (!mounted || _faulted || !_thermostatActive) return;
      final fault = _monitor.observeTemperature(temp);
      if (fault != null) {
        await _sensorFault(fault, temp);
        return;
      }
      // Плохое чтение (null / обрыв / нереалистично) — не принимаем по нему
      // решений: -500°C как "ниже порога включения" включило бы ТЭН.
      if (!HeaterSafetyMonitor.isUsable(temp)) return;
      setState(() => _currentTemp = temp!);
      // Аварийный потолок: в прогреве он есть, в обработке раньше не было
      // совсем — при залипшем реле от перегрева защищал бы только
      // аппаратный термовыключатель.
      if (temp! >= HeaterThresholds.overheatAbortC) {
        await _overheat(temp);
        return;
      }
      await _applyHeaterHysteresis(temp);
    });
  }

  // Сработал детектор отказа датчика температуры при включённом ТЭНе во
  // время обработки: немедленно safeAllOff() (ТЭН, насосы, компрессор;
  // светодиоды он НЕ гасит — их гасит ModbusService.ledsOff()), запись о детекторе, hardware_error
  // 'heater_sensor_fault' с подтипом, вывод из обслуживания
  // 'temp_sensor_fault'. Услуга здесь оказана частично (в отличие от
  // отказа в прогреве), поэтому serviceNotDelivered НЕ ставится — о том,
  // возвращать ли деньги, решает оператор по записи сессии (reason,
  // duration_s, phase). Мощность/напряжение — последние прочитанные
  // отсчётом CycleEnergyService, без лишнего обращения к шине до записи.
  Future<void> _sensorFault(HeaterFault fault, double? lastTemp) async {
    if (_faulted) return;
    _stopCycleTimers();
    final notifier = context.read<AppNotifier>();
    // safeAllOff не трогает светодиоды (красный должен сигналить аварию на
    // исправном аппарате), но на выведенном аппарате зелёный "идёт
    // обработка" гореть не должен. Подтверждение выключения ТЭНа — внутри.
    final shutdown = _shutdownAll(notifier, 'treating_sensor_fault');
    // Доля оказанной услуги — чтобы оператор мог решить о возврате по
    // записи: сколько секунд обработки (фаза treating) прошло из
    // запланированных. До начала обработки (компрессор) — 0, после — 100.
    final plannedS = _treatmentDuration;
    final doneS = _treatmentDoneS(plannedS);
    final extra = <String, dynamic>{
      'subtype': fault.subtype,
      'reason': fault.reason,
      'treatment_planned_s': plannedS,
      'treatment_done_s': doneS,
      'treatment_share_pct': plannedS == 0 ? 0 : (doneS * 100 / plannedS).round(),
      'power_w': ?CycleEnergyService.lastPowerW,
      'voltage_v': ?CycleEnergyService.lastVoltageV,
      'phase': _phase.name,
      ...fault.details,
    };
    await OutOfServiceService.trip(
      notifier,
      code: OutOfServiceCode.tempSensorFault,
      details: extra,
      alongside: shutdown,
      showScreen: false,
    );
    await CloudService.report(
      CloudEventType.hardwareError,
      data: {'code': 'heater_sensor_fault', 'temp_c': ?lastTemp, ...extra},
    );
    // phase/subtype/доля оказанной услуги — и в записи сессии, откуда
    // оператор решает о возврате, а не только в hardware_error.
    await SessionService.interrupt(
      'heater_sensor_fault',
      extra: {
        'phase': _phase.name,
        'subtype': fault.subtype,
        'treatment_planned_s': plannedS,
        'treatment_done_s': doneS,
        'treatment_share_pct': extra['treatment_share_pct'],
      },
    );
    notifier.goToError('heater_sensor_fault');
  }

  // Клиент сам остановил процедуру кнопкой "Отмена". В запись сессии идёт
  // reason 'cancelled_by_client' и СТАДИЯ (stage): компрессор / обработка —
  // вместе с долей оказанной услуги по времени. По этой записи оператор
  // отличает "клиент сам остановил" (возврат не положен или частичный) от
  // отказа оборудования (service_delivered:false, hardware_error) и решает
  // о возврате средств. Остановка — как при отказе: всё выключается, ТЭН с
  // подтверждением. Деньги не возвращаются автоматически.
  Future<void> _onCancel() async {
    if (_faulted || _cancelling || _phase == _Phase.shutdown) return;
    final lang = context.read<AppNotifier>().lang;
    final t = i18n[lang]!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t['cancel_title']!),
        content: Text(t['cancel_body']!),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t['cancel_no']!),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t['cancel_yes']!),
          ),
        ],
      ),
    );
    // Пока шёл диалог, цикл мог закончиться или сломаться сам.
    if (confirmed != true || !mounted || _faulted || _cancelling) return;
    if (_phase == _Phase.shutdown) return;
    _cancelling = true;
    _faulted = true; // термостат и тики больше ничего не делают
    _stopCycleTimers();
    final notifier = context.read<AppNotifier>();
    final plannedS = _treatmentDuration;
    final doneS = _treatmentDoneS(plannedS);
    final stage = _phase == _Phase.compressor ? 'compressor' : 'treating';
    await _shutdownAll(notifier, 'treating_client_cancel');
    await SessionService.interrupt(
      'cancelled_by_client',
      extra: {
        'cancelled_by': 'client',
        'stage': stage,
        'treatment_planned_s': plannedS,
        'treatment_done_s': doneS,
        'treatment_share_pct':
            plannedS == 0 ? 0 : (doneS * 100 / plannedS).round(),
      },
    );
    notifier.resetSession();
  }

  // Перегрев в обработке: тот же порог, что и в прогреве. Обычная ошибка
  // с возвратом к ожиданию (не вывод из обслуживания): перегрев сам по себе
  // не доказывает отказ аппарата, а если ТЭН не выключается — это поймает
  // ensureOff и выведет аппарат.
  Future<void> _overheat(double temp) async {
    if (_faulted) return;
    _faulted = true;
    _stopCycleTimers();
    final notifier = context.read<AppNotifier>();
    await _shutdownAll(notifier, 'treating_overheat');
    final plannedS = _treatmentDuration;
    final doneS = _treatmentDoneS(plannedS);
    final extra = <String, dynamic>{
      'phase': _phase.name,
      'treatment_planned_s': plannedS,
      'treatment_done_s': doneS,
      'treatment_share_pct': plannedS == 0 ? 0 : (doneS * 100 / plannedS).round(),
    };
    await CloudService.report(
      CloudEventType.hardwareError,
      data: {'code': 'overheat', 'temp_c': temp, ...extra},
    );
    await SessionService.interrupt('overheat', extra: extra);
    notifier.goToError('overheat');
  }

  // Снять управление реле и остановить таймеры экрана.
  void _stopCycleTimers() {
    _thermostatActive = false;
    _timer?.cancel();
    _heaterTimer?.cancel();
    _stopRedBlink();
    _blinkController.stop();
  }

  // Выключить всё и убедиться, что ТЭН выключен.
  Future<void> _shutdownAll(AppNotifier notifier, String where) async {
    await ModbusService.safeAllOff();
    await ModbusService.ledsOff();
    await HeaterShutdownService.ensureOff(where, notifier: notifier);
  }

  int _treatmentDoneS(int plannedS) => switch (_phase) {
    _Phase.compressor => 0,
    _Phase.treating => (plannedS - _secondsLeft).clamp(0, plannedS),
    _Phase.shutdown => plannedS,
  };

  // Решает, нужно ли переключить реле ТЭНа, и переключает не чаще
  // HeaterThresholds.maintainMinToggleInterval от последнего РЕАЛЬНОГО
  // переключения — внутри коридора (temp между low и high) решения нет,
  // держим текущее состояние реле как есть.
  Future<void> _applyHeaterHysteresis(double temp) async {
    bool? wantOn;
    if (temp < HeaterThresholds.maintainLowC) {
      wantOn = true;
    } else if (temp > HeaterThresholds.maintainHighC) {
      wantOn = false;
    }
    if (wantOn == null || wantOn == _heaterOn) return;

    // Ниже жёсткого пола пауза не действует вообще — температура падает,
    // греть нужно немедленно, а не ждать (решение оператора 28.09.2026).
    final now = DateTime.now();
    if (temp >= HeaterThresholds.maintainHardFloorC) {
      final last = _lastHeaterToggleAt;
      if (last != null && now.difference(last) < HeaterThresholds.maintainMinToggleInterval) {
        return;
      }
    }

    // Флаг проверяется синхронно прямо перед командой: между проверкой и
    // отправкой нет await, поэтому конец обработки (флаг снят до его
    // собственного выключения ТЭНа) не может оказаться "между".
    if (!_thermostatActive || _faulted) return;
    final notifier = context.read<AppNotifier>();
    final ok = await ModbusService.setHeater(wantOn);
    // Состояние реле "запоминается" только после подтверждённой записи:
    // раньше неудача выключения оставляла _heaterOn=false, и следующий тик
    // считал, что делать нечего, пока ТЭН продолжал греть.
    if (ok) {
      _lastHeaterToggleAt = now;
      _heaterOn = wantOn;
      _heaterToggleCount++;
      _monitor.heaterCommanded(wantOn, tempC: temp);
    } else if (!wantOn) {
      // Не удалось выключить — не ждать следующего тика: форсированное
      // выключение с подтверждением (при провале — вывод из обслуживания).
      if (await HeaterShutdownService.ensureOff('treating_thermostat', notifier: notifier)) {
        _heaterOn = false;
        _monitor.heaterCommanded(false, tempC: temp);
      } else {
        _faulted = true;
        _stopCycleTimers();
        await _shutdownAll(notifier, 'treating_thermostat');
        await SessionService.interrupt('heater_off_unconfirmed');
        notifier.goToError('heater_failure');
      }
    }
  }

  void _startPhase(_Phase phase, int seconds) {
    _timer?.cancel();
    setState(() {
      _phase = phase;
      _secondsLeft = seconds;
      _isBlinking = false;
    });
    _blinkController.stop();
    _blinkController.reset();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft--);

      // Мигание в конце TREATING
      if (_phase == _Phase.treating &&
          _secondsLeft <= _warningThreshold &&
          !_isBlinking) {
        setState(() => _isBlinking = true);
        _blinkController.repeat(reverse: true);
        _startRedBlink();
      }

      if (_secondsLeft <= 0) {
        _timer?.cancel();
        _nextPhase();
      }
    });
  }

  // Физическое мигание красной LED каждые 500мс, пока идёт предупреждение
  // об окончании сессии. Независимо от UI-анимации фона.
  void _startRedBlink() {
    _ledBlinkTimer?.cancel();
    _ledOn = false;
    _ledBlinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _ledOn = !_ledOn;
      unawaited(ModbusService.setLedRed(_ledOn));
    });
  }

  void _stopRedBlink() {
    _ledBlinkTimer?.cancel();
    _ledBlinkTimer = null;
  }

  Future<void> _nextPhase() async {
    switch (_phase) {
      case _Phase.compressor:
        // Компрессор прогрелся — запускаем насос выбранного аромата и
        // зелёную LED, затем переходим к отсчёту обработки.
        await ModbusService.setPump(_flavorIndex, true);
        await ModbusService.setLedGreen(true);
        if (!mounted) return;
        _startPhase(_Phase.treating, _treatmentDuration);
        break;
      case _Phase.treating:
        // Обработка завершена — насос+ТЭН+LED выкл, компрессор продувает.
        // Термостат отменяем ДО setHeater(false) — иначе он через 3 сек
        // снова включит ТЭН поверх этого явного выключения.
        _thermostatActive = false;
        _heaterTimer?.cancel();
        debugPrint(
          'TreatingScreen: реле ТЭНа переключилось $_heaterToggleCount раз за цикл',
        );
        _stopRedBlink();
        _blinkController.stop();
        _blinkController.reset();
        await ModbusService.setPump(_flavorIndex, false);
        // Выключение ТЭНа подтверждается чтением катушки; не подтвердилось
        // — аппарат выводится из обслуживания (HeaterShutdownService).
        if (!mounted || _faulted) return;
        final notifier = context.read<AppNotifier>();
        final heaterOff = await HeaterShutdownService.ensureOff(
          'treating_end',
          notifier: notifier,
        );
        if (!heaterOff) {
          _faulted = true;
          _timer?.cancel();
          await ModbusService.safeAllOff();
          await ModbusService.ledsOff();
          await SessionService.interrupt('heater_off_unconfirmed');
          notifier.goToError('heater_failure');
          return;
        }
        await ModbusService.setLedGreen(false);
        await ModbusService.setLedRed(false);
        if (!mounted) return;
        _startPhase(_Phase.shutdown, _shutdownDelay);
        break;
      case _Phase.shutdown:
        // Продувка завершена — компрессор выкл, финал. Сессия (Шаг 33,
        // задача 2.2) завершается именно здесь, а не в момент окончания
        // treating — клиент ещё физически держит шланг, длительность
        // сессии должна включать и продувку.
        await ModbusService.setCompressor(false);
        await SessionService.complete();
        if (!mounted) return;
        context.read<AppNotifier>().transition(AppState.finished);
        break;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _heaterTimer?.cancel();
    _stopRedBlink();
    _blinkController.dispose();
    // Аварийная гарантия: что бы ни случилось с экраном (уход, ошибка,
    // hot reload) — все выходы гарантированно выключаются.
    _thermostatActive = false;
    unawaited(() async {
      await ModbusService.safeAllOff();
      await HeaterShutdownService.ensureOff('treating_dispose');
    }());
    super.dispose();
  }

  double get _progress {
    int total;
    switch (_phase) {
      case _Phase.compressor:
        total = _compressorDelay;
        break;
      case _Phase.treating:
        total = _treatmentDuration;
        break;
      case _Phase.shutdown:
        total = _shutdownDelay;
        break;
    }
    final elapsed = total - _secondsLeft;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = i18n[lang]!;
    final flavorIndex = notifier.selectedFlavor ?? 0;
    final flavorName = notifier.config.flavorNames[lang]![flavorIndex];

    String title;
    String subtitle;
    Color titleColor;

    switch (_phase) {
      case _Phase.compressor:
        title = t['compressor_title']!;
        subtitle = t['compressor_sub']!;
        titleColor = const Color(0xFFFFAA00);
        break;
      case _Phase.treating:
        title = _isBlinking ? t['warning_title']! : t['treating_title']!;
        subtitle = _isBlinking ? t['warning_sub']! : t['treating_sub']!;
        titleColor = _isBlinking ? Colors.redAccent : const Color(0xFFFF3333);
        break;
      case _Phase.shutdown:
        title = t['shutdown_title']!;
        subtitle = t['shutdown_sub']!;
        titleColor = const Color(0xFFFFAA00);
        break;
    }

    return AnimatedBuilder(
      animation: _bgColorAnim,
      builder: (context, child) {
        return Scaffold(
          backgroundColor: _isBlinking
              ? _bgColorAnim.value
              : const Color(0xFF1A1A1A),
          // paintBase: false — заливку уже даёт Scaffold.backgroundColor
          // выше (в том числе мигание последних секунд), дублировать её
          // не нужно. intensity гасится в ноль на время мигания — та
          // анимация главнее и не должна перекрываться дымкой (Задача
          // 3.3).
          body: FogBackground(
            paintBase: false,
            intensity: _isBlinking ? 0 : 0.14,
            child: SafeArea(
              child: Row(
                children: [
                  // Левая колонка: заголовок, аромат, индикатор фаз
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    color: titleColor,
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                              LangSwitcher(
                                current: lang,
                                onChanged: notifier.setLanguage,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            subtitle,
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '${t['flavor']!}: $flavorName',
                            style: const TextStyle(
                              color: Color(0xFF2EC4B6),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          // Индикатор текущей фазы
                          Row(
                            children: [
                              _PhaseIndicator(
                                active: _phase == _Phase.compressor,
                                done: _phase != _Phase.compressor,
                                label: '1',
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Container(
                                  height: 2,
                                  color: Colors.white24,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _PhaseIndicator(
                                active: _phase == _Phase.treating,
                                done: _phase == _Phase.shutdown,
                                label: '2',
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Container(
                                  height: 2,
                                  color: Colors.white24,
                                ),
                              ),
                              const SizedBox(width: 8),
                              _PhaseIndicator(
                                active: _phase == _Phase.shutdown,
                                done: false,
                                label: '3',
                              ),
                            ],
                          ),
                          if (_phase != _Phase.shutdown) ...[
                            const SizedBox(height: 20),
                            SizedBox(
                              width: double.infinity,
                              height: 48,
                              child: OutlinedButton(
                                onPressed: _onCancel,
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: Colors.white70,
                                  side: const BorderSide(color: Colors.white38),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                                child: Text(t['cancel']!),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  Container(width: 1, color: const Color(0xFF2E2E2E)),

                  // Правая колонка: большой таймер + прогресс-бар
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '$_secondsLeft ${t['seconds']!}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 72,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: LinearProgressIndicator(
                              value: _progress,
                              minHeight: 24,
                              backgroundColor: const Color(0xFF2E2E2E),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                _phase == _Phase.treating
                                    ? const Color(0xFFFF3333)
                                    : const Color(0xFF2EC4B6),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PhaseIndicator extends StatelessWidget {
  final bool active;
  final bool done;
  final String label;

  const _PhaseIndicator({
    required this.active,
    required this.done,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    Color color;
    if (done) {
      color = const Color(0xFF2EC4B6);
    } else if (active) {
      color = const Color(0xFFFF3333);
    } else {
      color = Colors.white24;
    }

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Center(
        child: Text(
          done ? '✓' : label,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      ),
    );
  }
}
