import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/out_of_service.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/card_payment_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/out_of_service_service.dart';
import 'package:dry_fog_app/services/session_service.dart';
import 'package:dry_fog_app/services/thermo_idle_watch_service.dart';

// 1.11.4: фоновый контроль термопары в простое — проба раз в минуту (до 3
// свежих чтений), 3 неудачные пробы подряд → temp_sensor_fault /
// idle_no_reading. Часы и паузы подставные.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  const system = MethodChannel('com.carfog.dryfog/system');
  const storage = MethodChannel('com.carfog.dryfog/storage');

  late List<Object?> temps;
  late int tempReads;
  late List<String> systemCalls;
  late DateTime now;

  Object? next(List<Object?> q) => q.length > 1 ? q.removeAt(0) : q.first;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.resetForTest();
    CloudService.resetQueueForTest();
    CloudService.transport = LocalLogTransport();
    CardPaymentService.resetForTest();
    ModbusService.resetLastReadsForTest();
    ModbusService.paymentBlocked = false;
    now = DateTime(2026, 10, 25, 3, 0, 0);
    ModbusService.clock = () => now;
    ThermoIdleWatchService.pause = (d) async => now = now.add(d);
    temps = [32.0];
    tempReads = 0;
    systemCalls = [];
    messenger.setMockMethodCallHandler(modbus, (c) async {
      if (c.method == 'readTemperature') {
        tempReads++;
        now = now.add(const Duration(milliseconds: 40));
        return next(temps);
      }
      if (c.method == 'readAllInputs' || c.method == 'readCoils') return List.filled(16, false);
      return true;
    });
    messenger.setMockMethodCallHandler(system, (c) async {
      systemCalls.add(c.method);
      return c.method == 'writeOutOfService' || c.method == 'clearOutOfService' ? true : null;
    });
    messenger.setMockMethodCallHandler(storage, (c) async => null);
  });
  tearDown(() {
    ThermoIdleWatchService.stop();
    ThermoIdleWatchService.pause = Future<void>.delayed;
    SessionService.discard();
    ModbusService.resetLastReadsForTest();
    for (final c in [modbus, system, storage]) {
      messenger.setMockMethodCallHandler(c, null);
    }
  });

  AppNotifier notifier({bool thermo = true, String type = PaymentTerminalType.pulse}) {
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: thermo,
        energyMeterInstalled: true,
        paymentTerminalType: type,
        deviceId: 'CARFOG-T',
      );
    n.setBusHealthy(true);
    n.updateLevels(List.filled(8, true));
    n.transition(AppState.standby);
    return n;
  }

  // Следующая проба — через минуту.
  Future<bool> minuteLater(ThermoIdleWatchService w) {
    now = now.add(ThermoIdleWatchService.interval);
    return w.tick();
  }

  group('вывод из обслуживания после 3 неудачных проб', () {
    for (final (bad, reason) in <(Object?, String)>[(-500.0, 'обрыв −500'), (null, 'нет ответа')]) {
      test('$reason: 3 пробы подряд → temp_sensor_fault / idle_no_reading', () async {
        final n = notifier();
        final w = ThermoIdleWatchService.forTest(n);
        temps = [bad];
        expect(await w.tick(), isTrue);
        expect(n.outOfService, isNull, reason: 'одна проба состояние не меняет');
        expect(await minuteLater(w), isTrue);
        expect(n.outOfService, isNull);
        expect(await minuteLater(w), isTrue);
        expect(tempReads, 9, reason: '3 пробы по 3 чтения');
        final oos = n.outOfService!;
        expect(oos.code, OutOfServiceCode.tempSensorFault);
        expect(oos.details['subtype'], 'idle_no_reading');
        expect(oos.details['attempts'], 3);
        expect((oos.details['readings'] as List).map((e) => e['value']), [bad, bad, bad]);
        expect(oos.details.containsKey('last_usable_c'), isTrue);
        expect(oos.details['last_usable_c'], isNull);
        expect(oos.details['last_usable_age_s'], isNull);
        // записано на диск, оплата закрыта любым способом
        expect(systemCalls, contains('writeOutOfService'));
        expect(n.isPaymentBlocked, isTrue);
        final e = (await CloudService.history()).lastWhere((e) => e.type == CloudEventType.outOfService);
        expect(e.data['code'], 'temp_sensor_fault');
        expect(e.data['subtype'], 'idle_no_reading');
        expect(e.data['persisted'], true);
        expect(e.data['attempts'], 3);
        expect(e.data['readings'], isA<List>());
      });
    }

    test('в событии — последнее годное показание и его возраст', () async {
      final n = notifier();
      final w = ThermoIdleWatchService.forTest(n);
      temps = [31.5];
      expect(await w.tick(), isTrue);
      temps = [-500.0];
      for (var i = 0; i < 3; i++) {
        expect(await minuteLater(w), isTrue);
      }
      expect(n.outOfService!.details['last_usable_c'], 31.5);
      expect(n.outOfService!.details['last_usable_age_s'], greaterThanOrEqualTo(180));
    });

    test('монетный аппарат (тип терминала off) защищается так же', () async {
      final n = notifier(type: PaymentTerminalType.off);
      final w = ThermoIdleWatchService.forTest(n);
      temps = [-500.0];
      await w.tick();
      await minuteLater(w);
      await minuteLater(w);
      expect(n.outOfService?.code, OutOfServiceCode.tempSensorFault);
    });
  });

  group('годное показание сбрасывает счёт', () {
    test('2 неудачные + годная проба → без изменений, счёт заново', () async {
      final n = notifier();
      final w = ThermoIdleWatchService.forTest(n);
      temps = [-500.0];
      await w.tick();
      await minuteLater(w);
      expect(w.failedProbes, 2);
      temps = [null, 32.0]; // годное на 2-м чтении — проба прошла
      await minuteLater(w);
      expect(w.failedProbes, 0);
      temps = [-500.0];
      await minuteLater(w);
      await minuteLater(w);
      expect(n.outOfService, isNull, reason: 'после сброса только 2 неудачные');
    });

    test('годное чтение в другом месте приложения между пробами сбрасывает счёт', () async {
      final n = notifier();
      final w = ThermoIdleWatchService.forTest(n);
      temps = [-500.0];
      await w.tick();
      await minuteLater(w);
      temps = [33.0];
      now = now.add(const Duration(seconds: 10));
      await ModbusService.readTemperature(); // например, вкладка «Диагностика»
      temps = [-500.0];
      await minuteLater(w);
      expect(w.failedProbes, 1);
      expect(n.outOfService, isNull);
    });
  });

  group('когда не опрашивать', () {
    Future<void> expectNoProbe(AppNotifier n, String why) async {
      final w = ThermoIdleWatchService.forTest(n);
      temps = [-500.0];
      for (var i = 0; i < 4; i++) {
        expect(await minuteLater(w), isFalse, reason: why);
      }
      expect(tempReads, 0, reason: why);
    }

    test('термопара не установлена', () async {
      final n = notifier(thermo: false);
      await expectNoProbe(n, 'нет термопары');
      expect(n.outOfService, isNull);
    });

    for (final s in [
      AppState.payment,
      AppState.preparing,
      AppState.compressorStartup,
      AppState.treating,
      AppState.servicePinEntry,
      AppState.serviceMenu,
    ]) {
      test('состояние ${s.name} (оплата, цикл, продувка, сервисное меню)', () {
        final n = notifier()..transition(s);
        return expectNoProbe(n, s.name);
      });
    }

    test('идёт сессия (оплачено, цикл)', () async {
      final n = notifier();
      await SessionService.start(
        flavorIndex: 0, flavorNameRu: 'Лимон', priceCents: 200, paidCents: 200, readStartEnergy: false,
      );
      await expectNoProbe(n, 'сессия');
    });

    test('шина считается неисправной', () => expectNoProbe(notifier()..setBusHealthy(false), 'шина'));

    test('аппарат уже выведен из обслуживания', () async {
      final n = notifier();
      n.enterOutOfService(OutOfServiceState(code: OutOfServiceCode.overheat, since: now, details: const {}));
      await expectNoProbe(n, 'уже выведен');
      expect(n.outOfService?.code, OutOfServiceCode.overheat, reason: 'прежняя причина не подменяется');
    });

    test('не чаще раза в минуту', () async {
      final n = notifier();
      final w = ThermoIdleWatchService.forTest(n);
      temps = [-500.0];
      expect(await w.tick(), isTrue);
      now = now.add(const Duration(seconds: 30));
      expect(await w.tick(), isFalse);
      expect(tempReads, 3);
    });
  });

  group('снятие', () {
    test('блокировка снимается пробным циклом на месте; после снятия пробы снова идут', () async {
      final n = notifier();
      final w = ThermoIdleWatchService.forTest(n);
      temps = [-500.0];
      await w.tick();
      await minuteLater(w);
      await minuteLater(w);
      expect(n.outOfService?.code, OutOfServiceCode.tempSensorFault);
      expect(await OutOfServiceService.clearByTechnician(n), isFalse, reason: 'без пробного цикла нельзя');
      OutOfServiceService.markTrialPassed();
      expect(await OutOfServiceService.clearByTechnician(n), isTrue);
      expect(n.outOfService, isNull);
      expect(systemCalls, contains('clearOutOfService'));
      n.transition(AppState.standby);
      temps = [32.0];
      expect(await minuteLater(w), isTrue);
      expect(w.failedProbes, 0);
    });
  });

  testWidgets('таймер: первая проба через 60 с, не раньше', (tester) async {
    final n = notifier();
    ThermoIdleWatchService.start(n);
    await tester.pump(const Duration(seconds: 59));
    expect(tempReads, 0);
    now = now.add(const Duration(seconds: 61));
    await tester.pump(const Duration(seconds: 2));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(tempReads, 1, reason: 'годное с первого чтения');
    ThermoIdleWatchService.stop();
  });
}
