import '../models/bus_map.dart';

// Независимый от "верю термопаре" контроль нагрева (задача "детектор
// отказа датчика температуры"). Чистая логика без шины и без экранов —
// на вход подаются команды на ТЭН и показания, на выходе вердикт; часы
// подменяются в тестах.
//
// Работает ТОЛЬКО пока ТЭН включён. Четыре детектора (пороги и их
// происхождение — HeaterThresholds в bus_map.dart):
//   out_of_range  — показание вне допустимого диапазона / служебный код
//                   обрыва / null и ошибки чтения ПОДРЯД несколько раз;
//   stale         — при непрерывно включённом ТЭНе показание не менялось;
//   no_rise       — после команды температура не выросла на минимум за окно;
//   energy_budget — набежало больше энергии, чем нужно на прогрев, а цель
//                   по показаниям не достигнута.
// Одиночный сбой чтения (шину дёрнуло) отказом не считается: нужно
// HeaterThresholds.sensorBadReadConfirmCount плохих чтений подряд.

enum HeaterFaultKind { outOfRange, stale, noRise, energyBudget }

extension HeaterFaultKindCode on HeaterFaultKind {
  // Подтип в hardware_error 'heater_sensor_fault' и в details вывода из
  // обслуживания.
  String get code {
    switch (this) {
      case HeaterFaultKind.outOfRange:
        return 'out_of_range';
      case HeaterFaultKind.stale:
        return 'stale';
      case HeaterFaultKind.noRise:
        return 'no_rise';
      case HeaterFaultKind.energyBudget:
        return 'energy_budget';
    }
  }
}

class HeaterFault {
  final HeaterFaultKind kind;
  // Что именно не так: 'no_reading' | 'below_min' | 'above_max' |
  // 'unchanged' | 'no_temperature_rise' | 'budget_exceeded'.
  final String reason;
  // Последние показания, время от команды на ТЭН и т.п. — идёт в журнал и
  // в облако; мощность/энергию/напряжение добавляет вызывающий код.
  final Map<String, dynamic> details;

  const HeaterFault(this.kind, this.reason, this.details);

  String get subtype => kind.code;
}

