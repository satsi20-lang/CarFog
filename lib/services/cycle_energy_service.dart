import 'dart:async';
import 'package:flutter/foundation.dart';
import 'modbus_service.dart';
import '../models/bus_map.dart';

// Ведёт пять из шести чисел цикла обработки (задача "контроль цикла по
// электросчётчику", фаза 2, часть 2) — шестое, energy_wh, уже считает
// SessionService отдельной парой чтений 0x4000 до/после и сюда не
// дублируется. Заодно отвечает за проверку нагрева по счётчику (часть 1):
// verifyHeaterPower() и обычная секундная выборка пишут в один и тот же
// накопитель пиковой мощности, так что "поймать пик" во время проверки не
// нужно отдельно — эти пять секунд уже вошли в общий цикл.
//
// Жизненный цикл: beginCycle() — один раз в preparing.dart, ДО команды на
// ТЭН (иначе базовая мощность оказалась бы уже с ТЭНом); сама команда
// отмечается markHeaterCommandSent(). endCycle()
// — один раз в SessionService._finish(), не важно, чем цикл кончился
// (успех/таймаут/перегрев/отмена/сбой нагрева) — так calling-код в
// preparing.dart/treating.dart не должен помнить о финализации отдельно.
// Повторный beginCycle() без endCycle() перезатирает предыдущий трекер —
// такого в реальном потоке экранов не бывает (один цикл — одна сессия).
class CycleEnergyService {
  CycleEnergyService._();

  static Timer? _timer;
  // Счётчик энергии не установлен (флаг в настройках) — опрос и проверка
  // мощности не выполняются: иначе каждая проверка проваливалась бы и
  // первый же платный цикл выводил аппарат из обслуживания, а шина весь
  // цикл была бы забита заведомо неудачными запросами.
  static bool _meterInstalled = true;
  static double? _baselinePowerW;
  static double _peakPowerW = 0;
  static double _voltageSum = 0;
  static int _voltageSamples = 0;

  static DateTime? _heaterCommandAt;
  static int? _timeToFullPowerMs;

  static bool _aboveThreshold = false;
  static DateTime? _aboveSince;
  static Duration _activeHeatingTotal = Duration.zero;

  // Энергия, накопленная с момента команды на ТЭН — интеграл мощности по
  // отсчётам счётчика (трапеция), а не разница регистра 0x4000: тот
  // отдаёт шаг 0,01 кВт·ч = 10 Вт·ч, для бюджета прогрева 45 Вт·ч это
  // грубее допустимого. Нужна детектору "убегающего" нагрева
  // (HeaterSafetyMonitor.observeEnergy).
  static bool _integrating = false;
  static DateTime? _lastSampleAt;
  static double _lastPowerW = 0;
  static double _energySinceCommandWh = 0;
  static double? _preheatEnergyWh;
  static int? _preheatSeconds;

  static double get energySinceHeaterCommandWh => _energySinceCommandWh;

  // Последние ПРОЧИТАННЫЕ мощность (Вт) и напряжение (В) — для записи об
  // отказе без дополнительного обращения к шине: между отказом и
  // подтверждённой записью на диск не должно быть лишних транзакций
  // (питание может пропасть именно в этот момент). null — ни одного
  // успешного отсчёта ещё не было.
  static double? _lastReadPowerW;
  static double? _lastReadVoltageV;
  static double? get lastPowerW => _lastReadPowerW;
  static double? get lastVoltageV => _lastReadVoltageV;

  // Раз в секунду — "этого хватает для пика и энергии" (задача, часть 2).
  // НЕ используется во время окна оплаты (там опрос монетоприёмника
  // каждые 80 мс, шина занята деньгами) — цикл начинается только после
  // payment.dart, so здесь по построению так и есть, отдельного флага не
  // требуется.
  static const _sampleInterval = Duration(seconds: 1);

  static Future<void> beginCycle({bool meterInstalled = true}) async {
    _timer?.cancel();
    _meterInstalled = meterInstalled;
    _peakPowerW = 0;
    _voltageSum = 0;
    _voltageSamples = 0;
    _heaterCommandAt = null;
    _timeToFullPowerMs = null;
    _aboveThreshold = false;
    _aboveSince = null;
    _activeHeatingTotal = Duration.zero;
    _integrating = false;
    _lastSampleAt = null;
    _lastPowerW = 0;
    _energySinceCommandWh = 0;
    _preheatEnergyWh = null;
    _preheatSeconds = null;
    _lastReadPowerW = null;
    _lastReadVoltageV = null;

    if (!_meterInstalled) {
      _baselinePowerW = null;
      _timer = null;
      return;
    }
    final energy = await ModbusService.readEnergy();
    _baselinePowerW = energy == null ? null : energy['power']! * 1000;

    _timer = Timer.periodic(_sampleInterval, (_) => _sample());
  }

  // Вызывается ровно в момент отправки команды на ТЭН — от этой отметки
  // считается time_to_full_power_ms.
  static void markHeaterCommandSent() {
    final now = DateTime.now();
    _heaterCommandAt = now;
    _integrating = true;
    _lastSampleAt = now;
    _lastPowerW = _baselinePowerW ?? 0;
    _energySinceCommandWh = 0;
  }

