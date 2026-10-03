import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/app_state.dart';
import '../models/bus_map.dart';
import '../models/out_of_service.dart';
import 'cloud_service.dart';
import 'cycle_energy_service.dart';
import 'heater_safety_monitor.dart';
import 'heater_shutdown_service.dart';
import 'modbus_service.dart';
import 'out_of_service_service.dart';

// Пробный цикл БЕЗ оплаты (задача "вывод аппарата из обслуживания",
// требования 15-16): короткий прогрев из сервисного меню с теми же
// проверками, что и в боевом цикле — мощность ТЭНа выше порога за окно
// проверки нагрева и подъём температуры за окно детектора "нет роста" (он
// же ловит застывший датчик). Блокировку сам НЕ снимает и клиентам оплату
// не открывает: проход лишь разрешает кнопку "Снять блокировку" на 15
// минут (OutOfServiceService.trialPassedRecently); снимает техник вручную
// с подтверждением. Провал — блокировка остаётся, запись о причине
// обновляется.
class TrialResult {
  final bool passed;
  // true — цикл не состоялся (горячий испаритель, уже идёт другой пробный
  // цикл, прерван уходом с вкладки) — это НЕ провал, ничего не пишется.
  final bool skipped;
  // 'heater_no_power' | 'temp_sensor_fault' | 'too_hot' | 'busy' |
  // 'cancelled' | 'overheat'
  final String? code;
  final Map<String, dynamic> details;

  const TrialResult.pass(this.details)
    : passed = true,
      skipped = false,
      code = null;
  const TrialResult.fail(this.code, this.details)
    : passed = false,
      skipped = false;
  const TrialResult.skipped(this.code, this.details)
    : passed = false,
      skipped = true;
}

class HeaterTrialService {
  HeaterTrialService._();

  static bool _running = false;
  static bool _cancelRequested = false;
  static bool get running => _running;

  // Уход с вкладки "Диагностика" посреди пробного цикла: её dispose()
  // принудительно гасит выходы, и цикл вышел бы "провалом" на исправном
  // аппарате — поэтому вместо этого цикл помечается прерванным.
  static void cancel() {
    if (_running) _cancelRequested = true;
  }