class HeaterSafetyMonitor {
  // checkNoRise / checkEnergy — только для прогрева (сухой цикл без
  // жидкости, поведение измерено). В режиме обработки с жидкостью
  // температура может стоять на плато при включённом ТЭНе, поэтому там
  // работают только out_of_range и stale.
  HeaterSafetyMonitor({
    this.checkNoRise = true,
    this.checkEnergy = true,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final bool checkNoRise;
  final bool checkEnergy;
  final DateTime Function() _clock;

  bool _heaterOn = false;
  DateTime? _onSince;
  double? _startTemp;
  bool _riseConfirmed = false;
  double? _lastTemp;
  DateTime? _lastChangeAt;
  // Последнее годное (не выброс) показание и его время — для проверки
  // скорости изменения; обновляется и при выключенном ТЭНе.
  double? _lastGood;
  DateTime? _lastGoodAt;
  bool _lastReadBad = false;
  int _consecutiveBad = 0;
  final List<Map<String, dynamic>> _recent = [];

  bool get heaterOn => _heaterOn;

  // Последнее показание признано плохим (null / вне диапазона / нереальный
  // скачок). Вызывающий код НЕ принимает по нему решений (перегрев,
  // гистерезис, цель прогрева): одиночный выброс не должен ни выводить
  // аппарат из обслуживания "перегревом", ни включать/выключать реле.
  bool get lastReadBad => _lastReadBad;

  // Показание годно для принятия решений (в допустимом диапазоне). null,
  // служебное значение обрыва и нереалистично высокое — нет. Управление
  // нагревом по таким значениям недопустимо: например, -500°C как "ниже
  // порога включения" включило бы ТЭН.
  static bool isUsable(double? t) =>
      t != null &&
      t > HeaterThresholds.sensorPlausibleMinC &&
      t <= HeaterThresholds.sensorPlausibleMaxC;

  // Температура уже выросла на noRiseMinC с момента команды (для пробного
  // цикла — критерий успеха).
  bool get riseConfirmed => _riseConfirmed;

  // Команда на ТЭН. Включение (из выключенного) начинает отсчёт окон
  // заново; повторное "включить" при уже включённом — игнорируется;
  // выключение останавливает контроль (ТЭН выключен — температура вправе
  // стоять).
  void heaterCommanded(bool on, {double? tempC}) {
    if (on == _heaterOn) return;
    _heaterOn = on;
    _consecutiveBad = 0;
    if (on) {
      final now = _clock();
      _onSince = now;
      _startTemp = tempC;
      _riseConfirmed = false;
      _lastTemp = tempC;
      _lastChangeAt = now;
    }
  }

  // Последний сработавший детектор (для пакета диагностики): подтип,
  // причина, время. Хранится статически — мониторы живут в экранах и
  // исчезают вместе с ними.
  static Map<String, dynamic>? lastFault;

  static HeaterFault? _record(HeaterFault? f) {
    if (f != null) {
      lastFault = {
        'subtype': f.subtype,
        'reason': f.reason,
        'at': DateTime.now().toIso8601String(),
      };
    }
    return f;
  }

  // Каждое показание температуры (в том числе null — не удалось прочитать).
  HeaterFault? observeTemperature(double? temp) =>
      _record(_observeTemperature(temp));

  HeaterFault? _observeTemperature(double? temp) {
    final now = _clock();
    final outOfBounds = !isUsable(temp);
    var jump = false;
    final good = _lastGood;
    final goodAt = _lastGoodAt;
    if (!outOfBounds && good != null && goodAt != null) {
      final delta = (temp! - good).abs();
      final dtS = now.difference(goodAt).inMilliseconds / 1000.0;
      jump = delta >= HeaterThresholds.sensorJumpMinDeltaC &&
          (dtS <= 0 || delta / dtS > HeaterThresholds.sensorMaxRateCPerS);
    }
    final bad = outOfBounds || jump;
    _lastReadBad = bad;
    _remember(now, temp);
    // Опорное годное показание — только из НЕвыбросов (иначе выброс сам
    // сдвинул бы опору и следующее нормальное чтение выглядело бы скачком).
    if (!bad) {
      _lastGood = temp;
      _lastGoodAt = now;
    }

    if (!_heaterOn) {
      _consecutiveBad = 0;
      if (!bad) _lastTemp = temp;
      return null;
    }

    if (bad) {
      _consecutiveBad++;
      if (_consecutiveBad >= HeaterThresholds.sensorBadReadConfirmCount) {
        final reason = temp == null
            ? 'no_reading'
            : jump
            ? 'implausible_jump'
            : (temp <= HeaterThresholds.sensorPlausibleMinC
                  ? 'below_min'
                  : 'above_max');
        return HeaterFault(HeaterFaultKind.outOfRange, reason, _details(now));
      }
      return null;
    }
    _consecutiveBad = 0;

    // bad == false → isUsable(temp) → temp не null.
    final t = temp!;
    _startTemp ??= t;
    final last = _lastTemp;
    if (last == null ||
        (t - last).abs() >= HeaterThresholds.sensorChangeEpsilonC) {
      _lastChangeAt = now;
    }
    _lastTemp = t;
    _lastChangeAt ??= now;

    if (now.difference(_lastChangeAt!) >= HeaterThresholds.sensorStaleWindow) {
      return HeaterFault(HeaterFaultKind.stale, 'unchanged', _details(now));
    }

    if (checkNoRise && !_riseConfirmed) {
      if (t - _startTemp! >= HeaterThresholds.noRiseMinC) {
        _riseConfirmed = true;
      } else if (now.difference(_onSince!) >= HeaterThresholds.noRiseWindow) {
        return HeaterFault(
          HeaterFaultKind.noRise,
          'no_temperature_rise',
          _details(now),
        );
      }
    }
    return null;
  }

  // Накопленная с момента команды на ТЭН энергия (Вт·ч, по интегралу
  // мощности со счётчика). targetReached — цель прогрева по показаниям уже
  // достигнута (тогда перерасход не отказ датчика, а просто долгий прогрев).
  HeaterFault? observeEnergy({
    required double energyWh,
    required bool targetReached,
  }) => _record(_observeEnergy(energyWh: energyWh, targetReached: targetReached));

  HeaterFault? _observeEnergy({
    required double energyWh,
    required bool targetReached,
  }) {
    if (!_heaterOn || !checkEnergy || targetReached) return null;
    if (energyWh > HeaterThresholds.preheatEnergyBudgetWh) {
      final details = _details(_clock());
      details['energy_since_heater_on_wh'] = energyWh;
      details['energy_budget_wh'] = HeaterThresholds.preheatEnergyBudgetWh;
      return HeaterFault(
        HeaterFaultKind.energyBudget,
        'budget_exceeded',
        details,
      );
    }
    return null;
  }

  void _remember(DateTime now, double? temp) {
    final onSince = _onSince;
    _recent.add({
      't_s': _heaterOn && onSince != null
          ? now.difference(onSince).inMilliseconds / 1000.0
          : null,
      'c': temp,
    });
    if (_recent.length > 6) _recent.removeAt(0);
  }

  Map<String, dynamic> _details(DateTime now) {
    final onSince = _onSince;
    return {
      if (onSince != null)
        'since_heater_on_s': now.difference(onSince).inMilliseconds / 1000.0,
      'start_temp_c': _startTemp,
      'last_temp_c': _lastTemp,
      'consecutive_bad_reads': _consecutiveBad,
      'recent_temps': List<Map<String, dynamic>>.from(_recent),
    };
  }
}
