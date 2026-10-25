import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/app_state.dart';
import '../models/out_of_service.dart';
import 'app_log_service.dart';
import 'card_payment_service.dart';
import 'heater_safety_monitor.dart';
import 'heater_trial_service.dart';
import 'modbus_service.dart';
import 'module_probe.dart';
import 'out_of_service_service.dart';
import 'session_service.dart';

// Фоновый контроль термопары в простое (1.11.4). Раньше о неисправном датчике
// аппарат узнавал, только когда подходил клиент (pre-flight или цикл). Теперь
// в простое киоска раз в минуту — проба как в pre-flight: до 3 свежих чтений
// подряд с паузой 300 мс, годное = HeaterSafetyMonitor.isUsable.
//
//   * Простой: заставка / выбор языка / выбор запаха, нет сессии оплаты и
//     цикла, нет пробного цикла, шина считается исправной, аппарат не
//     выведен. Сервисное меню, оплата, прогрев, обработка, продувка — не
//     простой (там шиной пользуются экраны сами).
//   * Термопара не установлена — проб нет. Тип терминала не важен: монетный
//     аппарат защищается так же.
//   * 3 неудачные пробы подряд (около 3 минут без годного показания) — вывод
//     из обслуживания temp_sensor_fault, subtype idle_no_reading, тем же
//     механизмом, что при отказе в цикле: запись на диск, блок оплаты,
//     снятие — пробный цикл на месте. Одна неудачная проба ничего не
//     меняет; любое годное показание (проба или чтение в другом месте)
//     сбрасывает счёт.
//   * Не больше одной пробы в минуту. Детекторы цикла и pre-flight не
//     меняются.
class ThermoIdleWatchService {
  ThermoIdleWatchService._(this.notifier);

  static ThermoIdleWatchService? _instance;
  static ThermoIdleWatchService? get instance => _instance;

  static const interval = Duration(seconds: 60);
  static const failedProbesToTrip = 3;
  static const subtype = 'idle_no_reading';

  // Пауза между чтениями пробы — подменяется в тестах (без реального ожидания).
  @visibleForTesting
  static Future<void> Function(Duration) pause = Future<void>.delayed;

  final AppNotifier notifier;
  Timer? _timer;
  bool _running = false;
  DateTime? _lastProbeAt;
  int _failedProbes = 0;
  DateTime? _lastFailedAt;

  int get failedProbes => _failedProbes;

  static void start(AppNotifier notifier) {
    stop();
    final s = ThermoIdleWatchService._(notifier);
    _instance = s;
    s._timer = Timer.periodic(interval, (_) => unawaited(s.tick()));
  }

  static void stop() {
    _instance?._timer?.cancel();
    _instance = null;
  }

  @visibleForTesting
  static ThermoIdleWatchService forTest(AppNotifier notifier) =>
      ThermoIdleWatchService._(notifier);

  static bool _isIdleState(AppState s) =>
      s == AppState.standby || s == AppState.selectLanguage || s == AppState.selectFlavor;

  // Можно ли сейчас трогать шину пробой.
  bool get canProbe =>
      notifier.config.thermoInstalled &&
      _isIdleState(notifier.state) &&
      notifier.busHealthy &&
      !notifier.isOutOfService &&
      SessionService.currentSessionId == null &&
      !CardPaymentService.approvedPending &&
      !HeaterTrialService.running;

  // Одна проба; вызывается таймером раз в interval. true — проба была.
  Future<bool> tick() async {
    if (_running || !canProbe) return false;
    final now = ModbusService.clock();
    final last = _lastProbeAt;
    // Не чаще раза в интервал (с небольшим допуском на дрожание таймера).
    if (last != null && now.difference(last) < interval - const Duration(seconds: 1)) {
      return false;
    }
    _running = true;
    _lastProbeAt = now;
    try {
      final p = await probeModule<double>(
        ModbusService.readTemperatureDetailed,
        HeaterSafetyMonitor.isUsable,
        attempts: CardPaymentService.preflightAttempts,
        retryPause: CardPaymentService.preflightRetryPause,
        pause: pause,
        keepValue: true,
      );
      if (p.ok) {
        _failedProbes = 0;
        _lastFailedAt = null;
        return true;
      }
      // Годное показание где-то ещё после прошлой неудачной пробы — счёт заново.
      final good = ModbusService.lastUsableTemperature;
      final prevFail = _lastFailedAt;
      if (good != null && prevFail != null && good.at.isAfter(prevFail)) _failedProbes = 0;
      _failedProbes++;
      _lastFailedAt = ModbusService.clock();
      AppLog.log('Thermo', 'проба термопары в простое не прошла ($_failedProbes из $failedProbesToTrip): ${p.readings}');
      if (_failedProbes >= failedProbesToTrip && canProbe) {
        await _trip(p);
      }
      return true;
    } finally {
      _running = false;
    }
  }

  Future<void> _trip(ProbeResult p) async {
    final last = ModbusService.lastUsableTemperature;
    final details = <String, dynamic>{
      'subtype': subtype,
      'reason': 'no_usable_reading',
      'failed_probes': _failedProbes,
      'probe_interval_s': interval.inSeconds,
      'phase': 'idle',
      'state': notifier.state.name,
      ...p.details(lastOkAt: last?.at),
      'last_usable_c': last?.c,
    };
    AppLog.log('Thermo', 'нет годного показания термопары $_failedProbes пробы подряд — вывод из обслуживания');
    _failedProbes = 0;
    _lastFailedAt = null;
    await OutOfServiceService.trip(
      notifier,
      code: OutOfServiceCode.tempSensorFault,
      details: details,
      // Fail-closed, как при отказе в цикле: выходы и так выключены в простое.
      alongside: ModbusService.safeAllOff(),
    );
  }
}
