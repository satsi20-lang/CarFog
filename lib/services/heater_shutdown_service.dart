import '../models/app_state.dart';
import '../models/bus_map.dart';
import '../models/out_of_service.dart';
import 'cloud_service.dart';
import 'cycle_summary_service.dart';
import 'modbus_service.dart';
import 'out_of_service_service.dart';

// Итог проверки выключения ТЭНа.
class HeaterOffResult {
  final bool confirmed;
  // 'coil_and_power'            — катушка выключена И мощность упала;
  // 'coil_only_power_skipped'   — счётчик не установлен, только катушка;
  // 'coil_only_power_high'      — катушка выключена, но мощность НЕ упала
  //                               (залипшее реле) — НЕ подтверждено;
  // 'coil_only_power_unreadable'— катушка выключена, счётчик не прочитался
  //                               — НЕ подтверждено (fail-closed);
  // 'coil_unconfirmed'          — катушку выключить/подтвердить не удалось.
  final String confirmedBy;
  // 'ok' | 'skipped' | 'high' | 'unreadable' | 'not_checked'
  final String powerCheck;
  final double? powerW;

  const HeaterOffResult({
    required this.confirmed,
    required this.confirmedBy,
    required this.powerCheck,
    this.powerW,
  });

  Map<String, dynamic> toDetails() => {
    'confirmed_by': confirmedBy,
    'power_check': powerCheck,
    'power_w': ?powerW,
    if (powerCheck == 'high' || powerCheck == 'ok')
      'power_threshold_w': HeaterThresholds.heaterOffPowerMaxW,
  };
}

// Выключение ТЭНа с подтверждением. Единая точка для всех мест, где цикл
// обрывается или заканчивается. Подтверждение двойное: (1) катушка модуля
// выключена (ModbusService.forceHeaterOff) и (2) если счётчик установлен —
// мощность упала ниже HeaterThresholds.heaterOffPowerMaxW за окно
// heaterOffPowerWindow. Катушка показывает то, что думает модуль, а не то,
// что делает ТЭН: залипшее твердотельное реле при выключенной катушке
// проходило бы одну только проверку по катушке.
//
// Не подтвердилось — аппарат выводится из обслуживания с кодом
// heaterOffUnconfirmed (реле может быть залипшим, безопасно греть нельзя) и
// уходит hardware_error с подробностями (confirmed_by / power_check).
class HeaterShutdownService {
  HeaterShutdownService._();

  // Проверка без побочных эффектов (облако/состояние) — для тестов и для
  // мест, где решение принимает вызывающий код (_fail прогрева, пробный
  // цикл). forceOff / readPowerW подменяются в тестах.
  static Future<HeaterOffResult> confirmOff({
    required bool meterInstalled,
    Future<bool> Function()? forceOff,
    Future<double?> Function()? readPowerW,
    Duration? window,
    Duration? poll,
  }) async {
    final coilOk = await (forceOff ?? ModbusService.forceHeaterOff)();
    // Сводка цикла: катушка ТЭНа выключена (только запись).
    if (coilOk) CycleSummary.heaterCommanded(false);
    if (!coilOk) {
      return const HeaterOffResult(
        confirmed: false,
        confirmedBy: 'coil_unconfirmed',
        powerCheck: 'not_checked',
      );
    }
    if (!meterInstalled) {
      return const HeaterOffResult(
        confirmed: true,
        confirmedBy: 'coil_only_power_skipped',
        powerCheck: 'skipped',
      );
    }

    final read = readPowerW ?? _readPowerW;
    final win = window ?? HeaterThresholds.heaterOffPowerWindow;
    final step = poll ?? HeaterThresholds.heaterOffPowerPoll;
    final started = DateTime.now();
    double? last;
    while (true) {
      final w = await read();
      if (w != null) {
        last = w;
        if (w < HeaterThresholds.heaterOffPowerMaxW) {
          return HeaterOffResult(
            confirmed: true,
            confirmedBy: 'coil_and_power',
            powerCheck: 'ok',
            powerW: w,
          );
        }
      }
      if (DateTime.now().difference(started) >= win) break;
      await Future.delayed(step);
    }
    // Окно истекло. Ни одного отсчёта — счётчик не отвечает (fail-closed:
    // подтвердить нечем); отсчёты были, но мощность высокая — ТЭН греет.
    if (last == null) {
      return const HeaterOffResult(
        confirmed: false,
        confirmedBy: 'coil_only_power_unreadable',
        powerCheck: 'unreadable',
      );
    }
    return HeaterOffResult(
      confirmed: false,
      confirmedBy: 'coil_only_power_high',
      powerCheck: 'high',
      powerW: last,
    );
  }

  static Future<double?> _readPowerW() async {
    final e = await ModbusService.readEnergy();
    final kw = e?['power'];
    return kw == null ? null : kw * 1000;
  }

  // where — откуда вызвано (для журнала). notifier == null — вызов из
  // dispose экрана без доступа к состоянию: тогда только событие в облако.
  // meterInstalled — если не задан, берётся из настроек notifier'а, а при
  // отсутствии и его — проверка по счётчику не выполняется (skipped).
  // Возвращает true, если выключение подтверждено.
  static Future<bool> ensureOff(
    String where, {
    AppNotifier? notifier,
    bool showScreen = false,
    bool? meterInstalled,
  }) async {
    final result = await confirmOff(
      meterInstalled:
          meterInstalled ?? notifier?.config.energyMeterInstalled ?? false,
    );
    if (result.confirmed) return true;
    await reportUnconfirmed(where, result, notifier: notifier, showScreen: showScreen);
    return false;
  }

  // Событие + вывод из обслуживания по уже полученному результату.
  static Future<void> reportUnconfirmed(
    String where,
    HeaterOffResult result, {
    AppNotifier? notifier,
    bool showScreen = false,
    bool tripOutOfService = true,
  }) async {
    final details = {'where': where, ...result.toDetails()};
    await CloudService.report(
      CloudEventType.hardwareError,
      data: {'code': 'heater_off_unconfirmed', ...details},
    );
    if (tripOutOfService && notifier != null) {
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterOffUnconfirmed,
        details: details,
        showScreen: showScreen,
      );
    }
  }
}
