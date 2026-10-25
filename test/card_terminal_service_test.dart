import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/card_terminal_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';

// Терминал Nayax в основном потоке (1.11.0, этап 2) — Dart-сторона: когда
// терминал нужен, какие события уходят в облако и как часто.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const card = MethodChannel('com.carfog.dryfog/card_terminal');
  const system = MethodChannel('com.carfog.dryfog/system');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.resetForTest();
    CloudService.resetQueueForTest();
    CloudService.transport = LocalLogTransport();
    CardTerminalService.resetForTest();
    ModbusService.paymentBlocked = false;
    messenger.setMockMethodCallHandler(system, (c) async => null);
  });
  tearDown(() {
    CardTerminalService.stop();
    messenger.setMockMethodCallHandler(card, null);
    messenger.setMockMethodCallHandler(system, null);
  });

  AppNotifier notifier(String type) => AppNotifier()
    ..config = AppConfig(
      thermoInstalled: true,
      energyMeterInstalled: true,
      paymentTerminalType: type,
      deviceId: 'CARFOG-T',
    );

  group('нужен ли терминал', () {
    test('mdb и аппарат исправен — терминал и приём карт', () {
      final d = CardTerminalService.desiredFor(notifier(PaymentTerminalType.mdb));
      expect(d.active, isTrue);
      expect(d.enabled, isTrue);
    });

    test('pulse или off — терминал не нужен', () {
      for (final t in [PaymentTerminalType.pulse, PaymentTerminalType.off]) {
        final d = CardTerminalService.desiredFor(notifier(t));
        expect(d.active, isFalse, reason: t);
        expect(d.enabled, isFalse, reason: t);
      }
    });

    test('обслуживание или блок конфигурации — терминал на связи, приём выключен', () {
      final n = notifier(PaymentTerminalType.mdb)..setMaintenance(true);
      final d = CardTerminalService.desiredFor(n);
      expect(d.active, isTrue);
      expect(d.enabled, isFalse);
      final blocked = AppNotifier()
        ..config = AppConfig(paymentTerminalType: PaymentTerminalType.mdb);
      expect(blocked.isConfigBlocked, isTrue);
      expect(CardTerminalService.desiredFor(blocked).enabled, isFalse);
    });
  });

  group('события', () {
    Future<List<String>> cloudTypes() async =>
        (await CloudService.history()).map((e) => e.type).toList();

    test('terminal_offline / terminal_recovered — в облако с номером аппарата', () async {
      CardTerminalService.handleEvent(
        {'kind': 'event', 'type': 'terminal_offline', 'data': {'reason': 'no_answer'}},
        'CARFOG-T',
      );
      CardTerminalService.handleEvent(
        {'kind': 'event', 'type': 'terminal_recovered', 'data': <String, dynamic>{}},
        'CARFOG-T',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final events = await CloudService.history();
      expect(events.map((e) => e.type), ['terminal_offline', 'terminal_recovered']);
      expect(events.first.data['reason'], 'no_answer');
      expect(events.first.data['device_id'], 'CARFOG-T');
    });

    test('неожиданные кадры — в облако не чаще раза в 10 минут, со счётчиком', () async {
      final t0 = DateTime(2026, 10, 22, 12);
      void frame(DateTime at) => CardTerminalService.handleEvent(
        {'kind': 'event', 'type': 'terminal_unexpected_frame', 'data': {'reason': 'код 09'}},
        'CARFOG-T',
        now: at,
      );
      frame(t0);
      frame(t0.add(const Duration(minutes: 1)));
      frame(t0.add(const Duration(minutes: 5)));
      frame(t0.add(const Duration(minutes: 10)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final events = (await CloudService.history())
          .where((e) => e.type == 'terminal_unexpected_frame')
          .toList();
      expect(events.length, 2);
      expect(events[0].data['count'], 1);
      expect(events[1].data['count'], 3, reason: 'три кадра с прошлого отчёта');
    });

    test('обрывки кадров (1.11.5): сводное terminal_frame_fragments как пришло, без счётчика неожиданных', () async {
      final t0 = DateTime(2026, 10, 25, 12);
      CardTerminalService.handleEvent(
        {'kind': 'event', 'type': 'terminal_frame_fragments', 'data': {'count': 2, 'total': 5, 'last_reason': 'кадр 78… не из паспорта'}},
        'CARFOG-T',
        now: t0,
      );
      // неожиданный кадр сразу после — отчёт идёт как обычно (count 1): обрывки его не копят
      CardTerminalService.handleEvent(
        {'kind': 'event', 'type': 'terminal_unexpected_frame', 'data': {'reason': 'код 09'}},
        'CARFOG-T',
        now: t0.add(const Duration(seconds: 1)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final h = await CloudService.history();
      final f = h.where((e) => e.type == 'terminal_frame_fragments').single;
      expect(f.data['count'], 2);
      expect(f.data['total'], 5);
      expect(f.data['last_reason'], 'кадр 78… не из паспорта');
      expect(f.data['device_id'], 'CARFOG-T');
      expect(h.where((e) => e.type == 'terminal_unexpected_frame').single.data['count'], 1);
      expect(CardTerminalService.recent.value.last, contains('terminal_unexpected_frame'));
    });

    test('карта без выбранного запаха — подсказка экрану, в облако не уходит', () async {
      final at = DateTime(2026, 10, 22, 12, 30);
      CardTerminalService.handleEvent(
        {'kind': 'event', 'type': 'card_tapped_without_flavor', 'data': {'funds': 1000}},
        'CARFOG-T',
        now: at,
      );
      expect(CardTerminalService.tappedWithoutFlavorAt.value, at);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await cloudTypes(), isEmpty);
    });

    test('строки журнала Kotlin — в журнал приложения, не в облако', () async {
      CardTerminalService.handleEvent({'kind': 'log', 'text': 'терминал готов'}, 'CARFOG-T');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(await cloudTypes(), isEmpty);
    });
  });

  test('опрос: configure один раз на смену состояния, статус и события из poll', () async {
    final calls = <MethodCall>[];
    var pollEvents = <Map<String, dynamic>>[
      {'kind': 'event', 'type': 'terminal_offline', 'data': {'reason': 'no_device'}},
    ];
    messenger.setMockMethodCallHandler(card, (c) async {
      calls.add(c);
      if (c.method == 'poll') {
        final ev = pollEvents;
        pollEvents = [];
        return {'state': 'NO_DEVICE', 'stateTitle': 'адаптер не найден', 'cardAvailable': false, 'events': ev};
      }
      return null;
    });
    final n = notifier(PaymentTerminalType.mdb);
    CardTerminalService.start(n);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls.where((c) => c.method == 'configure').length, 1);
    expect(calls.first.arguments, {'active': true, 'desiredEnabled': true});
    expect(CardTerminalService.status.value.state, 'NO_DEVICE');
    expect((await CloudService.history()).map((e) => e.type), contains('terminal_offline'));

    // Смена: обслуживание → приём выключить.
    n.setMaintenance(true);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final configures = calls.where((c) => c.method == 'configure').toList();
    expect(configures.length, 2);
    expect(configures.last.arguments, {'active': true, 'desiredEnabled': false});
    CardTerminalService.stop();
  });

  test('терминал не mdb — Kotlin не трогается вовсе', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(card, (c) async {
      calls.add(c);
      return null;
    });
    CardTerminalService.start(notifier(PaymentTerminalType.off));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(calls, isEmpty);
    CardTerminalService.stop();
  });
}
