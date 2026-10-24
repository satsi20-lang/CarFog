import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/screens/payment.dart';
import 'package:dry_fog_app/screens/service/service_menu.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/card_payment_service.dart';
import 'package:dry_fog_app/services/card_terminal_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/session_service.dart';

// 1.11.3: pre-flight оплаты картой — до 3 свежих чтений подряд с паузой
// ~300 мс для термопары, модуля ввода-вывода и счётчика; «недоступно» только
// если все 3 негодны. Событие card_preflight: attempts, readings,
// last_usable_c / last_usable_age_s. Часы и паузы — подставные.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const card = MethodChannel('com.carfog.dryfog/card_terminal');
  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  const system = MethodChannel('com.carfog.dryfog/system');
  const storage = MethodChannel('com.carfog.dryfog/storage');

  // Ответы по очереди; 'throw' — ошибка нативной стороны (PlatformException).
  late List<Object?> temps;
  late List<Object?> inputs;
  late List<Object?> energies;
  late Map<String, int> reads;
  late List<Duration> pauses;
  late DateTime now;
  const readMs = 40; // «длительность» одного чтения на подставных часах
  const good16 = <bool>[
    false, false, false, false, false, false, false, false,
    false, false, false, false, false, false, false, false,
  ];

  Object? next(List<Object?> q) => q.length > 1 ? q.removeAt(0) : q.first;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.resetForTest();
    CloudService.resetQueueForTest();
    CloudService.transport = LocalLogTransport();
    CardTerminalService.resetForTest();
    CardPaymentService.resetForTest();
    CardPaymentService.install();
    ModbusService.resetLastReadsForTest();
    ModbusService.paymentBlocked = false;
    now = DateTime(2026, 10, 24, 15, 31, 37);
    ModbusService.clock = () => now;
    pauses = [];
    CardPaymentService.preflightPause = (d) async {
      pauses.add(d);
      now = now.add(d);
    };
    temps = [32.0];
    inputs = [good16];
    energies = [
      {'totalEnergy': 1.0, 'power': 0.015},
    ];
    reads = {};
    messenger.setMockMethodCallHandler(modbus, (c) async {
      Object? answer(List<Object?> q) {
        reads[c.method] = (reads[c.method] ?? 0) + 1;
        now = now.add(const Duration(milliseconds: readMs));
        final v = next(q);
        if (v == 'throw') throw PlatformException(code: 'MODBUS', message: '${c.method} failed');
        return v;
      }

      switch (c.method) {
        case 'readTemperature':
          return answer(temps);
        case 'readAllInputs':
          return answer(inputs);
        case 'readEnergy':
          return answer(energies);
        case 'getCoinAcceptorStatus':
          return {'cents': 0, 'failureCount': 0, 'down': false};
      }
      return true;
    });
    messenger.setMockMethodCallHandler(card, (c) async {
      if (c.method == 'arm') return c.arguments['cents'];
      return null;
    });
    for (final c in [system, storage]) {
      messenger.setMockMethodCallHandler(c, (call) async => null);
    }
  });
  tearDown(() {
    SessionService.discard();
    ModbusService.resetLastReadsForTest();
    for (final c in [card, modbus, system, storage]) {
      messenger.setMockMethodCallHandler(c, null);
    }
  });

  AppNotifier notifier({bool dio = true, bool thermo = true, bool meter = true}) {
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: thermo,
        energyMeterInstalled: meter,
        dioInstalled: dio,
        paymentTerminalType: PaymentTerminalType.mdb,
        flavorPricesCents: [200, 250, 300, 350],
        deviceId: 'CARFOG-T',
      );
    n.setBusHealthy(true);
    n.updateLevels(List.filled(8, true));
    return n;
  }

  group('термопара', () {
    for (final (seq, want, n) in <(List<Object?>, String?, int)>[
      ([null, 32.0], null, 2),
      ([null, null, 32.0], null, 3),
      ([-500.0, 32.0], null, 2),
      (['throw', 32.0], null, 2),
      ([450.0, 32.0], null, 2),
      ([32.0], null, 1),
      ([-500.0, -500.0, -500.0], 'thermocouple', 3),
      ([null, null, null], 'thermocouple', 3),
      ([450.0, 450.0, 450.0], 'thermocouple', 3),
      (['throw', 'throw', 'throw', 32.0], 'thermocouple', 3),
    ]) {
      test('$seq → ${want ?? 'проходит'}, чтений: $n', () async {
        temps = [...seq];
        final r = await CardPaymentService.preflightDetailed(notifier(), 0);
        expect(r.reason, want);
        expect(reads['readTemperature'], n);
        expect(pauses.length, n - 1, reason: 'пауза между чтениями, не перед первым');
        for (final p in pauses) {
          expect(p, CardPaymentService.preflightRetryPause);
        }
      });
    }

    test('обрыв −500 каждый раз: больше 3 чтений никогда', () async {
      temps = [-500.0];
      expect(await CardPaymentService.preflight(notifier(), 0), 'thermocouple');
      expect(reads['readTemperature'], 3);
    });

    test('термопара не установлена — ни одного чтения', () async {
      temps = [-500.0];
      // без термопары оплата и так закрыта настройкой (isConfigBlocked)
      expect(await CardPaymentService.preflight(notifier(thermo: false), 0), 'payment_blocked');
      expect(reads['readTemperature'], isNull);
    });

    test('пауза ≈300 мс', () {
      expect(CardPaymentService.preflightRetryPause, const Duration(milliseconds: 300));
      expect(CardPaymentService.preflightAttempts, 3);
    });
  });

  group('модуль ввода-вывода', () {
    for (final (seq, want, n) in <(List<Object?>, String?, int)>[
      ([null, good16], null, 2),
      ([null, null, good16], null, 3),
      (['throw', good16], null, 2),
      ([null, null, null], 'io_module', 3),
      (['throw', 'throw', 'throw'], 'io_module', 3),
    ]) {
      test('$seq → ${want ?? 'проходит'}, чтений: $n', () async {
        inputs = [...seq];
        final r = await CardPaymentService.preflightDetailed(notifier(), 0);
        expect(r.reason, want);
        expect(reads['readAllInputs'], n);
        expect(pauses.length, n - 1);
      });
    }

    test('не установлен — ни одного чтения', () async {
      inputs = [null];
      expect(await CardPaymentService.preflight(notifier(dio: false), 0), isNull);
      expect(reads['readAllInputs'], isNull);
    });
  });

  group('счётчик энергии', () {
    final ok = {'totalEnergy': 1.0, 'power': 0.015};
    for (final (seq, want, n) in <(List<Object?>, String?, int)>[
      ([null, ok], null, 2),
      ([null, null, ok], null, 3),
      (['throw', ok], null, 2),
      ([null, null, null], 'energy_meter', 3),
      (['throw', 'throw', 'throw'], 'energy_meter', 3),
    ]) {
      test('$seq → ${want ?? 'проходит'}, чтений: $n', () async {
        energies = [...seq];
        final r = await CardPaymentService.preflightDetailed(notifier(), 0);
        expect(r.reason, want);
        expect(reads['readEnergy'], n);
        expect(pauses.length, n - 1);
      });
    }

    test('не установлен — ни одного чтения', () async {
      energies = [null];
      // без счётчика оплата и так закрыта настройкой (isConfigBlocked)
      expect(await CardPaymentService.preflight(notifier(meter: false), 0), 'payment_blocked');
      expect(reads['readEnergy'], isNull);
    });
  });

  group('подробности для события card_preflight', () {
    test('термопара: attempts, readings со значениями и null, без прошлого годного', () async {
      temps = [-500.0, null, 'throw'];
      final r = await CardPaymentService.preflightDetailed(notifier(), 0);
      expect(r.reason, 'thermocouple');
      expect(r.details['attempts'], 3);
      expect(r.details['readings'], [
        {'value': -500.0, 'error': 'out_of_range', 'ms': readMs},
        {'value': null, 'error': 'read_failed', 'ms': readMs},
        {'value': null, 'error': 'read_failed', 'ms': readMs},
      ]);
      expect(r.details.containsKey('last_usable_c'), isTrue);
      expect(r.details['last_usable_c'], isNull, reason: 'с запуска годного не было');
      expect(r.details['last_usable_age_s'], isNull);
    });

    test('термопара: последнее годное из любого места приложения и его возраст', () async {
      temps = [31.8];
      await ModbusService.readTemperature(); // например, вкладка «Диагностика»
      now = now.add(const Duration(seconds: 25));
      temps = [450.0];
      final r = await CardPaymentService.preflightDetailed(notifier(), 0);
      expect(r.details['last_usable_c'], 31.8);
      // 25 с + 3 чтения по 40 мс + 2 паузы по 300 мс
      expect(r.details['last_usable_age_s'], 25);
      expect((r.details['readings'] as List).first, {'value': 450.0, 'error': 'out_of_range', 'ms': readMs});
    });

    test('негодное показание последним годным не становится', () async {
      temps = [-500.0];
      await ModbusService.readTemperature();
      expect(ModbusService.lastUsableTemperature, isNull);
    });

    test('модуль ввода-вывода: no_plugin, возраст последнего успешного чтения', () async {
      await ModbusService.readAllInputs(); // опрос уровней прошёл
      now = now.add(const Duration(seconds: 7));
      messenger.setMockMethodCallHandler(modbus, null); // нет нативной части
      final r = await CardPaymentService.preflightDetailed(notifier(), 0);
      expect(r.reason, 'io_module');
      expect(r.details['attempts'], 3);
      expect((r.details['readings'] as List).map((e) => e['error']), ['no_plugin', 'no_plugin', 'no_plugin']);
      expect((r.details['readings'] as List).map((e) => e['value']), [null, null, null]);
      expect(r.details['last_usable_age_s'], 7);
      expect(r.details.containsKey('last_usable_c'), isFalse);
    });

    test('счётчик: read_failed, без прошлого успешного чтения', () async {
      energies = [null];
      final r = await CardPaymentService.preflightDetailed(notifier(), 0);
      expect(r.reason, 'energy_meter');
      expect(r.details['attempts'], 3);
      expect((r.details['readings'] as List).map((e) => e['error']), ['read_failed', 'read_failed', 'read_failed']);
      expect(r.details['last_usable_age_s'], isNull);
    });

    test('проверка прошла — подробностей нет', () async {
      temps = [null, 32.0];
      final r = await CardPaymentService.preflightDetailed(notifier(), 0);
      expect(r.reason, isNull);
      expect(r.details, isEmpty);
    });
  });

  group('экран оплаты', () {
    Future<AppNotifier> pumpPayment(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      await tester.runAsync(I18n.load);
      CardTerminalService.status.value = const CardTerminalStatus(
        state: 'READY',
        cardAvailable: true,
        readerEnabled: true,
      );
      final n = notifier()..setLanguage('ru');
      n.selectFlavor(1);
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: PaymentScreen()),
      ));
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      return n;
    }

    Future<void> disposeScreen(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    }

    testWidgets('одно плохое чтение термопары — «Приложите карту»', (tester) async {
      temps = [-500.0, 32.0];
      await pumpPayment(tester);
      expect(find.text('Приложите карту'), findsOneWidget);
      expect(find.text('Аппарат временно недоступен'), findsNothing);
      final hw = (await tester.runAsync(CloudService.history))!
          .where((e) => e.type == CloudEventType.hardwareError);
      expect(hw, isEmpty);
      await disposeScreen(tester);
    });

    testWidgets('три плохих — «Аппарат временно недоступен», событие с attempts и readings', (tester) async {
      temps = [null, -500.0, 450.0];
      await pumpPayment(tester);
      expect(find.text('Аппарат временно недоступен'), findsOneWidget);
      expect(reads['readTemperature'], 3);
      final hw = (await tester.runAsync(CloudService.history))!
          .where((e) => e.type == CloudEventType.hardwareError)
          .single
          .data;
      expect(hw['code'], 'card_preflight');
      expect(hw['reason'], 'thermocouple');
      expect(hw['attempts'], 3);
      expect((hw['readings'] as List).map((e) => e['value']), [null, -500.0, 450.0]);
      expect(hw.containsKey('last_usable_c'), isTrue);
      expect(hw.containsKey('last_usable_age_s'), isTrue);
      await disposeScreen(tester);
    });
  });

  group('вкладка «Датчики»: нумерация', () {
    for (final (lang, tab, sensor, di) in [
      ('ru', 'Датчики', 'Датчик', 'Канал DI (с 0)'),
      ('en', 'Sensors', 'Sensor', 'DI channel (from 0)'),
      ('et', 'Andurid', 'Andur', 'DI kanal (alates 0)'),
    ]) {
      testWidgets('[$lang] $sensor 1…8, без 0; у канала DI — подпись', (tester) async {
        tester.view.devicePixelRatio = 1.5;
        tester.view.physicalSize = const Size(1080, 1920);
        addTearDown(tester.view.reset);
        final n = AppNotifier()
          ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: true, servicePin: '7351');
        n.setLanguage(lang);
        await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
          value: n,
          child: const MaterialApp(home: ServiceMenuScreen()),
        ));
        await tester.pump(const Duration(milliseconds: 600));
        final dlg = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton));
        if (dlg.evaluate().isNotEmpty) {
          await tester.tap(dlg.last);
          await tester.pump(const Duration(milliseconds: 600));
        }
        await tester.ensureVisible(find.text(tab));
        await tester.tap(find.text(tab));
        await tester.pump(const Duration(milliseconds: 600));
        for (var i = 1; i <= 8; i++) {
          expect(find.text('$sensor $i'), findsOneWidget, reason: '$sensor $i');
        }
        expect(find.text('$sensor 0'), findsNothing);
        expect(find.text(di), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
      });
    }
  });
}