  // Самый низкий уровень: сам прогрев и вердикт, без записи в состояние.
  static Future<TrialResult> _execute(AppNotifier notifier) async {
    if (_running) return const TrialResult.skipped('busy', {});
    if (notifier.state != AppState.serviceMenu) {
      // Пробный цикл — только из сервисного меню; во время клиентского
      // цикла греть "ещё раз" нельзя.
      return const TrialResult.skipped('busy', {});
    }
    final config = notifier.config;
    if (!config.thermoInstalled) {
      // Без термопары пробный цикл ничего не докажет — это не провал.
      return const TrialResult.skipped('no_thermocouple', {});
    }
    // Блокировка по таймауту прогрева (heat_timeout) снимается только
    // если пробный прогрев ДОСТИГ ЦЕЛИ за тот же срок, что и боевой, а не
    // просто показал рост на 3°C — иначе тот же отказ прошёл бы незамеченным.
    // Для overheat то же + ТЭН обязан выключиться ПОДТВЕРЖДЁННО, с падением
    // мощности (HeaterShutdownService.confirmOff): причина — именно
    // невыключающийся ТЭН.
    final oosCode = notifier.outOfService?.code;
    final requireTarget =
        oosCode == OutOfServiceCode.heatTimeout ||
        oosCode == OutOfServiceCode.overheat;
    final requireOffByPower = oosCode == OutOfServiceCode.overheat;
    _running = true;
    _cancelRequested = false;
    try {
      final temp0 = await ModbusService.readTemperature();
      final startUsable = HeaterSafetyMonitor.isUsable(temp0);
      if (startUsable && temp0! > HeaterThresholds.trialMaxStartTempC) {
        // Горячий испаритель: подождать остывания, это не отказ.
        return TrialResult.skipped('too_hot', {'temp_c': temp0});
      }

      await CycleEnergyService.beginCycle(
        meterInstalled: config.energyMeterInstalled,
      );
      final monitor = HeaterSafetyMonitor(checkEnergy: false);
      CycleEnergyService.markHeaterCommandSent();
      monitor.heaterCommanded(true, tempC: startUsable ? temp0 : null);
      await ModbusService.setHeater(true);

      final verified = await CycleEnergyService.verifyHeaterPower();
      if (_cancelRequested) return const TrialResult.skipped('cancelled', {});
      if (!verified) {
        return TrialResult.fail(OutOfServiceCode.heaterNoPower, {
          'power_w': ?CycleEnergyService.lastPowerW,
          'voltage_v': ?CycleEnergyService.lastVoltageV,
          'temp_c': ?temp0,
          'threshold_w': HeaterVerification.thresholdW,
          'window_s': HeaterVerification.window.inSeconds,
        });
      }

      final deadline = DateTime.now().add(
        requireTarget
            ? HeaterThresholds.preheatTimeout
            : HeaterThresholds.trialMaxDuration,
      );
      double? lastTemp = temp0;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(seconds: 3));
        if (_cancelRequested) return const TrialResult.skipped('cancelled', {});
        final t = await ModbusService.readTemperature();
        lastTemp = t ?? lastTemp;
        final fault = monitor.observeTemperature(t);
        if (fault != null) {
          return TrialResult.fail(OutOfServiceCode.tempSensorFault, {
            'subtype': fault.subtype,
            'reason': fault.reason,
            'power_w': ?CycleEnergyService.lastPowerW,
            'voltage_v': ?CycleEnergyService.lastVoltageV,
            ...fault.details,
          });
        }
        if (HeaterSafetyMonitor.isUsable(t) &&
            !monitor.lastReadBad &&
            t! >= HeaterThresholds.overheatAbortC) {
          // Аварийный потолок прогрева (тот же, что в preparing.dart).
          return TrialResult.fail('overheat', {'temp_c': t});
        }
        if (requireTarget) {
          if (HeaterSafetyMonitor.isUsable(t) &&
              !monitor.lastReadBad &&
              t! >= HeaterThresholds.preheatTargetC) {
            if (requireOffByPower) {
              final off = await HeaterShutdownService.confirmOff(
                meterInstalled: config.energyMeterInstalled,
              );
              if (!off.confirmed) {
                return TrialResult.fail(OutOfServiceCode.heaterOffUnconfirmed, {
                  'temp_c': t,
                  ...off.toDetails(),
                });
              }
            }
            return TrialResult.pass({
              'power_w': ?CycleEnergyService.lastPowerW,
              'voltage_v': ?CycleEnergyService.lastVoltageV,
              'start_temp_c': ?temp0,
              'end_temp_c': ?lastTemp,
              'target_reached': true,
            });
          }
          continue;
        }
        if (monitor.riseConfirmed) {
          return TrialResult.pass({
            'power_w': ?CycleEnergyService.lastPowerW,
            'voltage_v': ?CycleEnergyService.lastVoltageV,
            'start_temp_c': ?temp0,
            'end_temp_c': ?lastTemp,
          });
        }
      }
      if (requireTarget) {
        return TrialResult.fail(
          oosCode == OutOfServiceCode.overheat
              ? OutOfServiceCode.overheat
              : OutOfServiceCode.heatTimeout,
          {
            'timeout_s': HeaterThresholds.preheatTimeout.inSeconds,
            'target_c': HeaterThresholds.preheatTargetC,
            'start_temp_c': ?temp0,
            'last_temp_c': ?lastTemp,
            'energy_since_heater_on_wh':
                CycleEnergyService.energySinceHeaterCommandWh,
          },
        );
      }
      // Время вышло, а подъёма нет, хотя детектор не успел сработать
      // (задержки опроса) — это тоже "нет роста".
      return TrialResult.fail(OutOfServiceCode.tempSensorFault, {
        'subtype': 'no_rise',
        'reason': 'no_temperature_rise',
        'start_temp_c': ?temp0,
        'last_temp_c': ?lastTemp,
      });
    } finally {
      // Всегда: ТЭН и всё остальное выключены, учёт цикла остановлен.
      try {
        await ModbusService.safeAllOff();
        // Выключение ТЭНа подтверждается чтением катушки; не подтвердилось
        // — вывод из обслуживания (реле могло залипнуть).
        await HeaterShutdownService.ensureOff('trial_cycle', notifier: notifier);
      } catch (e) {
        debugPrint('HeaterTrialService: не удалось выключить выходы: $e');
      }
      CycleEnergyService.endCycle();
      _running = false;
    }
  }

  // Пробный цикл с записью итога: проход открывает кнопку "Снять
  // блокировку"; провал — обновляет запись о причине и оставляет
  // блокировку (а на исправном ещё аппарате — выводит его: проверка
  // нагрева не пройдена, безопасная услуга невозможна).
  static Future<TrialResult> runAndRecord(AppNotifier notifier) async {
    final wasOutOfService = notifier.isOutOfService;
    final result = await _execute(notifier);
    if (result.skipped) return result;

    await CloudService.report(
      CloudEventType.outOfServiceTrial,
      data: {
        'passed': result.passed,
        'was_out_of_service': wasOutOfService,
        'code': ?result.code,
        ...result.details,
      },
    );

    if (result.passed) {
      if (wasOutOfService) OutOfServiceService.markTrialPassed();
      return result;
    }

    if (wasOutOfService) {
      await OutOfServiceService.recordTrialFailure(
        notifier,
        code: switch (result.code) {
          OutOfServiceCode.heaterNoPower => OutOfServiceCode.heaterNoPower,
          OutOfServiceCode.heatTimeout => OutOfServiceCode.heatTimeout,
          OutOfServiceCode.overheat => OutOfServiceCode.overheat,
          OutOfServiceCode.heaterOffUnconfirmed =>
            OutOfServiceCode.heaterOffUnconfirmed,
          _ => OutOfServiceCode.tempSensorFault,
        },
        details: {...result.details, 'source': 'trial_cycle'},
      );
    } else {
      await OutOfServiceService.trip(
        notifier,
        code: switch (result.code) {
          OutOfServiceCode.heaterNoPower => OutOfServiceCode.heaterNoPower,
          OutOfServiceCode.heatTimeout => OutOfServiceCode.heatTimeout,
          OutOfServiceCode.overheat => OutOfServiceCode.overheat,
          OutOfServiceCode.heaterOffUnconfirmed =>
            OutOfServiceCode.heaterOffUnconfirmed,
          _ => OutOfServiceCode.tempSensorFault,
        },
        details: {...result.details, 'source': 'trial_cycle'},
        // мы в сервисном меню — экран "не работает" появится при выходе
        showScreen: false,
      );
    }
    return result;
  }
}
