import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import '../widgets/portrait_ui.dart';

const Map<String, Map<String, String>> i18n = {
  'ru': {
    'title': 'Прогрев...',
    'subtitle': 'Идёт нагрев испарителя, пожалуйста подождите',
    'hint1': '1. Вставьте шланг в приоткрытое окно автомобиля',
    'hint2': '2. Включите внутреннюю рециркуляцию воздуха',
    'hint3': '3. Закройте все двери и ожидайте снаружи',
    'hint4':
        '4. После завершения обработки насос ещё {s} сек будет распылять — не трогайте шланг',
    'target': 'Цель',
    'cancel': 'Отмена',
  },
  'en': {
    'title': 'Preheating...',
    'subtitle': 'Heating the evaporator, please wait',
    'hint1': '1. Insert the hose through a slightly open window',
    'hint2': '2. Turn on cabin air recirculation',
    'hint3': '3. Close all doors and wait outside',
    'hint4':
        '4. After treatment ends, the pump keeps spraying for {s} more sec — do not touch the hose',
    'target': 'Target',
    'cancel': 'Cancel',
  },
  'et': {
    'title': 'Eelsoojendus...',
    'subtitle': 'Aurusti soojenemine käib, palun oota',
    'hint1': '1. Sisesta voolik veidi avatud autoaknasse',
    'hint2': '2. Lülita sisse salongi õhu ringlus',
    'hint3': '3. Sulge kõik uksed ja oota väljas',
    'hint4':
        '4. Pärast töötluse lõppu pihustab pump veel {s} sek — ära puuduta voolikut',
    'target': 'Sihtmärk',
    'cancel': 'Tühista',
  },
};

class PreparingScreen extends StatefulWidget {
  const PreparingScreen({super.key});

  @override
  State<PreparingScreen> createState() => _PreparingScreenState();
}

class _PreparingScreenState extends State<PreparingScreen> {
  static const double _targetTemp = HeaterThresholds.preheatTargetC;
  // Аварийный потолок — сохранён из прежней (симулированной) версии этого
  // экрана. Без него реальный ТЭН, управляемый только по показаниям
  // термопары, не имеет верхнего предела на случай залипшего реле или
  // сбоя чтения.
  static const double _abortTemp = HeaterThresholds.overheatAbortC;
  static final int _maxDurationS = HeaterThresholds.preheatTimeout.inSeconds;

  // Для экрана — 0.0 до первого чтения; в записи об отказе — _lastTempC
  // (null, если термопара ни разу не прочиталась: 0.0°C там врал бы).
  double _currentTemp = 0.0;
  double? _lastTempC;
  // Время нагрева — от фактической команды на ТЭН, а не от входа на экран:
  // иначе окно проверки мощности (3 с) съедало бы таймаут прогрева.
  final Stopwatch _heatingClock = Stopwatch();
  int get _elapsedS => _heatingClock.elapsed.inSeconds;
  Timer? _timer;

  // Независимый от "верю термопаре" контроль нагрева (задача "детектор
  // отказа датчика температуры"): служебное значение обрыва (~-500°C),
  // null/ошибки чтения подряд, застывшее показание, отсутствие роста при
  // нагреве и перерасход энергии прогрева. Пороги — HeaterThresholds.
  // Раньше здесь был счётчик плохих чтений на 15 с, не ловивший
  // застывший (но "годный" на вид) датчик вообще.
  // Без счётчика (флаг energyMeterInstalled) энергетический бюджет не
  // считается — в остальном детекторы те же.
  late final HeaterSafetyMonitor _monitor;
  late final bool _meterInstalled;

  static bool _usable(double? t) => HeaterSafetyMonitor.isUsable(t);

