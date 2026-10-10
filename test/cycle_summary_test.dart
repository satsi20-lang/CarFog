import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/remote_limits.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/cycle_summary_service.dart';
import 'package:dry_fog_app/services/heater_shutdown_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/session_service.dart';

// Сводка цикла в session_complete (1.10.1): только запись, на цикл не влияет.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = ['com.carfog.dryfog/modbus', 'com.carfog.dryfog/system', 'com.carfog.dryfog/storage'];

  // Подставные часы: время двигает сам тест.
  var clock = DateTime(2026, 10, 10, 12);
  void tick(num seconds) => clock = clock.add(Duration(milliseconds: (seconds * 1000).round()));

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ModbusService.paymentBlocked = false;
    CloudService.resetQueueForTest();
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (call) async => null);
    }
    clock = DateTime(2026, 10, 10, 12);
    CycleSummary.now = () => clock;
    CycleSummary.reset();
  });

  tearDown(() {
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
    CycleSummary.now = DateTime.now;
    CycleSummary.reset();
  });

  Future<void> startSession() => SessionService.start(
        flavorIndex: 0,
        flavorNameRu: 'Лимон',
        priceCents: 200,
        paidCents: 200,
        readStartEnergy: false,
      );

  Future<Map<String, dynamic>> lastSession() async {
    final ev = (await CloudService.history()).where((e) => e.type == CloudEventType.sessionComplete).toList();
    expect(ev, isNotEmpty, reason: 'session_complete должно уйти');
    return ev.last.data;
  }

  // Обычный цикл в том же порядке отметок, что дают экраны.
  void normalCycle({bool withTemps = true}) {
    CycleSummary.enterPhase('preheat'); // preparing.initState
    tick(1); // beginCycle: базовая мощность
    if (withTemps) CycleSummary.recordTemp(21.04); // температура до команды
    CycleSummary.heaterCommanded(true);
    var t = 21.04;
    for (var i = 0; i < 30; i++) {
      tick(3);
      t += 5.66;
      if (withTemps) CycleSummary.recordTemp(t);
    }
    CycleSummary.preheatReached(190.84);
    tick(0.2);
    CycleSummary.enterPhase('compressor_startup');
    tick(5);
    CycleSummary.enterPhase('treating');
    for (var i = 0; i < 13; i++) {
      tick(3);
      if (withTemps) CycleSummary.recordTemp(i < 6 ? 196.0 + i : 200.0 - i);
      if (i == 4) CycleSummary.heaterCommanded(false); // гистерезис: выше коридора
      if (i == 9) CycleSummary.heaterCommanded(true); // ниже коридора
    }
    tick(1);
    CycleSummary.heaterCommanded(false); // HeaterShutdownService: конец обработки
    CycleSummary.enterPhase('purge');
    tick(5);
  }

  test('обычный цикл: сводные поля, единицы и округление', () async {
    await startSession();
    normalCycle();
    await SessionService.complete();
    final d = await lastSession();
    expect(d['completed'], isTrue);
    expect(d['preheat_s'], 90.0);
    expect(d['start_temp_c'], 21.0);
    expect(d['preheat_end_temp_c'], 190.8);
    expect(d['peak_temp_c'], 201.0);
    expect(d['final_temp_c'], 188.0);
    expect(d['heater_switches'], 4); // вкл, выкл, вкл, выкл
    // вкл 90 + 0.2 + 5 + 15 (до выкл на i=4) = 110.2; снова вкл на i=9 → 3·3+1 = 10
    expect(d['heater_on_s'], 120.2);
    expect(d['phase_preheat_s'], 91.2);
    expect(d['phase_compressor_startup_s'], 5.0);
    expect(d['phase_treating_s'], 40.0);
    expect(d['phase_purge_s'], 5.0);
    expect(d.containsKey('preheat_aborted'), isFalse);
    final curve = (d['temp_curve_c'] as List).cast<num>();
    expect(curve.length, lessThanOrEqualTo(CycleSummaryLimits.curveMaxPoints));
    expect(d['temp_curve_step_s'], greaterThanOrEqualTo(10));
    expect(curve.first, 21.0);
    for (final v in curve) {
      expect((v * 10).roundToDouble(), v * 10, reason: 'округление до 0,1');
    }
    final size = jsonEncode(d).length;
    expect(size, lessThanOrEqualTo(CycleSummaryLimits.maxEventDataChars));
    // ignore: avoid_print
    print('пример (обычный цикл, $size символов): ${jsonEncode(d)}');
  });

  test('прерванная сессия: preheat_aborted и причина, событие уходит', () async {
    await startSession();
    CycleSummary.enterPhase('preheat');
    CycleSummary.recordTemp(20);
    CycleSummary.heaterCommanded(true);
    tick(600);
    CycleSummary.recordTemp(150.25);
    CycleSummary.preheatAborted('HEAT_TIMEOUT'); // _fail
    CycleSummary.preheatAborted('preheat_abandoned'); // dispose: первая причина остаётся
    CycleSummary.heaterCommanded(false);
    await SessionService.interrupt('heat_timeout', serviceNotDelivered: true);
    final d = await lastSession();
    expect(d['completed'], isFalse);
    expect(d['reason'], 'heat_timeout');
    expect(d['preheat_aborted'], isTrue);
    expect(d['preheat_abort_reason'], 'HEAT_TIMEOUT');
    expect(d.containsKey('preheat_s'), isFalse);
    expect(d.containsKey('preheat_end_temp_c'), isFalse);
    expect(d['peak_temp_c'], 150.3);
    expect(d['heater_on_s'], 600.0);
    expect(d['heater_switches'], 2);
    expect(d['phase_preheat_s'], 600.0);
  });

  test('без показаний термопары: температурных полей нет, событие уходит', () async {
    await startSession();
    normalCycle(withTemps: false);
    await SessionService.complete();
    final d = await lastSession();
    for (final k in ['start_temp_c', 'preheat_end_temp_c', 'peak_temp_c', 'final_temp_c', 'temp_curve_c']) {
      if (k == 'preheat_end_temp_c') continue; // цель отмечается экраном по годному показанию
      expect(d.containsKey(k), isFalse, reason: k);
    }
    expect(d['phase_treating_s'], 40.0);
    expect(d['completed'], isTrue);
  });

  test('термопара не установлена: ТЭН не включался — нет и полей ТЭНа', () async {
    await startSession();
    CycleSummary.enterPhase('preheat');
    CycleSummary.preheatAborted('HEAT_NO_THERMOCOUPLE');
    await SessionService.interrupt('thermo_not_installed', serviceNotDelivered: true);
    final d = await lastSession();
    expect(d.containsKey('heater_switches'), isFalse);
    expect(d.containsKey('heater_on_s'), isFalse);
    expect(d['preheat_abort_reason'], 'HEAT_NO_THERMOCOUPLE');
    expect(d['service_delivered'], isFalse);
  });

  test('ошибка сборщика не мешает событию: поля просто отсутствуют', () async {
    await startSession();
    normalCycle();
    CycleSummary.now = () => throw StateError('часы сломались');
    expect(() => CycleSummary.recordTemp(10), returnsNormally);
    await SessionService.complete();
    final d = await lastSession();
    expect(d['completed'], isTrue);
    expect(d.containsKey('phase_treating_s'), isFalse);
    expect(d.containsKey('peak_temp_c'), isFalse);
  });

  test('размер: длинный цикл укладывается в предел; превышение — кривая выбрасывается', () async {
    await startSession();
    CycleSummary.enterPhase('preheat');
    CycleSummary.heaterCommanded(true);
    for (var i = 0; i < 1200; i++) {
      tick(3);
      CycleSummary.recordTemp(20 + i * 0.1537);
    }
    await SessionService.complete();
    final d = await lastSession();
    final curve = d['temp_curve_c'] as List;
    expect(curve.length, inInclusiveRange(2, CycleSummaryLimits.curveMaxPoints));
    final size = jsonEncode(d).length;
    expect(size, lessThanOrEqualTo(CycleSummaryLimits.maxEventDataChars));
    // ignore: avoid_print
    print('пример: размер данных session_complete $size символов JSON, точек кривой ${curve.length}');

    // Большое extra (подробности отказа) — кривая не входит, числа остаются.
    await startSession();
    normalCycle();
    await SessionService.interrupt('heater_sensor_fault', extra: {'recent_temps': List.filled(700, 199.9)});
    final big = await lastSession();
    expect(big.containsKey('temp_curve_c'), isFalse);
    expect(big['peak_temp_c'], 201.0);
    expect(big['phase_treating_s'], 40.0);
  });

  test('сводка не тянется между сессиями (discard)', () async {
    await startSession();
    CycleSummary.enterPhase('preheat');
    CycleSummary.recordTemp(55);
    SessionService.discard();
    expect(CycleSummary.active, isFalse);
    await startSession();
    normalCycle(withTemps: false);
    await SessionService.complete();
    expect((await lastSession()).containsKey('peak_temp_c'), isFalse);
  });

  test('выключение ТЭНа через HeaterShutdownService отмечается в сводке', () async {
    await startSession();
    CycleSummary.enterPhase('preheat');
    CycleSummary.heaterCommanded(true);
    tick(12);
    await HeaterShutdownService.confirmOff(meterInstalled: false, forceOff: () async => true);
    tick(30);
    await SessionService.complete();
    final d = await lastSession();
    expect(d['heater_switches'], 2);
    expect(d['heater_on_s'], 12.0);
  });

  test('старые события без новых полей читаются как раньше', () {
    final old = CloudEvent.fromJson({
      'type': 'session_complete',
      'ts': '2026-10-01T10:00:00.000',
      'data': {'session_id': '1', 'completed': true, 'duration_s': 60},
    });
    expect(old.data['completed'], isTrue);
    expect(old.data.containsKey('peak_temp_c'), isFalse);
  });
}