  // Цель прогрева по показаниям достигнута — фиксируем, сколько энергии и
  // секунд ушло. Идёт в session_complete (preheat_energy_wh,
  // preheat_energy_margin_pct) — по этому числу на холодном аппарате
  // пересматривается бюджет HeaterThresholds.preheatEnergyBudgetWh.
  static void markPreheatReached() {
    if (_preheatEnergyWh != null) return;
    _preheatEnergyWh = _energySinceCommandWh;
    final at = _heaterCommandAt;
    if (at != null) _preheatSeconds = DateTime.now().difference(at).inSeconds;
  }

  // Опрашивает счётчик с окном HeaterVerification.window и интервалом
  // HeaterVerification.pollInterval, пишет каждый отсчёт в тот же
  // накопитель, что и обычная секундная выборка. Возвращает true, как
  // только мощность хоть раз превысила порог — false, если окно истекло.
  // Вызывающий код (preparing.dart) сам решает, что делать при false
  // (прервать цикл, пометить услугу неоказанной).
  // Без счётчика проверить нечем — возвращает true (не проверено, а не
  // провалено); температурные детекторы продолжают работать.
  static Future<bool> verifyHeaterPower() async {
    if (!_meterInstalled) return true;
    final deadline = DateTime.now().add(HeaterVerification.window);
    while (true) {
      final crossed = await _sample();
      if (crossed) return true;
      if (DateTime.now().isAfter(deadline)) return false;
      await Future.delayed(HeaterVerification.pollInterval);
    }
  }

  // Один отсчёт: обновляет пик/среднее напряжение/время-до-полной-мощности
  // /суммарное время выше порога. Возвращает true, если ИМЕННО этот отсчёт
  // застал мощность выше порога (для verifyHeaterPower).
  static Future<bool> _sample() async {
    if (!_meterInstalled) return false;
    final energy = await ModbusService.readEnergy();
    if (energy == null) return false;
    final powerW = energy['power']! * 1000;
    final voltage = energy['voltage']!;

    _lastReadPowerW = powerW;
    _lastReadVoltageV = voltage;
    if (powerW > _peakPowerW) _peakPowerW = powerW;
    _voltageSum += voltage;
    _voltageSamples++;

    final now = DateTime.now();
    final prevAt = _lastSampleAt;
    if (_integrating && prevAt != null) {
      final dtS = now.difference(prevAt).inMilliseconds / 1000.0;
      if (dtS > 0) {
        _energySinceCommandWh += (_lastPowerW + powerW) / 2 * dtS / 3600.0;
        _lastSampleAt = now;
        _lastPowerW = powerW;
      }
    }
    final crossed = powerW >= HeaterVerification.thresholdW;
    if (crossed) {
      _timeToFullPowerMs ??= _heaterCommandAt == null
          ? null
          : now.difference(_heaterCommandAt!).inMilliseconds;
      if (!_aboveThreshold) {
        _aboveThreshold = true;
        _aboveSince = now;
      }
    } else if (_aboveThreshold) {
      _activeHeatingTotal += now.difference(_aboveSince!);
      _aboveThreshold = false;
      _aboveSince = null;
    }
    return crossed;
  }

  // Итог цикла — вызывается один раз из SessionService._finish(). null,
  // если цикл вообще не начинался (например, оплата отменена ДО
  // preparing.dart — SessionService.discard(), не _finish()).
  static Map<String, dynamic>? endCycle() {
    if (_baselinePowerW == null && _voltageSamples == 0) {
      _timer?.cancel();
      _timer = null;
      return null;
    }
    _timer?.cancel();
    _timer = null;
    // Если сессия оборвалась прямо во время нагрева — досчитать открытый
    // интервал "выше порога" по факту завершения, а не потерять его.
    if (_aboveThreshold && _aboveSince != null) {
      _activeHeatingTotal += DateTime.now().difference(_aboveSince!);
      _aboveThreshold = false;
    }

    final result = <String, dynamic>{
      if (_baselinePowerW != null) 'baseline_power_w': _baselinePowerW,
      'peak_power_w': _peakPowerW,
      if (_timeToFullPowerMs != null)
        'time_to_full_power_ms': _timeToFullPowerMs,
      'active_heating_s': _activeHeatingTotal.inSeconds,
      if (_voltageSamples > 0)
        'grid_voltage_v': _voltageSum / _voltageSamples,
      if (_preheatEnergyWh != null) ...{
        'preheat_energy_wh': _preheatEnergyWh,
        'preheat_energy_margin_pct':
            (HeaterThresholds.preheatEnergyBudgetWh - _preheatEnergyWh!) /
            HeaterThresholds.preheatEnergyBudgetWh *
            100,
        if (_preheatSeconds != null) 'preheat_s': _preheatSeconds,
      },
    };

    _baselinePowerW = null;
    _voltageSamples = 0;
    _voltageSum = 0;
    _integrating = false;
    debugPrint('CycleEnergyService.endCycle: $result');
    return result;
  }
}