  // Не даёт таймеру среагировать ещё раз после того, как исход уже решён
  // (успех/таймаут/перегрев/отмена) — Timer.periodic может успеть
  // сработать повторно, пока идут await внутри предыдущего тика.
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    final config = context.read<AppNotifier>().config;
    _meterInstalled = config.energyMeterInstalled;
    _monitor = HeaterSafetyMonitor(checkEnergy: _meterInstalled);
    if (!config.thermoInstalled) {
      // Без термопары греть нельзя: обратной связи нет вообще. ТЭН не
      // включается, услуга не оказана (деньги уже приняты — см. запись).
      unawaited(_noThermocouple());
      return;
    }
    unawaited(_startHeating());
  }

  // Проверка нагрева по счётчику (задача "контроль цикла по
  // электросчётчику", фаза 2, часть 1) — команда на ТЭН должна дать рост
  // мощности выше HeaterVerification.thresholdW в течение
  // HeaterVerification.window. Реле могло не сработать, ТЭН — сгореть,
  // предохранитель — быть вынут: раньше единственным признаком была
  // температура, которая в этом случае просто не растёт ещё 10 минут до
  // обычного таймаута, и клиент всё это время греет воздух за свои деньги.
  // beginCycle() снимает базовую мощность ДО команды — обязательно раньше
  // setHeater(true), иначе базовая линия окажется уже с ТЭНом.
  Future<void> _startHeating() async {
    await CycleEnergyService.beginCycle(meterInstalled: _meterInstalled);
    // Температура ДО команды — точка отсчёта для детектора "нет роста".
    final startTemp = await ModbusService.readTemperature();
    if (!mounted || _finished) return _abandonStart(heaterCommanded: false);
    if (_usable(startTemp)) {
      _lastTempC = startTemp;
      setState(() => _currentTemp = startTemp!);
    }
    CycleEnergyService.markHeaterCommandSent();
    _heatingClock.start();
    _monitor.heaterCommanded(true, tempC: _usable(startTemp) ? startTemp : null);
    await ModbusService.setHeater(true);
    // Экран закрыли, пока шла команда: ТЭН уже может быть включён, а
    // dispose отработал раньше — гасим здесь.
    if (!mounted || _finished) return _abandonStart(heaterCommanded: true);
    final verified = await CycleEnergyService.verifyHeaterPower();
    if (!mounted || _finished) return _abandonStart(heaterCommanded: true);
    if (!verified) {
      await _heaterVerificationFailed();
      return;
    }
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  // Экран ушёл (удалённый сброс, отмена, отказ) до того, как нагрев начался
  // по-настоящему: вернуть выходы и счётчик в исходное состояние. Если
  // _finished — исход уже решён другим путём (_fail/_onCancel сами гасят ТЭН
  // и закрывают цикл), здесь только страховка.
  void _abandonStart({required bool heaterCommanded}) {
    if (heaterCommanded) {
      unawaited(
        HeaterShutdownService.ensureOff(
          'preheat_abandoned',
          meterInstalled: _meterInstalled,
        ),
      );
    }
    CycleEnergyService.endCycle();
  }

  // Термопара не установлена (флаг в настройках): греть вслепую нельзя.
  Future<void> _noThermocouple() async {
    await _fail(
      errorCode: 'heater_failure',
      logCode: 'HEAT_NO_THERMOCOUPLE',
      sessionReason: 'thermo_not_installed',
      hardwareErrorCode: 'thermo_not_installed',
      serviceNotDelivered: true,
    );
  }

  // Деньги уже приняты (оплата — на payment.dart, до этого экрана), а
  // нагрева нет вообще — услуга не оказана ни на секунду. Отдельная ветка
  // от обычного _fail(): safeAllOffFirst (реле могло залипнуть),
  // serviceNotDelivered (спор с клиентом решается по записи сессии) и
  // вывод из обслуживания (задача "вывод аппарата из обслуживания"):
  // сгоревший предохранитель/пробитое реле дистанционно не лечатся, а
  // аппарат без этого продолжал бы брать деньги и выдавать ошибку.
  // Мощность и напряжение — последние ПРОЧИТАННЫЕ в окне проверки, без
  // нового обращения к шине: до подтверждённой записи на диск не должно
  // быть лишних транзакций.
  Future<void> _heaterVerificationFailed() async {
    final powerW = CycleEnergyService.lastPowerW;
    final voltageV = CycleEnergyService.lastVoltageV;
    final extra = <String, dynamic>{'power_w': ?powerW, 'voltage_v': ?voltageV};
    await _fail(
      errorCode: 'heater_failure',
      logCode: 'HEAT_NO_POWER',
      sessionReason: 'heater_failure',
      hardwareErrorCode: 'heater_no_power',
      tempC: _lastTempC,
      hardwareErrorExtra: extra,
      serviceNotDelivered: true,
      safeAllOffFirst: true,
      outOfServiceCode: OutOfServiceCode.heaterNoPower,
      outOfServiceDetails: {
        ...extra,
        'temp_c': ?_lastTempC,
        'threshold_w': HeaterVerification.thresholdW,
        'window_s': HeaterVerification.window.inSeconds,
      },
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Экран закрыт, а исход не решён (удалённая команда сброса сессии,
    // смена состояния извне): ТЭН не должен остаться включённым без
    // термостата, а счётчик — опрашиваться бесконечно. Успешный прогрев
    // тоже ставит _finished (ТЭН намеренно остаётся включённым для
    // обработки), поэтому сюда он не попадает.
    if (!_finished) {
      _finished = true;
      _abandonStart(heaterCommanded: true);
    }
    super.dispose();
  }

  Future<void> _tick() async {
    if (_finished) return;

    final temp = await ModbusService.readTemperature();
    if (!mounted || _finished) return;

    // Детекторы отказа датчика/"убегающего" нагрева — раньше любой
    // проверки по значению: застывший датчик отдаёт "годные" числа.
    var fault = _monitor.observeTemperature(temp);
    if (fault == null && _usable(temp)) {
      fault = _monitor.observeEnergy(
        energyWh: CycleEnergyService.energySinceHeaterCommandWh,
        targetReached: temp! >= _targetTemp,
      );
    }
    if (fault != null) {
      await _sensorFault(fault, temp);
      return;
    }
    // Плохое чтение, ещё не подтверждённое монитором (одиночный сбой
    // шины) — ждём следующего тика, не принимаем решений по мусору.
    if (!_usable(temp) || _monitor.lastReadBad) return;
    _lastTempC = temp;
    setState(() => _currentTemp = temp!);

    if (temp! >= _abortTemp) {
      await _fail(
        errorCode: 'overheat',
        logCode: 'HEAT_OVERHEAT',
        sessionReason: 'overheat',
        hardwareErrorCode: 'overheat',
        tempC: temp,
        safeAllOffFirst: true,
        // Деньги приняты, услуги нет; 240°C при годном датчике — ТЭН не
        // выключается / термостат не работает → вывод из обслуживания.
        serviceNotDelivered: true,
        outOfServiceCode: OutOfServiceCode.overheat,
        outOfServiceDetails: {
          'temp_c': temp,
          'threshold_c': HeaterThresholds.overheatAbortC,
          'phase': 'preheat',
        },
      );
      return;
    }

    if (temp >= _targetTemp) {
      _finished = true;
      _timer?.cancel();
      CycleEnergyService.markPreheatReached();
      if (!mounted) return;
      context.read<AppNotifier>().transition(AppState.compressorStartup);
      return;
    }

    if (_elapsedS >= _maxDurationS) {
      // Цель не достигнута за таймаут, а ни один детектор не сработал
      // (например, мощность упала — энергия копится медленнее бюджета):
      // безопасная услуга невозможна → вывод из обслуживания, как и при
      // отказе нагрева, а не возврат к ожиданию с приёмом денег.
      final powerW = CycleEnergyService.lastPowerW;
      final voltageV = CycleEnergyService.lastVoltageV;
      final extra = <String, dynamic>{
        'power_w': ?powerW,
        'voltage_v': ?voltageV,
        'energy_since_heater_on_wh': CycleEnergyService.energySinceHeaterCommandWh,
        'elapsed_s': _elapsedS,
        'timeout_s': _maxDurationS,
        'last_temp_c': temp,
        'target_c': _targetTemp,
      };
      await _fail(
        // клиенту — то же понятное "услуга не оказана, возврат", что и при
        // отказе нагрева; технические подробности (цель, секунды) не нужны
        errorCode: 'heater_failure',
        logCode: 'HEAT_TIMEOUT',
        sessionReason: 'heat_timeout',
        hardwareErrorCode: 'heat_timeout',
        tempC: temp,
        hardwareErrorExtra: extra,
        serviceNotDelivered: true,
        safeAllOffFirst: true,
        outOfServiceCode: OutOfServiceCode.heatTimeout,
        outOfServiceDetails: {...extra, 'phase': 'preheat'},
        logDetail: 'elapsed_s=$_elapsedS energy_wh='
            '${CycleEnergyService.energySinceHeaterCommandWh.toStringAsFixed(1)}',
      );
    }
  }

  // errorCode — что показать клиенту на error.dart. sessionReason —
  // значение поля reason в session_complete (Шаг 33, задача 2.3).
  // hardwareErrorCode — если задан, дополнительно шлётся hardware_error
  // (Шаг 33, задача 5.2) с фактической температурой + hardwareErrorExtra
  // (задача "контроль цикла по электросчётчику" — мощность/напряжение на
  // момент отказа нагрева). safeAllOffFirst — реле могло залипнуть, не
  // достаточно погасить только ТЭН. serviceNotDelivered — деньги приняты,
  // а услуга не оказана ни на секунду (тот же смысл, что и у
  // "отказ вместо недосчёта" на payment.dart, только для нагрева).
  Future<void> _fail({
    required String errorCode,
    required String logCode,
    required String sessionReason,
    String? hardwareErrorCode,
    double? tempC,
    Map<String, dynamic>? hardwareErrorExtra,
    bool serviceNotDelivered = false,
    bool safeAllOffFirst = false,
    String? outOfServiceCode,
    Map<String, dynamic>? outOfServiceDetails,
    String? logDetail,
  }) async {
    _finished = true;
    _timer?.cancel();
    // Захватываем сразу: вывод из обслуживания не должен зависеть от того,
    // смонтирован ли экран к концу асинхронных шагов ниже.
    final notifier = mounted ? context.read<AppNotifier>() : null;
    // Отключение выходов стартует ПЕРВЫМ и идёт параллельно с записью
    // признака на диск (см. OutOfServiceService.trip): оба окна —
    // "отказ → выходы выключены" и "отказ → запись подтверждена" —
    // должны быть минимальными.
    HeaterOffResult? heaterOff;
    final shutdown = () async {
      // Катушка + (если счётчик установлен) падение мощности.
      heaterOff = await HeaterShutdownService.confirmOff(
        meterInstalled: _meterInstalled,
      );
      if (safeAllOffFirst) await ModbusService.safeAllOff();
    }();
    if (outOfServiceCode != null && notifier != null) {
      await OutOfServiceService.trip(
        notifier,
        code: outOfServiceCode,
        details: outOfServiceDetails ?? const {},
        alongside: shutdown,
        // клиенту, чья оплата уже прошла, сначала объясняем (экран ошибки),
        // экран "не работает" появится после него по таймеру возврата
        showScreen: false,
      );
    } else {
      await shutdown;
    }
    final off = heaterOff;
    if (off != null && !off.confirmed) {
      // Выключение не подтверждено (катушка или мощность) — реле могло
      // залипнуть. Если вывод из обслуживания уже сработал по другой
      // причине (там ТЭН тоже мог остаться горящим), событие всё равно
      // уходит оператору отдельно.
      await HeaterShutdownService.reportUnconfirmed(
        'preheat_fail:$logCode',
        off,
        notifier: notifier,
        tripOutOfService: outOfServiceCode == null,
      );
    }
    await _logError(
      logCode,
      'temp=${_lastTempC?.toStringAsFixed(1) ?? 'n/a'}${logDetail != null ? ' $logDetail' : ''}',
    );
    if (hardwareErrorCode != null) {
      await CloudService.report(
        CloudEventType.hardwareError,
        data: {
          'code': hardwareErrorCode,
          'temp_c': ?tempC,
          ...?hardwareErrorExtra,
        },
      );
    }
    await SessionService.interrupt(
      sessionReason,
      serviceNotDelivered: serviceNotDelivered,
    );
    notifier?.goToError(errorCode);
  }

  // Сработал детектор отказа датчика температуры / "убегающего" нагрева
  // (HeaterSafetyMonitor). Реакция немедленная — не ждём таймаута прогрева:
  // safeAllOff(), запись о сработавшем детекторе, hardware_error
  // 'heater_sensor_fault' с подтипом, сессия помечена как неоказанная и
  // вывод аппарата из обслуживания 'temp_sensor_fault' (безопасная услуга
  // физически невозможна; одно подтверждённое срабатывание).
  Future<void> _sensorFault(HeaterFault fault, double? lastTemp) async {
    final powerW = CycleEnergyService.lastPowerW;
    final voltageV = CycleEnergyService.lastVoltageV;
    final energyWh = CycleEnergyService.energySinceHeaterCommandWh;
    final extra = <String, dynamic>{
      'subtype': fault.subtype,
      'reason': fault.reason,
      'power_w': ?powerW,
      'voltage_v': ?voltageV,
      'energy_since_heater_on_wh': energyWh,
      ...fault.details,
    };
    await _fail(
      errorCode: 'heater_sensor_fault',
      logCode: 'HEAT_SENSOR_FAULT_${fault.subtype.toUpperCase()}',
      sessionReason: 'heater_sensor_fault',
      hardwareErrorCode: 'heater_sensor_fault',
      tempC: lastTemp,
      hardwareErrorExtra: extra,
      serviceNotDelivered: true,
      safeAllOffFirst: true,
      outOfServiceCode: OutOfServiceCode.tempSensorFault,
      outOfServiceDetails: {...extra, 'phase': 'preheat'},
      // что именно сработало и на каких показаниях — в локальный журнал
      logDetail:
          'subtype=${fault.subtype} reason=${fault.reason} '
          'power_w=${powerW?.toStringAsFixed(0)} '
          'energy_wh=${energyWh.toStringAsFixed(1)} '
          'since_on_s=${fault.details['since_heater_on_s']} '
          'recent=${fault.details['recent_temps']}',
    );
  }

  Future<void> _onCancel() async {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    final notifier = context.read<AppNotifier>();
    // Подтверждённое выключение: аппарат возвращается в ожидание, и ТЭН
    // там гореть не должен; не подтвердилось — вывод из обслуживания.
    await HeaterShutdownService.ensureOff('preheat_cancel', notifier: notifier);
    CycleEnergyService.endCycle();
    await _logError(
      'HEAT_USER_CANCEL',
      'temp=${_lastTempC?.toStringAsFixed(1) ?? 'n/a'}',
    );
    // Деньги уже внесены на payment.dart и не возвращаются монетоприёмником
    // — сессия должна остаться в отчёте, а не пропасть молча (Шаг 33,
    // задача 2, уточнено отдельно от исходного текста задания).
    // Клиент сам остановил на стадии прогрева — обработка не начиналась
    // (0% услуги). Запись отличает это от отказа оборудования.
    await SessionService.interrupt(
      'cancelled_by_client',
      extra: {
        'cancelled_by': 'client',
        'stage': 'preheat',
        'treatment_done_s': 0,
        'treatment_share_pct': 0,
        'temp_c': ?_lastTempC,
      },
    );
    if (!mounted) return;
    context.read<AppNotifier>().resetSession();
  }

  // Дописывает запись в JSON-массив под ключом "error_log" в
  // SharedPreferences, не перезаписывая уже накопленные записи.
  Future<void> _logError(String code, String detail) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('error_log');
      final List<dynamic> list = raw != null
          ? jsonDecode(raw) as List<dynamic>
          : <dynamic>[];
      list.add({
        'timestamp': DateTime.now().toIso8601String(),
        'code': code,
        'detail': detail,
      });
      await prefs.setString('error_log', jsonEncode(list));
    } catch (e) {
      debugPrint('PreparingScreen._logError error: $e');
    }
  }

  double get _progress => (_currentTemp / _targetTemp).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = i18n[lang]!;

    return Scaffold(
      body: FogBackground(
        // Тёплый акцент — идёт нагрев испарителя (Задача 1.4).
        accentColor: const Color(0xFFFFAA00),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(PUi.gutter),
            child: PortraitScroll(
              // Портрет: сверху заголовок/язык и температура с прогрессом,
              // ниже подсказки для клиента, внизу отмена.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t['title']!,
                          style: const TextStyle(
                            color: Color(0xFFFFAA00),
                            fontSize: PUi.titleSp,
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
                  const SizedBox(height: 12),
                  Text(
                    t['subtitle']!,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: PUi.minBodySp,
                    ),
                  ),
                  const Spacer(),
                  Center(
                    child: Text(
                      '${_currentTemp.toStringAsFixed(0)}°C',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 128,
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
                      backgroundColor: const Color(0xFF2E2E2E),
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _progress > 0.9
                            ? Colors.redAccent
                            : const Color(0xFFFF3333),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      '${t['target']!} ${_targetTemp.toStringAsFixed(0)}°C',
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: PUi.minBodySp,
                      ),
                    ),
                  ),
                  const Spacer(),
                  _HintRow(text: t['hint1']!),
                  const SizedBox(height: 20),
                  _HintRow(text: t['hint2']!),
                  const SizedBox(height: 20),
                  _HintRow(text: t['hint3']!),
                  const SizedBox(height: 20),
                  _HintRow(
                    text: t['hint4']!.replaceAll(
                      '{s}',
                      '${notifier.config.pumpAfterHeaterS}',
                    ),
                  ),
                  const Spacer(),
                  SizedBox(
                    height: PUi.buttonH,
                    child: OutlinedButton(
                      onPressed: _onCancel,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF8899AA),
                        side: const BorderSide(
                          color: Color(0xFF8899AA),
                          width: 2,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: Text(
                        t['cancel']!,
                        style: const TextStyle(fontSize: 28),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HintRow extends StatelessWidget {
  final String text;
  const _HintRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.arrow_right, color: Color(0xFF2EC4B6), size: 36),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: PUi.minBodySp + 2,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
