import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/bus_map.dart';
import 'package:dry_fog_app/models/out_of_service.dart';
import 'package:dry_fog_app/screens/service/mdb_bench_tab.dart';
import 'package:dry_fog_app/screens/treating.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/card_payment_service.dart';
import 'package:dry_fog_app/services/card_payment_store.dart';
import 'package:dry_fog_app/services/card_terminal_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:dry_fog_app/services/mdb_bench_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/session_service.dart';

// 1.11.2: контроль «нет годного показания» в обработке при выключенном ТЭНе
// (сценарий владельца на CARFOG-100), pre-flight по негодному показанию,
// кадр 10 00 (terminal_reset), ts событий в UTC, нейтральный текст стенда.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const card = MethodChannel('com.carfog.dryfog/card_terminal');
  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  const system = MethodChannel('com.carfog.dryfog/system');
  const storage = MethodChannel('com.carfog.dryfog/storage');

  late List<MethodCall> cardCalls;
  late List<MethodCall> modbusCalls;
  // Показания термопары по очереди; кончились — последнее.
  late List<Object?> temps;
  late bool heaterCoil;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppLog.resetForTest();
    CloudService.resetQueueForTest();
    CloudService.transport = LocalLogTransport();
    CardTerminalService.resetForTest();
    CardPaymentService.resetForTest();
    CardPaymentService.install();
    ModbusService.paymentBlocked = false;
    cardCalls = [];
    modbusCalls = [];
    temps = [25.0];
    heaterCoil = false;
    messenger.setMockMethodCallHandler(card, (c) async {
      cardCalls.add(c);
      if (c.method == 'arm') return c.arguments['cents'];
      return null;
    });
    messenger.setMockMethodCallHandler(modbus, (c) async {
      modbusCalls.add(c);
      switch (c.method) {
        case 'readAllInputs':
          return List.filled(16, false);
        case 'readCoils':
          return List.filled(16, false)..[AuxOutput.heaterDO] = heaterCoil;
        case 'readTemperature':
          return temps.length > 1 ? temps.removeAt(0) : temps.first;
        case 'readEnergy':
          return {'totalEnergy': 1.0, 'power': 0.015};
      }
      return true;
    });
    // Вывод из обслуживания записан на диск с подтверждением — без фонового
    // повтора записи.
    messenger.setMockMethodCallHandler(system, (call) async => call.method == 'writeOutOfService' ? true : null);
    messenger.setMockMethodCallHandler(storage, (call) async => null);
  });
  tearDown(() {
    SessionService.discard();
    for (final c in [card, modbus, system, storage]) {
      messenger.setMockMethodCallHandler(c, null);
    }
  });

  AppNotifier notifier({bool meter = false}) {
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        // без счётчика экран не ждёт мощность по реальному времени; для
        // pre-flight счётчик нужен (без него оплата заблокирована настройкой)
        energyMeterInstalled: meter,
        paymentTerminalType: PaymentTerminalType.mdb,
        flavorPricesCents: [200, 250, 300, 350],
        deviceId: 'CARFOG-T',
      );
    n.setBusHealthy(true);
    n.updateLevels(List.filled(8, true));
    return n;
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  group('сценарий владельца: горячий старт, термопару отключили', () {
    for (final bad in <Object?>[-500.0, null]) {
      testWidgets('≥190 °C → ТЭН выключен на первом тике → $bad → отказ датчика ≈9 с, сбой аппарата', (tester) async {
        tester.view.devicePixelRatio = 1.5;
        tester.view.physicalSize = const Size(1080, 1920);
        addTearDown(tester.view.reset);
        final n = notifier()..setLanguage('ru');
        final t0 = DateTime.now();
        await tester.runAsync(() async {
          await I18n.load();
          await CardPaymentService.arm(notifier: n, cents: 250, flavorIndex: 1, coinsCents: 0);
          await CardPaymentService.handlePaymentEvent({
            'type': 'approved',
            'data': {'units': 250, 'approved_at': t0.millisecondsSinceEpoch},
          });
          await SessionService.start(
            flavorIndex: 1, flavorNameRu: 'Вишня', priceCents: 250, paidCents: 250,
            paymentMethod: 'card', coinsCents: 0, readStartEnergy: false,
          );
          CardPaymentService.attachSession(SessionService.currentSessionId);
        });
        // первый тик — годное 194.9 (термостат выключает ТЭН), дальше обрыв
        temps = [194.9, bad];
        await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
          value: n,
          child: const MaterialApp(home: TreatingScreen()),
        ));
        await settle(tester);

        // тик 3 с: годное, ТЭН выключается
        await tester.pump(const Duration(seconds: 3));
        await settle(tester);
        expect(
            modbusCalls.where((c) =>
                c.method == 'setDO' && c.arguments['channel'] == AuxOutput.heaterDO && c.arguments['value'] == false),
            isNotEmpty,
            reason: 'термостат выключил ТЭН (> 190)');
        // тики 6 и 9 с — по одному плохому: ещё не отказ
        for (var i = 0; i < 2; i++) {
          await tester.pump(const Duration(seconds: 3));
          await settle(tester);
          expect(n.outOfService, isNull, reason: 'плохих подряд: ${i + 1}');
        }
        // тик 12 с — третье плохое подряд (≈9 с после первого): отказ
        await tester.pump(const Duration(seconds: 3));
        for (var i = 0; i < 6; i++) {
          await settle(tester);
        }
        expect(n.outOfService?.code, OutOfServiceCode.tempSensorFault);
        expect(n.state, AppState.error);
        final h = (await tester.runAsync(CloudService.history))!;
        final s = h.lastWhere((e) => e.type == CloudEventType.sessionComplete).data;
        expect(s['completed'], false);
        expect(s['reason'], 'heater_sensor_fault');
        expect(s['subtype'], 'out_of_range');
        final hw = h.where((e) => e.type == CloudEventType.hardwareError).single.data;
        expect(hw['code'], 'heater_sensor_fault');
        expect(hw['heater_on'], false);
        // ТЭН подтверждённо выключен: катушка прочитана выключенной
        expect(modbusCalls.where((c) => c.method == 'readCoils'), isNotEmpty);
        expect(h.where((e) => e.type == CloudEventType.hardwareError && e.data['code'] == 'heater_off_unconfirmed'), isEmpty);
        // оплата картой — как сбой аппарата, не отмена клиентом
        expect(cardCalls.where((c) => c.method == 'clientCancel'), isEmpty);
        expect(cardCalls.where((c) => c.method == 'finish').single.arguments,
            {'success': false, 'reason': 'heater_sensor_fault'});
        // итог автомата (в окне — возврат) обрабатывается как раньше
        await tester.runAsync(() => CardPaymentService.handlePaymentEvent(
            {'type': 'refunded', 'data': {'refund': 'ACK 00', 'cycle_reason': 'heater_sensor_fault'}}));
        expect((await tester.runAsync(CardPaymentStore.history))!.single.status, 'refunded');

        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
      });
    }

    testWidgets('одиночный плохой отсчёт при выключенном ТЭНе не прерывает обработку', (tester) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      final n = notifier()..setLanguage('ru');
      await tester.runAsync(() async {
        await I18n.load();
        await SessionService.start(
          flavorIndex: 1, flavorNameRu: 'Вишня', priceCents: 250, paidCents: 250,
          paymentMethod: 'coins', coinsCents: 250, readStartEnergy: false,
        );
      });
      temps = [194.9, -500.0, 193.0, null, 192.5, -500.0, 192.0];
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: TreatingScreen()),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(seconds: 3));
        await settle(tester);
      }
      expect(n.outOfService, isNull);
      expect(n.state, isNot(AppState.error));
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    });
  });

  group('pre-flight: негодное показание = оплата картой недоступна', () {
    for (final (t, want) in <(Object?, String?)>[
      (25.0, null),
      (194.9, null),
      (null, 'thermocouple'),
      (-500.0, 'thermocouple'),
      (450.0, 'thermocouple'),
      (-150.0, 'thermocouple'),
    ]) {
      test('$t → $want', () async {
        temps = [t];
        expect(await CardPaymentService.preflight(notifier(meter: true), 0), want);
      });
    }
  });

  group('10 00 — terminal_reset', () {
    test('в облако terminal_reset, не неожиданный кадр', () async {
      CardTerminalService.handleEvent(
        {'kind': 'event', 'type': 'terminal_reset', 'data': {'during_payment': false, 'state': 'READY'}},
        'CARFOG-T',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final h = await CloudService.history();
      final e = h.where((e) => e.type == 'terminal_reset').single;
      expect(e.data['during_payment'], false);
      expect(e.data['device_id'], 'CARFOG-T');
      expect(h.where((e) => e.type == 'terminal_unexpected_frame'), isEmpty);
    });
  });

  group('ts событий — UTC с Z', () {
    test('toJson: UTC ISO 8601 с Z, тот же момент', () {
      final local = DateTime(2026, 10, 24, 15, 0, 0);
      final j = CloudEvent(type: 'x', ts: local).toJson();
      final ts = j['ts'] as String;
      expect(ts.endsWith('Z'), isTrue, reason: ts);
      expect(DateTime.parse(ts).isAtSameMomentAs(local), isTrue);
    });

    test('fromJson: новое (Z) и старое (локальное без смещения) — тот же момент, в памяти местное', () {
      final local = DateTime(2026, 10, 24, 15, 0, 0);
      final back = CloudEvent.fromJson(CloudEvent(type: 'x', ts: local).toJson());
      expect(back.ts.isUtc, isFalse);
      expect(back.ts.isAtSameMomentAs(local), isTrue);
      final old = CloudEvent.fromJson({'type': 'x', 'ts': local.toIso8601String(), 'data': <String, dynamic>{}});
      expect(old.ts, local);
      expect((old.toJson()['ts'] as String).endsWith('Z'), isTrue);
    });
  });

  group('стенд: нейтральный текст вместо «исход неизвестен»', () {
    test('статус стенда несёт флаг', () {
      final s = MdbBenchStatus.fromMap({'testOutcome': 'НЕ УДАЛАСЬ — …', 'testVendUnsettled': true});
      expect(s.testVendUnsettled, isTrue);
      expect(MdbBenchStatus.fromMap({}).testVendUnsettled, isFalse);
    });

    for (final (lang, text) in [
      ('ru', 'Терминал не сообщил итог списания'),
      ('en', 'did not report the final charge status'),
      ('et', 'ei teatanud makse lõpptulemust'),
    ]) {
      testWidgets('вкладка стенда показывает строку на языке меню [$lang]', (tester) async {
        const ch = MethodChannel('com.carfog.dryfog/mdb_bench');
        messenger.setMockMethodCallHandler(ch, (c) async => c.method == 'status'
            ? {'testOutcome': 'НЕ УДАЛАСЬ — порт потерян', 'testOutcomeOk': false, 'testVendUnsettled': true}
            : null);
        addTearDown(() => messenger.setMockMethodCallHandler(ch, null));
        final n = notifier()..setLanguage(lang);
        await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
          value: n,
          child: const MaterialApp(home: Scaffold(body: MdbBenchTab())),
        ));
        await settle(tester);
        expect(find.textContaining(text), findsOneWidget);
        expect(find.textContaining('исход неизвестен'), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
      });
    }
  });
}
