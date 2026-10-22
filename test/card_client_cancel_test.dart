import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/screens/preparing.dart';
import 'package:dry_fog_app/screens/treating.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/card_payment_service.dart';
import 'package:dry_fog_app/services/card_payment_store.dart';
import 'package:dry_fog_app/services/card_terminal_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/session_service.dart';

// Отмена клиентом при оплате картой (1.11.1, ТЗ раздел 15): возврат только в
// прогреве и в окне 30 с с 10 05; после прогрева или после окна — услуга
// оказана (13 02), событие payment_client_cancelled_no_refund, без ручного
// возврата. Сбои аппарата — по-прежнему (finish → окно или ручной возврат).
// Автомат MDB — в Kotlin (MdbCardPaymentTest); здесь его события подаются
// напрямую.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const card = MethodChannel('com.carfog.dryfog/card_terminal');
  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  const system = MethodChannel('com.carfog.dryfog/system');
  const storage = MethodChannel('com.carfog.dryfog/storage');

  // 10 05 по часам автомата.
  final t0 = DateTime(2026, 10, 22, 14, 5);
  late List<MethodCall> cardCalls;
  late Object? temperature;

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
    temperature = 25.0;
    messenger.setMockMethodCallHandler(card, (c) async {
      cardCalls.add(c);
      if (c.method == 'arm') return c.arguments['cents'];
      return null;
    });
    messenger.setMockMethodCallHandler(modbus, (c) async {
      switch (c.method) {
        case 'readAllInputs':
        case 'readCoils':
          return List.filled(16, false);
        case 'readTemperature':
          return temperature;
        case 'readEnergy':
          return {'totalEnergy': 1.0, 'power': 0.015};
      }
      return true;
    });
    for (final c in [system, storage]) {
      messenger.setMockMethodCallHandler(c, (call) async => null);
    }
  });
  tearDown(() {
    SessionService.discard();
    for (final c in [card, modbus, system, storage]) {
      messenger.setMockMethodCallHandler(c, null);
    }
  });

  AppNotifier notifier() {
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        // без счётчика прогрев не ждёт мощность по реальному времени
        energyMeterInstalled: false,
        paymentTerminalType: PaymentTerminalType.mdb,
        flavorPricesCents: [200, 250, 300, 350],
        deviceId: 'CARFOG-T',
      );
    n.setBusHealthy(true);
    n.updateLevels(List.filled(8, true));
    return n;
  }

  Future<List<CloudEvent>> cloud() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return CloudService.history();
  }

  Future<List<String>> cloudTypes() async => (await cloud()).map((e) => e.type).toList();

  Iterable<MethodCall> calls(String m) => cardCalls.where((c) => c.method == m);

  // Карта одобрена на 2,50 € (запах 2), сессия цикла создана.
  Future<String> approvedSession(AppNotifier n, {bool card = true}) async {
    if (card) {
      await CardPaymentService.arm(notifier: n, cents: 250, flavorIndex: 1, coinsCents: 0);
      await CardPaymentService.handlePaymentEvent({
        'type': 'approved',
        'data': {'units': 250, 'approved_at': t0.millisecondsSinceEpoch},
      }, now: t0);
    }
    await SessionService.start(
      flavorIndex: 1,
      flavorNameRu: 'Вишня',
      priceCents: 250,
      paidCents: 250,
      paymentMethod: card ? 'card' : 'coins',
      coinsCents: card ? 0 : 250,
      readStartEnergy: false,
    );
    final sid = SessionService.currentSessionId!;
    if (card) CardPaymentService.attachSession(sid);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return sid;
  }

  void at(Duration sinceApproval) => CardPaymentService.clock = () => t0.add(sinceApproval);

  group('правило возврата при отмене клиентом', () {
    bool rule(String stage, int ms) =>
        CardPaymentService.refundOnClientCancel(stage: stage, elapsedMs: ms, refundWindowS: 30);

    test('прогрев: в окне — возврат, ровно на границе и после — нет', () {
      expect(rule('preheat', 0), isTrue);
      expect(rule('preheat', 29_999), isTrue);
      expect(rule('preheat', 30_000), isFalse);
      expect(rule('preheat', 30_001), isFalse);
      expect(rule('preheat', -1), isFalse, reason: 'часы ушли назад — без возврата');
    });

    test('после прогрева — никогда, даже на 1-й секунде', () {
      for (final s in ['compressor', 'treating', 'purge', '']) {
        expect(rule(s, 1000), isFalse, reason: s);
      }
    });

    test('без карты (монеты) — решения нет, экран ведёт себя как раньше', () async {
      await approvedSession(notifier(), card: false);
      expect(CardPaymentService.quoteClientCancel('preheat'), isNull);
    });

    test('карта ещё не одобрена — решения нет', () async {
      await CardPaymentService.arm(notifier: notifier(), cents: 250, flavorIndex: 1, coinsCents: 0);
      expect(CardPaymentService.quoteClientCancel('preheat'), isNull);
    });

    test('окно считается от 10 05 автомата (approved_at), а не от опроса', () async {
      await approvedSession(notifier());
      at(const Duration(seconds: 29, milliseconds: 999));
      final q = CardPaymentService.quoteClientCancel('preheat')!;
      expect(q.refund, isTrue);
      expect(q.elapsedS, 29);
      at(const Duration(seconds: 30));
      expect(CardPaymentService.quoteClientCancel('preheat')!.refund, isFalse);
    });
  });

  group('отмена после прогрева: без возврата, услуга оказана', () {
    test('решение → запись на диске → терминалу clientCancel(refund: false)', () async {
      await approvedSession(notifier());
      at(const Duration(seconds: 10));
      CardPaymentRecord? onDiskWhenSent;
      messenger.setMockMethodCallHandler(card, (c) async {
        cardCalls.add(c);
        if (c.method == 'clientCancel') onDiskWhenSent = await CardPaymentStore.pending();
        return null;
      });
      await CardPaymentService.clientCancel(CardPaymentService.quoteClientCancel('compressor')!);
      expect(calls('clientCancel').single.arguments, {'stage': 'compressor', 'refund': false});
      expect(onDiskWhenSent!.clientCancel, containsPair('refund', false));
      expect(onDiskWhenSent!.clientCancel, containsPair('stage', 'compressor'));
    });

    test('итог автомата: запись закрыта, payment_client_cancelled_no_refund с полями, без ручного возврата', () async {
      final sid = await approvedSession(notifier());
      at(const Duration(seconds: 75));
      await CardPaymentService.clientCancel(CardPaymentService.quoteClientCancel('treating')!);
      await CardPaymentService.handlePaymentEvent({
        'type': 'client_cancelled_no_refund',
        'data': {'stage': 'treating', 'confirm': 'ACK 00', 'elapsed_s': 78},
      });
      expect(await CardPaymentStore.pending(), isNull);
      expect((await CardPaymentStore.history()).single.status, 'client_cancelled_no_refund');
      final types = await cloudTypes();
      expect(types, isNot(contains('payment_manual_refund_needed')));
      expect(types, isNot(contains('payment_refunded_auto')));
      final e = (await cloud()).lastWhere((e) => e.type == 'payment_client_cancelled_no_refund');
      expect(e.data['amount_cents'], 250);
      expect(e.data['flavor_index'], 1);
      expect(e.data['flavor'], isNotEmpty);
      expect(e.data['stage'], 'treating');
      expect(e.data['elapsed_s'], 75, reason: 'секунды на момент нажатия, не на итог');
      expect(e.data['session_id'], sid);
      expect(CardPaymentService.customerNotice.value, isNull);
    });

    test('итог цикла из SessionService после отмены — терминал больше не трогается', () async {
      final sid = await approvedSession(notifier());
      at(const Duration(seconds: 40));
      await CardPaymentService.clientCancel(CardPaymentService.quoteClientCancel('compressor')!);
      SessionService.onFinished!(sid, false, 'cancelled_by_client', {'stage': 'compressor'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls('finish'), isEmpty);
      expect(calls('clientCancel').length, 1);
    });

    test('повторное нажатие: то же решение, одна команда терминалу', () async {
      await approvedSession(notifier());
      at(const Duration(seconds: 12));
      final q1 = CardPaymentService.quoteClientCancel('compressor')!;
      await CardPaymentService.clientCancel(q1);
      at(const Duration(seconds: 50));
      final q2 = CardPaymentService.quoteClientCancel('treating')!;
      expect(q2.stage, 'compressor');
      expect(q2.elapsedS, 12);
      await CardPaymentService.clientCancel(q2);
      expect(calls('clientCancel').length, 1);
    });

    test('причина cancelled_by_client без нажатия через экран — запасной путь по причине', () async {
      final sid = await approvedSession(notifier());
      at(const Duration(seconds: 5));
      SessionService.onFinished!(sid, false, 'cancelled_by_client', {'stage': 'compressor'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls('finish'), isEmpty);
      expect(calls('clientCancel').single.arguments, {'stage': 'compressor', 'refund': false});
    });

    test('терминал недоступен — закрыть локально как оказанную услугу', () async {
      await approvedSession(notifier());
      messenger.setMockMethodCallHandler(card, (c) async => throw PlatformException(code: 'CARD'));
      at(const Duration(seconds: 50));
      await CardPaymentService.clientCancel(CardPaymentService.quoteClientCancel('treating')!);
      expect((await CardPaymentStore.history()).single.status, 'client_cancelled_no_refund');
      final types = await cloudTypes();
      expect(types, contains('payment_client_cancelled_no_refund'));
      expect(types, isNot(contains('payment_manual_refund_needed')));
    });
  });

  group('отмена в прогреве', () {
    test('в окне — clientCancel(refund: true), итог refunded → payment_refunded_auto', () async {
      await approvedSession(notifier());
      at(const Duration(seconds: 20));
      await CardPaymentService.clientCancel(CardPaymentService.quoteClientCancel('preheat')!);
      expect(calls('clientCancel').single.arguments, {'stage': 'preheat', 'refund': true});
      await CardPaymentService.handlePaymentEvent({
        'type': 'refunded',
        'data': {'refund': 'ACK 00', 'stage': 'preheat', 'cycle_reason': 'cancelled_by_client'},
      });
      expect(await cloudTypes(), contains('payment_refunded_auto'));
      expect((await CardPaymentStore.history()).single.status, 'refunded');
    });

    test('ровно на границе окна — уже без возврата и без ручного возврата', () async {
      await approvedSession(notifier());
      at(const Duration(seconds: 30));
      await CardPaymentService.clientCancel(CardPaymentService.quoteClientCancel('preheat')!);
      expect(calls('clientCancel').single.arguments, {'stage': 'preheat', 'refund': false});
    });

    test('в окне, но терминал недоступен — ручной возврат (как сбой в окне)', () async {
      await approvedSession(notifier());
      messenger.setMockMethodCallHandler(card, (c) async => throw PlatformException(code: 'CARD'));
      at(const Duration(seconds: 3));
      await CardPaymentService.clientCancel(CardPaymentService.quoteClientCancel('preheat')!);
      expect(await cloudTypes(), contains('payment_manual_refund_needed'));
    });
  });

  group('сбои аппарата — правило без изменений', () {
    for (final reason in [
      'heater_sensor_fault',
      'overheat',
      'heater_failure',
      'bus_unavailable',
      'out_of_service',
      'timeout',
    ]) {
      test('$reason в прогреве на 5-й секунде → finish(failure), не отмена клиентом', () async {
        final sid = await approvedSession(notifier());
        at(const Duration(seconds: 5));
        SessionService.onFinished!(sid, false, reason, {'phase': 'preheat'});
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(calls('finish').single.arguments, {'success': false, 'reason': reason});
        expect(calls('clientCancel'), isEmpty);
      });
    }

    test('сбой после окна — ручной возврат (облако), запись manual_refund_needed', () async {
      await approvedSession(notifier());
      await CardPaymentService.handlePaymentEvent({
        'type': 'manual_refund_needed',
        'data': {'refund': 'окно возврата прошло', 'cycle_reason': 'heater_sensor_fault'},
      });
      expect(await cloudTypes(), contains('payment_manual_refund_needed'));
      expect(await cloudTypes(), isNot(contains('payment_client_cancelled_no_refund')));
    });
  });

  group('перезапуск приложения во время отмены', () {
    Future<void> leavePending({Map<String, dynamic>? clientCancel}) =>
        CardPaymentStore.writePending(CardPaymentRecord(
          id: 'card-1',
          approvedAtMs: t0.millisecondsSinceEpoch,
          amountCents: 250,
          units: 250,
          flavorIndex: 1,
          flavorName: 'Вишня',
          coinsCents: 0,
          sessionId: 's-old',
          clientCancel: clientCancel,
        ));

    test('запись client_cancel переживает JSON', () async {
      await leavePending(clientCancel: const {'stage': 'treating', 'refund': false, 'elapsed_s': 44, 'at_ms': 1});
      final p = (await CardPaymentStore.pending())!;
      expect(p.clientCancel, {'stage': 'treating', 'refund': false, 'elapsed_s': 44, 'at_ms': 1});
    });

    test('отмена без возврата успела записаться — закрыть как услугу, не возвращать даже в окне', () async {
      await leavePending(clientCancel: const {'stage': 'preheat', 'refund': false, 'elapsed_s': 31, 'at_ms': 1});
      await CardPaymentService.recoverOnStartup(notifier(), now: t0.add(const Duration(seconds: 20)));
      expect(calls('recover'), isEmpty);
      expect(await CardPaymentStore.pending(), isNull);
      expect((await CardPaymentStore.history()).single.status, 'client_cancelled_no_refund');
      final types = await cloudTypes();
      expect(types, isNot(contains('payment_manual_refund_needed')));
      final e = (await cloud()).lastWhere((e) => e.type == 'payment_client_cancelled_no_refund');
      expect(e.data['recovered'], true);
      expect(e.data['stage'], 'preheat');
      expect(e.data['elapsed_s'], 31);
      expect(e.data['session_id'], 's-old');
    });

    test('отмена с возвратом в окне — возврат после перезапуска, если окно не прошло', () async {
      await leavePending(clientCancel: const {'stage': 'preheat', 'refund': true, 'elapsed_s': 8, 'at_ms': 1});
      await CardPaymentService.recoverOnStartup(notifier(), now: t0.add(const Duration(seconds: 15)));
      expect(calls('recover').single.arguments['deadlineMs'], t0.millisecondsSinceEpoch + 30000);
    });

    test('отмена с возвратом, перезапуск после окна — ручной возврат', () async {
      await leavePending(clientCancel: const {'stage': 'preheat', 'refund': true, 'elapsed_s': 8, 'at_ms': 1});
      await CardPaymentService.recoverOnStartup(notifier(), now: t0.add(const Duration(minutes: 2)));
      expect(await cloudTypes(), contains('payment_manual_refund_needed'));
    });

    test('падение до решения (окно подтверждения было открыто) — как сбой: ручной возврат после окна', () async {
      await leavePending();
      await CardPaymentService.recoverOnStartup(notifier(), now: t0.add(const Duration(minutes: 2)));
      expect(await cloudTypes(), contains('payment_manual_refund_needed'));
      expect(await cloudTypes(), isNot(contains('payment_client_cancelled_no_refund')));
    });
  });

  group('экраны: кнопка «Отмена» и предупреждение', () {
    Future<AppNotifier> pumpScreen(
      WidgetTester tester,
      Widget screen, {
      required Duration sinceApproval,
      bool card = true,
    }) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      final n = notifier()..setLanguage('ru');
      await tester.runAsync(() async {
        await I18n.load();
        await approvedSession(n, card: card);
      });
      at(sinceApproval);
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: MaterialApp(home: screen),
      ));
      await settle(tester);
      return n;
    }

    String tr(String key) => I18n.tr('ru', key);
    Finder cancelButton() => find.widgetWithText(OutlinedButton, tr('treating.cancel'));
    Finder noRefund() => find.text(tr('treating.no_refund_title'));

    Future<Map<String, dynamic>> sessionComplete(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await settle(tester);
      }
      final h = (await tester.runAsync(CloudService.history))!;
      return h.lastWhere((e) => e.type == CloudEventType.sessionComplete).data;
    }

    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    }

    testWidgets('прогрев в окне: остановка сразу, без предупреждения, с автовозвратом', (tester) async {
      await pumpScreen(tester, const PreparingScreen(), sinceApproval: const Duration(seconds: 25));
      await tester.tap(cancelButton());
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await settle(tester);
      expect(calls('clientCancel').single.arguments, {'stage': 'preheat', 'refund': true});
      final s = await sessionComplete(tester);
      expect(s['completed'], false);
      expect(s['reason'], 'cancelled_by_client');
      expect(s['stage'], 'preheat');
      expect(calls('finish'), isEmpty);
      await done(tester);
    });

    testWidgets('прогрев после окна: «Деньги не возвращаются»; «Продолжить» — ничего, «Остановить» — без возврата', (tester) async {
      await pumpScreen(tester, const PreparingScreen(), sinceApproval: const Duration(seconds: 45));
      await tester.tap(cancelButton());
      await settle(tester);
      expect(noRefund(), findsOneWidget);
      await tester.tap(find.text(tr('treating.cancel_no')));
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls('clientCancel'), isEmpty);
      expect(cancelButton(), findsOneWidget, reason: 'кнопка доступна снова');

      await tester.tap(cancelButton());
      await settle(tester);
      expect(noRefund(), findsOneWidget);
      // повторное нажатие «Отмена» под окном попадает в затемнение: окно
      // закрывается как «Продолжить», второго окна и остановки нет
      await tester.tap(cancelButton(), warnIfMissed: false);
      await settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls('clientCancel'), isEmpty);

      await tester.tap(cancelButton());
      await settle(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text(tr('treating.cancel_yes')));
      await settle(tester);
      expect(calls('clientCancel').single.arguments, {'stage': 'preheat', 'refund': false});
      final s = await sessionComplete(tester);
      expect(s['reason'], 'cancelled_by_client');
      expect(s['stage'], 'preheat');
      expect(s['paid_cents'], 250);
      await done(tester);
    });

    testWidgets('прогрев, монеты: как раньше — без окна и без терминала', (tester) async {
      await pumpScreen(tester, const PreparingScreen(), sinceApproval: const Duration(seconds: 45), card: false);
      await tester.tap(cancelButton());
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
      await settle(tester);
      expect(cardCalls.where((c) => c.method == 'clientCancel' || c.method == 'finish'), isEmpty);
      await done(tester);
    });

    testWidgets('компрессор, карта на 3-й секунде: всё равно «Деньги не возвращаются», затем 13 02-путь', (tester) async {
      await pumpScreen(tester, const TreatingScreen(), sinceApproval: const Duration(seconds: 3));
      await tester.tap(cancelButton());
      await settle(tester);
      expect(noRefund(), findsOneWidget);
      expect(find.text(tr('treating.no_refund_body')), findsOneWidget);
      await tester.tap(find.text(tr('treating.cancel_yes')));
      await settle(tester);
      expect(calls('clientCancel').single.arguments, {'stage': 'compressor', 'refund': false});
      final s = await sessionComplete(tester);
      expect(s['completed'], false);
      expect(s['reason'], 'cancelled_by_client');
      expect(s['stage'], 'compressor');
      expect(s['paid_cents'], 250);
      await done(tester);
    });

    testWidgets('обработка, монеты: прежнее окно «Остановить процедуру?»', (tester) async {
      await pumpScreen(tester, const TreatingScreen(), sinceApproval: Duration.zero, card: false);
      await tester.tap(cancelButton());
      await settle(tester);
      expect(find.text(tr('treating.cancel_title')), findsOneWidget);
      expect(noRefund(), findsNothing);
      await tester.tap(find.text(tr('treating.cancel_no')));
      await settle(tester);
      await done(tester);
    });

    testWidgets('переход прогрев → компрессор под открытым окном: окно закрывается, отмены нет', (tester) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      final n = notifier()..setLanguage('ru');
      await tester.runAsync(() async {
        await I18n.load();
        await approvedSession(n);
      });
      at(const Duration(seconds: 40));
      n.transition(AppState.preparing);
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: MaterialApp(
          home: Consumer<AppNotifier>(
            builder: (_, n, _) => n.state == AppState.compressorStartup
                ? const TreatingScreen()
                : const PreparingScreen(),
          ),
        ),
      ));
      await settle(tester);
      await tester.tap(cancelButton());
      await settle(tester);
      expect(noRefund(), findsOneWidget);
      // прогрев дошёл до цели, пока клиент читал окно
      temperature = 200.0;
      for (var i = 0; i < 5 && n.state != AppState.compressorStartup; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(n.state, AppState.compressorStartup);
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls('clientCancel'), isEmpty);
      // в компрессоре клиент нажимает снова — стадия уже compressor
      await tester.tap(cancelButton());
      await settle(tester);
      await tester.tap(find.text(tr('treating.cancel_yes')));
      await settle(tester);
      expect(calls('clientCancel').single.arguments, {'stage': 'compressor', 'refund': false});
      await done(tester);
    });

    testWidgets('нажатие в момент достижения цели (в окне): решение preheat, переход не происходит', (tester) async {
      final n = await pumpScreen(tester, const PreparingScreen(), sinceApproval: const Duration(seconds: 29));
      n.transition(AppState.preparing);
      temperature = 200.0; // следующий тик перевёл бы в компрессор
      await tester.tap(cancelButton());
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
      }
      expect(calls('clientCancel').single.arguments, {'stage': 'preheat', 'refund': true});
      expect(n.state, isNot(AppState.compressorStartup));
      await done(tester);
    });
  });
}

// Фейковое время виджета и реальное время каналов чередуются: иначе
// асинхронные вызовы каналов и SharedPreferences не завершаются.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}
