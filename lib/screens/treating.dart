import 'dart:async';
import 'package:flutter/material.dart';
import '../brand/brand_colors.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../models/bus_map.dart';
import '../models/out_of_service.dart';
import '../services/card_payment_service.dart';
import '../services/cloud_service.dart';
import '../services/cycle_energy_service.dart';
import '../services/cycle_summary_service.dart';
import '../services/heater_safety_monitor.dart';
import '../services/heater_shutdown_service.dart';
import '../services/i18n_service.dart';
import '../services/modbus_service.dart';
import '../services/out_of_service_service.dart';
import '../services/session_service.dart';
import '../widgets/cancel_confirm_dialog.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

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
  final CancelConfirmDialog _cancelDialog = CancelConfirmDialog();
  // Счётчик энергии установлен — нужен подтверждению выключения ТЭНа по
  // мощности (HeaterShutdownService), в том числе из dispose, где
  // context уже недоступен.
  late final bool _meterInstalled;

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
    _meterInstalled = context.read<AppNotifier>().config.energyMeterInstalled;
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
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
      if (!HeaterSafetyMonitor.isUsable(temp) || _monitor.lastReadBad) return;
      CycleSummary.recordTemp(temp);
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
      'treatment_share_pct': plannedS == 0
          ? 0
          : (doneS * 100 / plannedS).round(),
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
  // Оплата картой (1.11.1, ТЗ раздел 15): после прогрева возврата нет —
  // окно «Деньги не возвращаются», платёж закрывается как оказанная услуга
  // (13 02) ещё до остановки выходов.
  Future<void> _onCancel() async {
    if (_faulted || _cancelling || _phase == _Phase.shutdown) return;
    if (_cancelDialog.isOpen) return;
    String stageNow() =>
        _phase == _Phase.compressor ? 'compressor' : 'treating';
    final card = CardPaymentService.quoteClientCancel(stageNow());
    // Язык берётся при показе каждой строки: переключение языка во время
    // окна не закрывает его.
    String t(String key) =>
        I18n.tr(context.read<AppNotifier>().lang, 'treating.$key');
    final noRefund = card != null && !card.refund;
    if (card == null || noRefund) {
      final confirmed = await _cancelDialog.ask(
        context,
        title: t(noRefund ? 'no_refund_title' : 'cancel_title'),
        body: t(noRefund ? 'no_refund_body' : 'cancel_body'),
        no: t('cancel_no'),
        yes: t('cancel_yes'),
      );
      // Пока шёл диалог, цикл мог закончиться или сломаться сам.
      if (!confirmed || !mounted || _faulted || _cancelling) return;
    }
    if (_phase == _Phase.shutdown) return;
    _cancelling = true;
    _faulted = true; // термостат и тики больше ничего не делают
    _stopCycleTimers();
    final notifier = context.read<AppNotifier>();
    final plannedS = _treatmentDuration;
    final doneS = _treatmentDoneS(plannedS);
    // Стадия — на момент остановки (за время окна компрессор мог смениться
    // обработкой); возврата после прогрева нет ни в одной из них.
    final stage = stageNow();
    if (card != null) {
      unawaited(
        CardPaymentService.clientCancel(
          card.stage == stage
              ? card
              : CardPaymentService.quoteClientCancel(stage) ?? card,
        ),
      );
    }
    await _shutdownAll(notifier, 'treating_client_cancel');
    await SessionService.interrupt(
      'cancelled_by_client',
      extra: {
        'cancelled_by': 'client',
        'stage': stage,
        'treatment_planned_s': plannedS,
        'treatment_done_s': doneS,
        'treatment_share_pct': plannedS == 0
            ? 0
            : (doneS * 100 / plannedS).round(),
      },
    );
    notifier.resetSession();
  }

  // Перегрев в обработке: тот же порог, что и в прогреве. В обработке
  // гистерезис выключает ТЭН при 190°C, поэтому достижение 240°C при
  // ИСПРАВНОМ датчике (показание годное, детекторы не сработали) означает,
  // что ТЭН не выключился (залипшее реле) или термостат не работает: это
  // вывод из обслуживания (код overheat), а не обычная ошибка с возвратом
  // к ожиданию. Выключение подтверждается по катушке и мощности (_shutdownAll).
  Future<void> _overheat(double temp) async {
    if (_faulted) return;
    _faulted = true;
    _stopCycleTimers();
    final notifier = context.read<AppNotifier>();
    final shutdown = _shutdownAll(notifier, 'treating_overheat');
    final plannedS = _treatmentDuration;
    final doneS = _treatmentDoneS(plannedS);
    final extra = <String, dynamic>{
      'phase': _phase.name,
      'treatment_planned_s': plannedS,
      'treatment_done_s': doneS,
      'treatment_share_pct': plannedS == 0
          ? 0
          : (doneS * 100 / plannedS).round(),
    };
    await OutOfServiceService.trip(
      notifier,
      code: OutOfServiceCode.overheat,
      details: {
        'temp_c': temp,
        'threshold_c': HeaterThresholds.overheatAbortC,
        ...extra,
      },
      alongside: shutdown,
      showScreen: false,
    );
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
      if (last != null &&
          now.difference(last) < HeaterThresholds.maintainMinToggleInterval) {
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
      CycleSummary.heaterCommanded(wantOn);
      _lastHeaterToggleAt = now;
      _heaterOn = wantOn;
      _heaterToggleCount++;
      _monitor.heaterCommanded(wantOn, tempC: temp);
    } else if (!wantOn) {
      // Не удалось выключить — не ждать следующего тика: форсированное
      // выключение с подтверждением (при провале — вывод из обслуживания).
      if (await HeaterShutdownService.ensureOff(
        'treating_thermostat',
        notifier: notifier,
      )) {
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
    CycleSummary.enterPhase(switch (phase) {
      _Phase.compressor => 'compressor_startup',
      _Phase.treating => 'treating',
      _Phase.shutdown => 'purge',
    });
    setState(() {
      _phase = phase;
      _secondsLeft = seconds;
      _isBlinking = false;
    });
    _blinkController.stop();
    _blinkController.reset();

    // Этап нулевой длительности (продувка/насос = 0) пропускается сразу: без
    // секундного таймера, который ушёл бы в минус, и без деления на 0 в
    // прогрессе.
    if (seconds <= 0) {
      _timer = null;
      Future.microtask(() {
        if (mounted && !_faulted) _nextPhase();
      });
      return;
    }

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

  // Фон мигания зависит от бренда (begin = background), а Theme.of в initState
  // читать нельзя — строим анимацию здесь (вызывается до первого build).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bgColorAnim = ColorTween(
      begin: context.brand.background,
      end: const Color(0xFFFF0000),
    ).animate(_blinkController);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _heaterTimer?.cancel();
    _cancelDialog.dismiss();
    _stopRedBlink();
    _blinkController.dispose();
    // Аварийная гарантия: что бы ни случилось с экраном (уход, ошибка,
    // hot reload) — все выходы гарантированно выключаются.
    _thermostatActive = false;
    unawaited(() async {
      await ModbusService.safeAllOff();
      await HeaterShutdownService.ensureOff(
        'treating_dispose',
        meterInstalled: _meterInstalled,
      );
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
    if (total <= 0) return 1.0;
    final elapsed = total - _secondsLeft;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    String t(String key, [Map<String, Object?> params = const {}]) =>
        I18n.tr(lang, 'treating.$key', params: params);
    final flavorIndex = notifier.selectedFlavor ?? 0;
    final flavorName = notifier.config.flavorNameFor(lang, flavorIndex);

    String title;
    String subtitle;
    Color titleColor;

    switch (_phase) {
      case _Phase.compressor:
        title = t('compressor_title');
        subtitle = t('compressor_sub');
        titleColor = const Color(0xFFFFAA00);
        break;
      case _Phase.treating:
        title = _isBlinking ? t('warning_title') : t('treating_title');
        subtitle = _isBlinking ? t('warning_sub') : t('treating_sub');
        titleColor = _isBlinking ? Colors.redAccent : const Color(0xFFFF3333);
        break;
      case _Phase.shutdown:
        title = t('shutdown_title');
        subtitle = t('shutdown_sub');
        titleColor = const Color(0xFFFFAA00);
        break;
    }

    if (PUi.landscape) {
      return _buildLandscape(
        notifier,
        t,
        title,
        subtitle,
        titleColor,
        flavorName,
      );
    }

    return AnimatedBuilder(
      animation: _bgColorAnim,
      builder: (context, child) {
        return Scaffold(
          backgroundColor: _isBlinking
              ? _bgColorAnim.value
              : context.brand.background,
          // paintBase: false — заливку уже даёт Scaffold.backgroundColor
          // выше (в том числе мигание последних секунд), дублировать её
          // не нужно. intensity гасится в ноль на время мигания — та
          // анимация главнее и не должна перекрываться дымкой (Задача
          // 3.3).
          body: FogBackground(
            paintBase: false,
            intensity: _isBlinking ? 0 : 0.14,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(PUi.gutter),
                child: PortraitScroll(
                  // Портрет: сверху заголовок/язык и аромат, в середине
                  // крупный таймер с прогрессом, ниже индикатор фаз и отмена.
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: TextStyle(
                                color: titleColor,
                                fontSize: PUi.titleSp,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          LangSwitcher(
                            current: lang,
                            langs: notifier.displayLangs,
                            onChanged: notifier.setLanguage,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: context.brand.textPrimaryA(0x99),
                          fontSize: PUi.minBodySp,
                        ),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        t('flavor', {'flavor': flavorName}),
                        style: TextStyle(
                          color: context.brand.primary,
                          fontSize: PUi.bodySp + 4,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Center(
                        child: Text(
                          t('seconds', {'seconds': _secondsLeft}),
                          style: TextStyle(
                            color: context.brand.textPrimary,
                            fontSize: 112,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: LinearProgressIndicator(
                          value: _progress,
                          minHeight: 40,
                          backgroundColor: context.brand.surface,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _phase == _Phase.treating
                                ? const Color(0xFFFF3333)
                                : context.brand.primary,
                          ),
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
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              height: 3,
                              color: context.brand.textPrimaryA(0x3D),
                            ),
                          ),
                          const SizedBox(width: 12),
                          _PhaseIndicator(
                            active: _phase == _Phase.treating,
                            done: _phase == _Phase.shutdown,
                            label: '2',
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Container(
                              height: 3,
                              color: context.brand.textPrimaryA(0x3D),
                            ),
                          ),
                          const SizedBox(width: 12),
                          _PhaseIndicator(
                            active: _phase == _Phase.shutdown,
                            done: false,
                            label: '3',
                          ),
                        ],
                      ),
                      if (_phase != _Phase.shutdown) ...[
                        const SizedBox(height: 28),
                        SizedBox(
                          height: PUi.buttonH,
                          child: OutlinedButton(
                            onPressed: _onCancel,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: context.brand.textPrimaryA(0xB3),
                              side: BorderSide(
                                color: context.brand.textPrimaryA(0x62),
                                width: 2,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            child: Text(
                              t('cancel'),
                              style: const TextStyle(fontSize: 28),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // Альбом 853x533 dp (IXP101M1): слева крупный таймер и прогресс, справа
  // аромат, фазы и отмена. Мигание последних секунд — как в портрете.
  Widget _buildLandscape(
    AppNotifier notifier,
    String Function(String, [Map<String, Object?>]) t,
    String title,
    String subtitle,
    Color titleColor,
    String flavorName,
  ) {
    final m = PUi.m;
    return AnimatedBuilder(
      animation: _bgColorAnim,
      builder: (context, child) => Scaffold(
        backgroundColor: _isBlinking
            ? _bgColorAnim.value
            : context.brand.background,
        body: FogBackground(
          paintBase: false,
          intensity: _isBlinking ? 0 : 0.14,
          child: SafeArea(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                m.gutter,
                12,
                m.gutter,
                m.gutter - 4,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LandscapeHeader(
                    title: title,
                    titleColor: titleColor,
                    subtitle: subtitle,
                    trailing: LangSwitcher(
                      current: notifier.lang,
                      langs: notifier.displayLangs,
                      onChanged: notifier.setLanguage,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          flex: 6,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Center(
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    t('seconds', {'seconds': _secondsLeft}),
                                    style: TextStyle(
                                      color: context.brand.textPrimary,
                                      fontSize: 96,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: LinearProgressIndicator(
                                  value: _progress,
                                  minHeight: 28,
                                  backgroundColor: context.brand.surface,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    _phase == _Phase.treating
                                        ? const Color(0xFFFF3333)
                                        : context.brand.primary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: m.gutter + 8),
                        Expanded(
                          flex: 5,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                t('flavor', {'flavor': flavorName}),
                                textAlign: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: context.brand.primary,
                                  fontSize: m.bodySp + 4,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 24),
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
                                      height: 3,
                                      color: context.brand.textPrimaryA(0x3D),
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
                                      height: 3,
                                      color: context.brand.textPrimaryA(0x3D),
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
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_phase != _Phase.shutdown) ...[
                    const SizedBox(height: 8),
                    LandscapeCancelButton(
                      text: t('cancel'),
                      onPressed: _onCancel,
                    ),
                  ] else
                    SizedBox(height: 8 + m.buttonH),
                ],
              ),
            ),
          ),
        ),
      ),
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
      color = context.brand.primary;
    } else if (active) {
      color = const Color(0xFFFF3333);
    } else {
      color = context.brand.textPrimaryA(0x3D);
    }

    final size = PUi.landscape ? 52.0 : 64.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Center(
        child: Text(
          done ? '✓' : label,
          style: TextStyle(
            color: context.brand.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 28,
          ),
        ),
      ),
    );
  }
}
