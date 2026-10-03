import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/bus_map.dart';
import 'package:dry_fog_app/models/out_of_service.dart';
import 'package:dry_fog_app/screens/payment.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/cycle_energy_service.dart';
import 'package:dry_fog_app/services/heater_shutdown_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/output_watchdog_service.dart';
import 'package:dry_fog_app/services/session_service.dart';

// Доработка после проверки коммита 73acfe3: выключение ТЭНа по счётчику,
// блок оплаты по конфигурации, сторож (залипший выход), троттлинг событий,
// повторная оплата, энергия сессии по интегралу мощности.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  const system = MethodChannel('com.carfog.dryfog/system');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  AppNotifier readyNotifier() => AppNotifier()
    ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: true);

  List<bool> coils({required bool heater}) =>
      List.generate(12, (i) => i == AuxOutput.heaterDO ? heater : false);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ModbusService.paymentBlocked = false;
    messenger.setMockMethodCallHandler(system, (c) async {
      if (c.method == 'writeOutOfService') return true;
      if (c.method == 'clearOutOfService') return true;
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(modbus, null);
    messenger.setMockMethodCallHandler(system, null);
    ModbusService.paymentBlocked = false;
    OutputWatchdogService.stop();
  });

  // ---------------------------------------------------------------- п.1
  group('подтверждение выключения ТЭНа по счётчику', () {
    Future<HeaterOffResult> run({
      required bool coil,
      required bool meter,
      required List<double?> power,
    }) {
      var i = 0;
      return HeaterShutdownService.confirmOff(
        meterInstalled: meter,
        forceOff: () async => coil,
        readPowerW: () async => power[(i++).clamp(0, power.length - 1)],
        window: const Duration(milliseconds: 60),
        poll: const Duration(milliseconds: 10),
      );
    }

    test('катушка выключена, мощность 1400 Вт → НЕ подтверждено', () async {
      final r = await run(coil: true, meter: true, power: [1400]);
      expect(r.confirmed, isFalse);
      expect(r.confirmedBy, 'coil_only_power_high');
      expect(r.powerCheck, 'high');
      expect(r.powerW, 1400);
    });

    test('катушка выключена, мощность упала → подтверждено', () async {
      final r = await run(coil: true, meter: true, power: [1400, 900, 20]);
      expect(r.confirmed, isTrue);
      expect(r.confirmedBy, 'coil_and_power');
    });

    test('счётчик не установлен → по катушке, power_check: skipped', () async {
      final r = await run(coil: true, meter: false, power: [1400]);
      expect(r.confirmed, isTrue);
      expect(r.powerCheck, 'skipped');
    });

    test('катушка не выключилась → не подтверждено, мощность не смотрим', () async {
      final r = await run(coil: false, meter: true, power: [10]);
      expect(r.confirmed, isFalse);
      expect(r.confirmedBy, 'coil_unconfirmed');
    });

    test('счётчик не отвечает → fail-closed', () async {
      final r = await run(coil: true, meter: true, power: [null]);
      expect(r.confirmed, isFalse);
      expect(r.powerCheck, 'unreadable');
    });

    test('порог между холостым ходом с нагрузками и ТЭНом', () {
      expect(
        HeaterThresholds.heaterOffPowerMaxW,
        greaterThan(PowerSignature.idleW +
            PowerSignature.compressorDeltaW +
            PowerSignature.pumpDeltaW),
      );
      expect(HeaterThresholds.heaterOffPowerMaxW,
          lessThan(PowerSignature.heaterW));
    });

    test('ensureOff: мощность высокая → событие с confirmed_by и вывод из обслуживания',
        () async {
      messenger.setMockMethodCallHandler(modbus, (c) async {
        switch (c.method) {
          case 'setDO':
          case 'safeAllOff':
            return true;
          case 'readCoils':
            return coils(heater: false);
          case 'readEnergy':
            return {'voltage': 230.0, 'current': 6.0, 'power': 1.4, 'totalEnergy': 1.0};
        }
        return null;
      });
      final notifier = readyNotifier();
      final ok = await HeaterShutdownService.ensureOff('test', notifier: notifier);
      expect(ok, isFalse);
      expect(notifier.outOfService?.code, OutOfServiceCode.heaterOffUnconfirmed);
      expect(notifier.outOfService?.details['confirmed_by'], 'coil_only_power_high');
      final events = await CloudService.history();
      final e = events.lastWhere((e) => e.type == CloudEventType.hardwareError);
      expect(e.data['code'], 'heater_off_unconfirmed');
      expect(e.data['confirmed_by'], 'coil_only_power_high');
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  // ---------------------------------------------------------------- п.2
  test('причина overheat и output_stuck_on сохраняются и читаются', () {
    for (final code in [OutOfServiceCode.overheat, OutOfServiceCode.outputStuckOn]) {
      final s = OutOfServiceState(code: code, since: DateTime(2026, 10, 2));
      expect(OutOfServiceState.tryParse(s.toJson())?.code, code);
    }
  });

  // ---------------------------------------------------------------- п.3
  group('обязательные устройства', () {
    test('без термопары/счётчика оплата заблокирована, постоянного признака нет', () {
      final n = AppNotifier();
      expect(n.isConfigBlocked, isTrue);
      expect(n.missingRequiredDevices, ['thermocouple', 'energy_meter']);
      n.selectFlavor(0);
      expect(n.state, AppState.outOfService);
      expect(n.isOutOfService, isFalse); // не отказ, в хранилище не пишется
      expect(ModbusService.paymentBlocked, isTrue);
      expect(n.selectedFlavor, isNull);
    });

    test('после включения флагов блок пропадает и аппарат возвращается в ожидание',
        () async {
      final n = AppNotifier();
      n.selectFlavor(0);
      expect(n.state, AppState.outOfService);
      await n.saveConfig(
        n.config.copyWith(thermoInstalled: true, energyMeterInstalled: true),
      );
      expect(n.isConfigBlocked, isFalse);
      expect(ModbusService.paymentBlocked, isFalse);
      expect(n.state, AppState.standby);
    });

    test('только термопара — всё равно заблокировано (нужен и счётчик)', () {
      final n = AppNotifier()..config = AppConfig(thermoInstalled: true);
      expect(n.missingRequiredDevices, ['energy_meter']);
    });

    test('сервисное меню остаётся доступным', () {
      final n = AppNotifier();
      n.transition(AppState.servicePinEntry);
      expect(n.state, AppState.servicePinEntry);
    });

    test('при готовых устройствах выбор аромата идёт на оплату', () {
      final n = readyNotifier()..setBusHealthy(true);
      n.selectFlavor(0);
      expect(n.state, AppState.payment);
    });
  });

  // ---------------------------------------------------------------- п.4
  group('сторож выходов', () {
    test('выход остаётся включённым после safeAllOff → вывод output_stuck_on',
        () async {
      messenger.setMockMethodCallHandler(modbus, (c) async {
        if (c.method == 'readCoils') return coils(heater: true);
        return true;
      });
      final n = readyNotifier()..transition(AppState.standby);
      OutputWatchdogService.start(n);
      for (var i = 0; i < 50 && !n.isOutOfService; i++) {
        await Future.delayed(const Duration(milliseconds: 20));
      }
      expect(n.outOfService?.code, OutOfServiceCode.outputStuckOn);
      expect(n.outOfService?.details['channel'], AuxOutput.heaterDO);
    });

    test('safeAllOff помог → событие, но без вывода из обслуживания', () async {
      var off = false;
      messenger.setMockMethodCallHandler(modbus, (c) async {
        if (c.method == 'safeAllOff') {
          off = true;
          return true;
        }
        if (c.method == 'readCoils') return coils(heater: !off);
        return true;
      });
      final n = readyNotifier()..transition(AppState.standby);
      OutputWatchdogService.start(n);
      await Future.delayed(const Duration(milliseconds: 300));
      expect(n.isOutOfService, isFalse);
      final events = await CloudService.history();
      expect(
        events.where((e) => e.data['code'] == 'unexpected_output_on' &&
            e.data['confirmed_off'] == true),
        isNotEmpty,
      );
    });

    test('сторож включён по умолчанию', () {
      expect(AppConfig().outputWatchdogEnabled, isTrue);
    });

    test('EventThrottle: тот же ключ — не чаще интервала, другой — сразу', () {
      final t = EventThrottle(const Duration(seconds: 60));
      final t0 = DateTime(2026, 10, 2, 12);
      expect(t.allow('9:false', t0), isTrue);
      expect(t.allow('9:false', t0.add(const Duration(seconds: 3))), isFalse);
      expect(t.allow('8:false', t0.add(const Duration(seconds: 3))), isTrue);
      expect(t.allow('9:false', t0.add(const Duration(seconds: 61))), isTrue);
    });
  });

  // ---------------------------------------------------------------- п.6
  group('энергия сессии', () {
    test('energy_wh — интеграл мощности, energy_wh_counter — разность регистра',
        () async {
      messenger.setMockMethodCallHandler(modbus, (c) async {
        if (c.method == 'readEnergy') {
          return {'voltage': 230.0, 'current': 6.5, 'power': 1.5, 'totalEnergy': 5.0};
        }
        return null;
      });
      await SessionService.start(
        flavorIndex: 0,
        flavorNameRu: 'Лимон',
        priceCents: 200,
        paidCents: 200,
        paymentMethod: 'card',
      );
      expect(SessionService.currentSessionId, isNotNull);
      final id = SessionService.currentSessionId;
      await CycleEnergyService.beginCycle();
      await Future.delayed(const Duration(milliseconds: 2300));
      await SessionService.complete();
      final e = (await CloudService.history())
          .lastWhere((e) => e.type == CloudEventType.sessionComplete);
      // 1500 Вт × ~2.3 с ≈ 0.96 Вт·ч; регистр не изменился (шаг 10 Вт·ч)
      expect(e.data['session_id'], id);
      expect(e.data['energy_wh'], closeTo(0.96, 0.25));
      expect(e.data['energy_wh_counter'], 0.0);
      expect(e.data.containsKey('cycle_energy_wh'), isFalse);
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  // ---------------------------------------------------------------- п.5
  testWidgets('монета после защёлки не теряется: duplicate_payment с session_id',
      (tester) async {
    var statusCalls = 0;
    messenger.setMockMethodCallHandler(modbus, (c) async {
      switch (c.method) {
        case 'getCoinAcceptorStatus':
          statusCalls++;
          // первая выдача — 2 €, хватает на цикл; вторая (добор после
          // защёлки) — ещё 1 €
          if (statusCalls == 1) return {'cents': 200, 'failureCount': 0, 'down': false};
          if (statusCalls == 2) return {'cents': 100, 'failureCount': 0, 'down': false};
          return {'cents': 0, 'failureCount': 0, 'down': false};
        case 'readEnergy':
          return null;
      }
      return true;
    });
    final n = readyNotifier()..transition(AppState.payment);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: n,
        child: const MaterialApp(home: PaymentScreen()),
      ),
    );
    // Фейковое время виджета и реальное время SharedPreferences чередуем:
    // иначе запись события в хранилище не завершается.
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(n.state, AppState.preparing);
    final dup = (await tester.runAsync(() async {
      return (await CloudService.history())
          .where((e) => e.type == CloudEventType.duplicatePayment)
          .toList();
    }))!;
    expect(dup, isNotEmpty);
    expect(dup.first.data['cents'], 100);
    expect(dup.first.data['method'], 'coins');
    expect(dup.first.data['session_id'], isNotNull);
    expect(dup.first.data['first_method'], 'coins');
    SessionService.discard();
  }, timeout: const Timeout(Duration(seconds: 40)));
}
