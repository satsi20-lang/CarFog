import 'package:flutter_test/flutter_test.dart';
import 'package:dry_fog_app/models/bus_map.dart';
import 'package:dry_fog_app/services/heater_safety_monitor.dart';

// Детекторы отказа датчика температуры и "убегающего" нагрева (задача
// "детектор отказа датчика температуры"). Тик опроса в приложении — 3 с,
// здесь тот же шаг на подменяемых часах.
void main() {
  late DateTime now;
  DateTime clock() => now;
  void tick([int seconds = 3]) => now = now.add(Duration(seconds: seconds));

  HeaterSafetyMonitor monitor({bool noRise = true, bool energy = true}) =>
      HeaterSafetyMonitor(checkNoRise: noRise, checkEnergy: energy, clock: clock);

  setUp(() => now = DateTime(2026, 10, 1, 12));

  group('нормальный прогрев — ложных срабатываний нет', () {
    test('рост ~2°C/с с 20°C до цели не даёт ни одного детектора', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      var temp = 20.0;
      for (var i = 0; i < 20; i++) {
        tick();
        temp += 6.5; // ~2.2°C/с × 3 с
        expect(m.observeTemperature(temp), isNull, reason: 'тик $i');
        expect(m.observeEnergy(energyWh: i * 1.2, targetReached: false), isNull);
      }
      expect(m.riseConfirmed, isTrue);
    });

    test('горячий старт: температура уже у цели, ТЭН ВКЛ на пару тиков', () {
      final m = monitor()..heaterCommanded(true, tempC: 188.0);
      tick();
      expect(m.observeTemperature(190.5), isNull); // +2.5 < 3 — ещё не rise
      tick();
      expect(m.observeTemperature(193.0), isNull);
      expect(m.riseConfirmed, isTrue);
    });
  });

  group('out_of_range', () {
    test('одиночный сбой чтения (null) отказом НЕ считается', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      tick();
      expect(m.observeTemperature(null), isNull);
      tick();
      expect(m.observeTemperature(27.0), isNull); // чтение вернулось
      tick();
      expect(m.observeTemperature(33.0), isNull);
      tick();
      expect(m.observeTemperature(null), isNull); // счётчик плохих сброшен
    });

    test('3 плохих чтения подряд при включённом ТЭНе — отказ, no_reading', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      tick();
      expect(m.observeTemperature(null), isNull);
      tick();
      expect(m.observeTemperature(null), isNull);
      tick();
      final f = m.observeTemperature(null);
      expect(f, isNotNull);
      expect(f!.subtype, 'out_of_range');
      expect(f.reason, 'no_reading');
    });

    test('служебное значение обрыва термопары (-500) — below_min после подтверждения', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      HeaterFault? f;
      for (var i = 0; i < HeaterThresholds.sensorBadReadConfirmCount; i++) {
        tick();
        f = m.observeTemperature(-500.0);
      }
      expect(f?.subtype, 'out_of_range');
      expect(f?.reason, 'below_min');
    });

    test('нереалистично высокое значение — above_max', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      HeaterFault? f;
      for (var i = 0; i < HeaterThresholds.sensorBadReadConfirmCount; i++) {
        tick();
        f = m.observeTemperature(900.0);
      }
      expect(f?.reason, 'above_max');
    });

    test('при ВЫКЛЮЧЕННОМ ТЭНе плохие чтения не копятся', () {
      final m = monitor();
      for (var i = 0; i < 10; i++) {
        tick();
        expect(m.observeTemperature(null), isNull);
      }
      m.heaterCommanded(true, tempC: 20.0);
      tick();
      expect(m.observeTemperature(null), isNull); // счёт начался заново
    });
  });

  group('stale — застывшее показание', () {
    test('одно и то же значение при непрерывно включённом ТЭНе — за окно', () {
      final m = monitor(noRise: false)..heaterCommanded(true, tempC: 140.0);
      HeaterFault? f;
      var elapsed = 0;
      while (f == null && elapsed < 60) {
        tick();
        elapsed += 3;
        f = m.observeTemperature(140.0);
      }
      expect(f?.subtype, 'stale');
      // за секунды, а не за таймаут: окно 9 с → срабатывание на 9-й секунде
      expect(elapsed, HeaterThresholds.sensorStaleWindow.inSeconds);
    });

    test('значение с шумом в одну десятую не считается застывшим', () {
      final m = monitor(noRise: false)..heaterCommanded(true, tempC: 140.0);
      var toggle = false;
      for (var i = 0; i < 30; i++) {
        tick();
        toggle = !toggle;
        expect(m.observeTemperature(toggle ? 140.1 : 140.0), isNull);
      }
    });

    test('ТЭН выключен — температура вправе стоять, затем окно начинается заново', () {
      final m = monitor(noRise: false)..heaterCommanded(true, tempC: 150.0);
      m.heaterCommanded(false);
      for (var i = 0; i < 10; i++) {
        tick();
        expect(m.observeTemperature(150.0), isNull);
      }
      m.heaterCommanded(true, tempC: 150.0);
      tick();
      expect(m.observeTemperature(150.0), isNull);
      tick();
      expect(m.observeTemperature(150.0), isNull);
    });
  });

  group('no_rise', () {
    test('температура не растёт после команды — отказ по окну', () {
      // показание меняется шумом (не stale), но подъёма нет
      final m = monitor()..heaterCommanded(true, tempC: 60.0);
      HeaterFault? f;
      var elapsed = 0;
      var toggle = false;
      while (f == null && elapsed < 60) {
        tick();
        elapsed += 3;
        toggle = !toggle;
        f = m.observeTemperature(toggle ? 60.2 : 60.0);
      }
      expect(f?.subtype, 'no_rise');
      expect(elapsed, greaterThanOrEqualTo(HeaterThresholds.noRiseWindow.inSeconds));
    });

    test('в режиме обработки (checkNoRise=false) отсутствие роста не отказ', () {
      final m = monitor(noRise: false)..heaterCommanded(true, tempC: 150.0);
      var toggle = false;
      for (var i = 0; i < 30; i++) {
        tick();
        toggle = !toggle;
        expect(m.observeTemperature(toggle ? 150.2 : 150.0), isNull);
      }
    });
  });

  group('energy_budget', () {
    test('перерасход энергии без достижения цели — отказ', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      tick();
      expect(
        m.observeEnergy(
          energyWh: HeaterThresholds.preheatEnergyBudgetWh + 0.1,
          targetReached: false,
        )?.subtype,
        'energy_budget',
      );
    });

    test('перерасход, но цель по показаниям достигнута — не отказ датчика', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      expect(
        m.observeEnergy(energyWh: 100, targetReached: true),
        isNull,
      );
    });

    test('худший измеренный нормальный прогрев (≈28 Вт·ч) проходит с запасом', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      expect(m.observeEnergy(energyWh: 28.0, targetReached: false), isNull);
      // запас по бюджету, в процентах — для записи в журнал проверки
      final marginPct =
          (HeaterThresholds.preheatEnergyBudgetWh - 28.0) /
          HeaterThresholds.preheatEnergyBudgetWh *
          100;
      expect(marginPct, greaterThan(30));
    });

    test('в режиме обработки (checkEnergy=false) бюджет не проверяется', () {
      final m = monitor(energy: false)..heaterCommanded(true, tempC: 150.0);
      expect(m.observeEnergy(energyWh: 500, targetReached: false), isNull);
    });
  });

  test('details содержат последние показания и время от команды на ТЭН', () {
    final m = monitor(noRise: false)..heaterCommanded(true, tempC: 140.0);
    HeaterFault? f;
    while (f == null) {
      tick();
      f = m.observeTemperature(140.0);
    }
    expect(f.details['start_temp_c'], 140.0);
    expect(f.details['last_temp_c'], 140.0);
    expect(f.details['since_heater_on_s'], isA<double>());
    expect((f.details['recent_temps'] as List), isNotEmpty);
  });

  group('нереальная скорость изменения (разовый выброс при обрыве)', () {
    test('317°C после 40°C за один тик — плохое чтение, не отказ и не решение', () {
      final m = monitor()..heaterCommanded(true, tempC: 40.0);
      tick();
      expect(m.observeTemperature(46.0), isNull);
      tick();
      expect(m.observeTemperature(317.5), isNull); // выброс при отсоединении
      expect(m.lastReadBad, isTrue); // по нему нельзя решать "перегрев"
      tick();
      expect(m.observeTemperature(52.0), isNull); // датчик вернулся
      expect(m.lastReadBad, isFalse);
    });

    test('три выброса подряд — отказ out_of_range / implausible_jump', () {
      final m = monitor()..heaterCommanded(true, tempC: 40.0);
      tick();
      expect(m.observeTemperature(46.0), isNull);
      HeaterFault? f;
      for (var i = 0; i < 3; i++) {
        tick();
        f = m.observeTemperature(317.5);
      }
      expect(f?.kind, HeaterFaultKind.outOfRange);
      expect(f?.reason, 'implausible_jump');
    });

    test('нормальный нагрев 3°C/с (9°C за тик) скачком НЕ считается', () {
      final m = monitor()..heaterCommanded(true, tempC: 20.0);
      var t = 20.0;
      for (var i = 0; i < 15; i++) {
        tick();
        t += 9.0;
        expect(m.observeTemperature(t), isNull, reason: 'тик $i');
        expect(m.lastReadBad, isFalse);
      }
    });

    test('выброс не сдвигает опору: следующее нормальное чтение — не скачок', () {
      final m = monitor()..heaterCommanded(true, tempC: 40.0);
      tick();
      m.observeTemperature(46.0);
      tick();
      m.observeTemperature(317.5);
      tick();
      m.observeTemperature(52.0);
      expect(m.lastReadBad, isFalse);
    });

    test('скачок при выключенном ТЭНе не даёт отказа', () {
      final m = monitor();
      m.observeTemperature(40.0);
      tick();
      expect(m.observeTemperature(317.5), isNull);
    });

    test('постоянный обрыв −500 по-прежнему out_of_range', () {
      final m = monitor()..heaterCommanded(true, tempC: 40.0);
      HeaterFault? f;
      for (var i = 0; i < 3; i++) {
        tick();
        f = m.observeTemperature(-500.0);
      }
      expect(f?.kind, HeaterFaultKind.outOfRange);
    });
  });

  group('бюджет энергии после пересмотра 03.10.2026', () {
    test('измеренный холодный прогрев 36.3 Вт·ч проходит с запасом ≥ 40%', () {
      final m = monitor()..heaterCommanded(true, tempC: 25.0);
      tick();
      expect(m.observeEnergy(energyWh: 36.3, targetReached: false), isNull);
      expect(HeaterThresholds.preheatEnergyBudgetWh, greaterThanOrEqualTo(36.3 * 1.4));
    });

    test('оценка для −25°C (≈47 Вт·ч) проходит, 72 Вт·ч (таймаут) — отказ', () {
      final m = monitor()..heaterCommanded(true, tempC: -25.0);
      tick();
      expect(m.observeEnergy(energyWh: 47.0, targetReached: false), isNull);
      expect(
        m.observeEnergy(energyWh: 72.0, targetReached: false)?.kind,
        HeaterFaultKind.energyBudget,
      );
    });
  });
}
