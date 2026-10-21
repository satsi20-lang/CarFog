import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/screens/error.dart';
import 'package:dry_fog_app/screens/payment.dart';
import 'package:dry_fog_app/screens/select_flavor.dart';
import 'package:dry_fog_app/screens/service/card_status_tab.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/card_payment_service.dart';
import 'package:dry_fog_app/services/card_payment_store.dart';
import 'package:dry_fog_app/services/card_terminal_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/session_service.dart';

// Поток оплаты картой (1.11.0, этап 3, ТЗ раздел 6) — Dart-сторона: запись
// payment_pending до запуска цикла, итог цикла → терминал, события в облако,
// pre-flight и экран оплаты в режиме mdb. Автомат MDB — в Kotlin
// (MdbCardPaymentTest); здесь его события подаются напрямую.
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
  // Ответы шины для pre-flight и монетоприёмника.
  late Object? temperature;
  late Object? energy;
  late List<int> coins;

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
    temperature = 25.0;
    energy = {'totalEnergy': 1.0, 'power': 15.0};
    coins = [];
    messenger.setMockMethodCallHandler(card, (c) async {
      cardCalls.add(c);
      if (c.method == 'arm' || c.method == 'updateAmount') return c.arguments['cents'];
      return null;
    });
    messenger.setMockMethodCallHandler(modbus, (c) async {
      modbusCalls.add(c);
      switch (c.method) {
        case 'getCoinAcceptorStatus':
          final cents = coins.isEmpty ? 0 : coins.removeAt(0);
          return {'cents': cents, 'failureCount': 0, 'down': false};
        case 'readAllInputs':
          return List.filled(16, false);
        case 'readTemperature':
          return temperature;
        case 'readEnergy':
          return energy;
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

  AppNotifier notifier({List<int>? prices}) {
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: true,
        paymentTerminalType: PaymentTerminalType.mdb,
        flavorPricesCents: prices ?? [200, 250, 300, 350],
        deviceId: 'CARFOG-T',
      );
    n.setBusHealthy(true);
    n.updateLevels(List.filled(8, true));
    return n;
  }

  // События в облако уходят без ожидания (unawaited) — дать записи завершиться.
  Future<List<CloudEvent>> cloud() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return CloudService.history();
  }

  Future<List<String>> cloudTypes() async => (await cloud()).map((e) => e.type).toList();

  group('события автомата и запись на диске', () {
    Future<void> armed(AppNotifier n) => CardPaymentService.arm(
      notifier: n,
      cents: 150,
      flavorIndex: 1,
      coinsCents: 100,
    );

    test('10 05: payment_pending записан ДО того, как экран узнает об одобрении', () async {
      final n = notifier();
      await armed(n);
      CardPaymentRecord? seenWhenApproved;
      final sub = CardPaymentService.events.listen((e) async {
        if (e.type == 'approved') seenWhenApproved = await CardPaymentStore.pending();
      });
      await CardPaymentService.handlePaymentEvent({
        'kind': 'payment',
        'type': 'approved',
        'data': {'units': 150},
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(seenWhenApproved, isNotNull);
      expect(seenWhenApproved!.amountCents, 150);
      expect(seenWhenApproved!.coinsCents, 100);
      expect(seenWhenApproved!.flavorIndex, 1);
      expect(seenWhenApproved!.status, 'pending');
      expect(await cloudTypes(), contains('payment_card_approved'));
    });

    test('итог цикла уходит в терминал: сбой — finish(success: false, причина)', () async {
      final n = notifier();
      await armed(n);
      await CardPaymentService.handlePaymentEvent({'type': 'approved', 'data': {'units': 150}});
      CardPaymentService.attachSession('s-1');
      SessionService.onFinished!('s-1', false, 'heater_failure');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final finish = cardCalls.where((c) => c.method == 'finish').single;
      expect(finish.arguments, {'success': false, 'reason': 'heater_failure'});
    });

    test('чужая сессия или без одобрения — терминал не трогается', () async {
      final n = notifier();
      await armed(n);
      SessionService.onFinished!('s-x', true, null);
      await CardPaymentService.handlePaymentEvent({'type': 'approved', 'data': {'units': 150}});
      CardPaymentService.attachSession('s-1');
      SessionService.onFinished!('s-2', true, null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(cardCalls.where((c) => c.method == 'finish'), isEmpty);
    });

    test('успех: запись закрыта и в истории, payment_card_success', () async {
      await armed(notifier());
      await CardPaymentService.handlePaymentEvent({'type': 'approved', 'data': {'units': 150}});
      await CardPaymentService.handlePaymentEvent({'type': 'success', 'data': {'confirm': 'ACK 00'}});
      expect(await CardPaymentStore.pending(), isNull);
      final h = await CardPaymentStore.history();
      expect(h.single.status, 'success');
      expect(h.single.outcome['confirm'], 'ACK 00');
      expect(await cloudTypes(), contains('payment_card_success'));
      expect(CardPaymentService.customerNotice.value, isNull);
    });

    test('автовозврат: payment_refunded_auto, клиенту «деньги не списаны»', () async {
      await armed(notifier());
      await CardPaymentService.handlePaymentEvent({'type': 'approved', 'data': {'units': 150}});
      await CardPaymentService.handlePaymentEvent({'type': 'refunded', 'data': {'refund': 'ACK 00', 'elapsed_s': 12}});
      expect((await CardPaymentStore.history()).single.status, 'refunded');
      expect(await cloudTypes(), contains('payment_refunded_auto'));
      expect(CardPaymentService.customerNotice.value, CardCustomerNotice.refunded);
    });

    test('ручной возврат: payment_manual_refund_needed с суммой, запахом, временем', () async {
      await armed(notifier());
      await CardPaymentService.handlePaymentEvent({'type': 'approved', 'data': {'units': 150}});
      await CardPaymentService.handlePaymentEvent({'type': 'manual_refund_needed', 'data': {'refund': 'окно возврата прошло', 'elapsed_s': 95}});
      final e = (await cloud()).lastWhere((e) => e.type == 'payment_manual_refund_needed');
      expect(e.data['amount_cents'], 150);
      expect(e.data['coins_cents'], 100);
      expect(e.data['flavor_index'], 1);
      expect(e.data['device_id'], 'CARFOG-T');
      expect(e.data['approved_at'], isNotNull);
      expect(e.data['elapsed_s'], 95);
      expect(CardPaymentService.customerNotice.value, CardCustomerNotice.contactOperator);
      expect((await CardPaymentStore.history()).single.status, 'manual_refund_needed');
    });

    test('отказ и недостаточно средств — payment_card_declined с причиной, записи нет', () async {
      await armed(notifier());
      await CardPaymentService.handlePaymentEvent({'type': 'declined', 'data': <String, dynamic>{}});
      await CardPaymentService.handlePaymentEvent({'type': 'insufficient_funds', 'data': {'funds': 100}});
      final reasons = (await cloud())
          .where((e) => e.type == 'payment_card_declined')
          .map((e) => e.data['reason'])
          .toList();
      expect(reasons, ['declined', 'insufficient_funds']);
      expect(await CardPaymentStore.pending(), isNull);
    });

    test('история — не больше 50 закрытых записей', () async {
      for (var i = 0; i < 53; i++) {
        await CardPaymentStore.writePending(CardPaymentRecord(
          id: 'r$i', approvedAtMs: i, amountCents: 200, units: 200,
          flavorIndex: 0, flavorName: 'Лимон', coinsCents: 0,
        ));
        await CardPaymentStore.close('success', const {});
      }
      final h = await CardPaymentStore.history();
      expect(h.length, 50);
      expect(h.first.id, 'r3');
    });
  });

  group('pre-flight', () {
    test('всё в порядке', () async {
      expect(await CardPaymentService.preflight(notifier(), 0), isNull);
    });
    test('шина недоступна', () async {
      final n = notifier()..setBusHealthy(false);
      expect(await CardPaymentService.preflight(n, 0), 'bus');
    });
    test('канистра запаха пуста', () async {
      final n = notifier()..updateLevels([true, false, true, true, true, true, true, true]);
      expect(await CardPaymentService.preflight(n, 1), 'level');
    });
    test('термопара не читается', () async {
      temperature = null;
      expect(await CardPaymentService.preflight(notifier(), 0), 'thermocouple');
    });
    test('счётчик энергии не читается', () async {
      energy = null;
      expect(await CardPaymentService.preflight(notifier(), 0), 'energy_meter');
    });
    test('обслуживание — оплата заблокирована', () async {
      final n = notifier()..setMaintenance(true);
      expect(await CardPaymentService.preflight(n, 0), 'payment_blocked');
    });
  });

  group('экран оплаты, карта MDB', () {
    Future<AppNotifier> pumpPayment(
      WidgetTester tester, {
      bool cardAvailable = true,
      String state = 'READY',
    }) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      await tester.runAsync(I18n.load);
      CardTerminalService.status.value = CardTerminalStatus(
        state: state,
        cardAvailable: cardAvailable,
        readerEnabled: cardAvailable,
      );
      final n = notifier()..setLanguage('ru');
      n.selectFlavor(1); // 2,50 €
      expect(n.state, AppState.payment);
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: PaymentScreen()),
      ));
      await settle(tester);
      return n;
    }

    Future<void> event(WidgetTester tester, String type, [Map<String, dynamic>? data]) async {
      await tester.runAsync(() => CardPaymentService.handlePaymentEvent({'type': type, 'data': data ?? <String, dynamic>{}}));
      await settle(tester);
    }

    Future<void> disposeScreen(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    }

    testWidgets('pre-flight не прошёл: «Аппарат временно недоступен», ни монет, ни карты', (tester) async {
      temperature = null;
      final n = await pumpPayment(tester);
      expect(find.byKey(const ValueKey('machine_unavailable')), findsOneWidget);
      expect(find.text('Аппарат временно недоступен'), findsOneWidget);
      expect(cardCalls.where((c) => c.method == 'arm'), isEmpty);
      expect(modbusCalls.where((c) => c.method == 'startPaymentCoinCounting'), isEmpty);
      final hw = (await tester.runAsync(CloudService.history))!
          .where((e) => e.type == CloudEventType.hardwareError);
      expect(hw.single.data['code'], 'card_preflight');
      await tester.pump(const Duration(seconds: 9));
      expect(n.state, isNot(AppState.payment));
      await disposeScreen(tester);
    });

    testWidgets('карта ждёт на цену запаха, «Приложите карту», отмена видна', (tester) async {
      await pumpPayment(tester);
      final arm = cardCalls.where((c) => c.method == 'arm').single;
      expect(arm.arguments['cents'], 250);
      expect(arm.arguments['flavorIndex'], 1);
      expect(arm.arguments['refundWindowS'], 30);
      expect(find.text('Приложите карту'), findsOneWidget);
      expect(find.byKey(const ValueKey('payment_cancel')), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('после 10 03 и vend: отмена скрыта, таймер стоит, монета — duplicate', (tester) async {
      await pumpPayment(tester);
      await event(tester, 'vend_sent', {'units': 250});
      expect(find.byKey(const ValueKey('payment_cancel')), findsNothing);
      expect(find.text('Обработка платежа…'), findsOneWidget);
      expect(find.text('1:00'), findsOneWidget);
      coins.add(100);
      for (var i = 0; i < 5; i++) {
        await settle(tester);
      }
      expect(find.text('1:00'), findsOneWidget, reason: 'таймер стоит');
      final dup = (await tester.runAsync(CloudService.history))!
          .where((e) => e.type == CloudEventType.duplicatePayment);
      expect(dup.single.data['reason'], 'after_vend');
      await disposeScreen(tester);
    });

    testWidgets('одобрено: запись на диске, затем прогрев; оплата картой на полную цену', (tester) async {
      final n = await pumpPayment(tester);
      await event(tester, 'vend_sent', {'units': 250});
      await event(tester, 'approved', {'units': 250});
      expect(n.state, AppState.preparing);
      final p = (await tester.runAsync(CardPaymentStore.pending))!;
      expect(p.amountCents, 250);
      expect(p.sessionId, SessionService.currentSessionId);
      await disposeScreen(tester);
    });

    testWidgets('монета до карты — vend пойдёт на остаток', (tester) async {
      await pumpPayment(tester);
      coins.add(100);
      for (var i = 0; i < 3; i++) {
        await settle(tester);
      }
      final upd = cardCalls.where((c) => c.method == 'updateAmount').single;
      expect(upd.arguments['cents'], 150);
      await disposeScreen(tester);
    });

    testWidgets('отказ: «Платёж отклонён», карта снова ждёт', (tester) async {
      await pumpPayment(tester);
      await event(tester, 'vend_sent', {'units': 250});
      await event(tester, 'declined');
      await tester.pump(const Duration(milliseconds: 1100));
      await settle(tester);
      expect(find.text('Платёж отклонён, попробуйте другую карту'), findsOneWidget);
      expect(find.byKey(const ValueKey('payment_cancel')), findsOneWidget);
      expect(cardCalls.where((c) => c.method == 'arm').length, 2);
      await disposeScreen(tester);
    });

    testWidgets('недостаточно средств — своё сообщение', (tester) async {
      await pumpPayment(tester);
      await event(tester, 'insufficient_funds', {'funds': 100});
      expect(find.text('Недостаточно средств'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('«Отмена» до карты — сброс читателя (cancel), без disable', (tester) async {
      final n = await pumpPayment(tester);
      await tester.tap(find.byKey(const ValueKey('payment_cancel')));
      await settle(tester);
      expect(cardCalls.where((c) => c.method == 'cancel').length, 1);
      expect(cardCalls.where((c) => c.method == 'disarm'), isEmpty);
      expect(n.state, isNot(AppState.payment));
      await disposeScreen(tester);
    });

    testWidgets('терминал занят стендом — «Терминал занят сервисным режимом», монеты работают', (tester) async {
      await pumpPayment(tester, cardAvailable: false, state: 'SERVICE');
      expect(find.text('Терминал занят сервисным режимом'), findsOneWidget);
      expect(cardCalls.where((c) => c.method == 'arm'), isEmpty);
      expect(modbusCalls.where((c) => c.method == 'startPaymentCoinCounting'), isNotEmpty);
      await disposeScreen(tester);
    });

    testWidgets('терминал недоступен — «Оплата картой временно недоступна»', (tester) async {
      await pumpPayment(tester, cardAvailable: false, state: 'OFFLINE');
      expect(find.text('Оплата картой временно недоступна'), findsOneWidget);
      await disposeScreen(tester);
    });

    testWidgets('сумма не совпала — сообщение об ошибке, карта больше не предлагается', (tester) async {
      await pumpPayment(tester);
      await event(tester, 'vend_sent', {'units': 250});
      await event(tester, 'amount_mismatch', {'approved_units': 100});
      await tester.pump(const Duration(seconds: 2));
      await settle(tester);
      expect(find.text('Произошла ошибка, обратитесь к оператору'), findsOneWidget);
      expect(cardCalls.where((c) => c.method == 'arm').length, 1);
      await disposeScreen(tester);
    });
  });

  group('сообщения клиенту вне экрана оплаты', () {
    Future<void> pump(WidgetTester tester, AppNotifier n, Widget screen) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      await tester.runAsync(I18n.load);
      n.setLanguage('ru');
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: MaterialApp(home: screen),
      ));
      await tester.pump(const Duration(milliseconds: 300));
    }

    for (final (notice, text) in [
      (CardCustomerNotice.refunded, 'Платёж отменён, деньги не списаны'),
      (CardCustomerNotice.contactOperator, 'Произошла ошибка, обратитесь к оператору'),
    ]) {
      testWidgets('экран ошибки после сбоя цикла: $text', (tester) async {
        final n = notifier()..goToError('heater_failure');
        await pump(tester, n, const ErrorScreen());
        expect(find.byKey(const ValueKey('card_notice')), findsNothing);
        CardPaymentService.customerNotice.value = notice;
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text(text), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 11));
      });
    }

    testWidgets('карта без выбранного запаха — подсказка на экране выбора на 6 с', (tester) async {
      final n = notifier();
      await pump(tester, n, const SelectFlavorScreen());
      expect(find.text('Сначала выберите запах'), findsNothing);
      CardTerminalService.tappedWithoutFlavorAt.value = DateTime.now();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Сначала выберите запах'), findsOneWidget);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 6100)));
      await tester.pump(const Duration(seconds: 7));
      expect(find.text('Сначала выберите запах'), findsNothing);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('восстановление после перезапуска (раздел 8)', () {
    final approved = DateTime(2026, 10, 22, 14, 5);
    Future<void> leavePending() => CardPaymentStore.writePending(CardPaymentRecord(
      id: 'card-1',
      approvedAtMs: approved.millisecondsSinceEpoch,
      amountCents: 250,
      units: 250,
      flavorIndex: 1,
      flavorName: 'Вишня',
      coinsCents: 0,
      sessionId: 's-old',
    ));

    test('нет незакрытой записи — ничего', () async {
      await CardPaymentService.recoverOnStartup(notifier(), now: approved);
      expect(cardCalls, isEmpty);
      expect(await cloudTypes(), isEmpty);
    });

    test('окно не прошло, терминал mdb — просим терминал вернуть (recover)', () async {
      await leavePending();
      await CardPaymentService.recoverOnStartup(notifier(), now: approved.add(const Duration(seconds: 12)));
      final r = cardCalls.where((c) => c.method == 'recover').single;
      expect(r.arguments['units'], 250);
      expect(r.arguments['item'], 2);
      expect(r.arguments['deadlineMs'], approved.millisecondsSinceEpoch + 30000);
      // итог от терминала закрывает запись
      await CardPaymentService.handlePaymentEvent({'type': 'refunded', 'data': {'recovered': true, 'refund': 'ACK 00'}});
      expect(await CardPaymentStore.pending(), isNull);
      final h = (await CardPaymentStore.history()).single;
      expect(h.status, 'refunded');
      expect(h.sessionId, 's-old');
      final e = (await cloud()).lastWhere((e) => e.type == 'payment_refunded_auto');
      expect(e.data['amount_cents'], 250);
      expect(e.data['recovered'], true);
    });

    test('окно прошло — сразу ручной возврат (облако и Telegram), терминал не трогаем', () async {
      await leavePending();
      await CardPaymentService.recoverOnStartup(notifier(), now: approved.add(const Duration(minutes: 3)));
      expect(cardCalls.where((c) => c.method == 'recover'), isEmpty);
      final e = (await cloud()).lastWhere((e) => e.type == 'payment_manual_refund_needed');
      expect(e.data['amount_cents'], 250);
      expect(e.data['flavor'], 'Вишня');
      expect(e.data['recovered'], true);
      expect(e.data['refund'], 'окно возврата прошло до перезапуска');
      expect(e.data['elapsed_s'], 180);
      expect(e.data['approved_at'], approved.toUtc().toIso8601String());
      expect(await CardPaymentStore.pending(), isNull);
      expect((await CardPaymentStore.history()).single.status, 'manual_refund_needed');
    });

    test('тип терминала уже не mdb — ручной возврат', () async {
      await leavePending();
      final n = notifier()..config = notifier().config.copyWith(paymentTerminalType: PaymentTerminalType.off);
      await CardPaymentService.recoverOnStartup(n, now: approved.add(const Duration(seconds: 5)));
      final e = (await cloud()).lastWhere((e) => e.type == 'payment_manual_refund_needed');
      expect(e.data['refund'], 'терминал mdb выключен');
    });

    test('терминал не ответил на запрос — ручной возврат', () async {
      await leavePending();
      messenger.setMockMethodCallHandler(card, (c) async => throw PlatformException(code: 'CARD', message: 'нет порта'));
      await CardPaymentService.recoverOnStartup(notifier(), now: approved.add(const Duration(seconds: 5)));
      final e = (await cloud()).lastWhere((e) => e.type == 'payment_manual_refund_needed');
      expect(e.data['refund'], 'терминал недоступен');
    });
  });

  group('журнал событий и вкладка «Карта»', () {
    test('последние события — не больше 20, новые в конце', () {
      for (var i = 0; i < 25; i++) {
        CardTerminalService.handleEvent(
          {'kind': 'event', 'type': 'terminal_unexpected_frame', 'data': {'reason': 'r$i'}},
          'CARFOG-T',
          now: DateTime(2026, 10, 22, 12, 0, i),
        );
      }
      final list = CardTerminalService.recent.value;
      expect(list.length, 20);
      expect(list.last, contains('r24'));
      expect(list.first, contains('r5'));
    });

    testWidgets('статус, незакрытая оплата и история', (tester) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await CardPaymentStore.writePending(CardPaymentRecord(
          id: 'a', approvedAtMs: DateTime(2026, 10, 22, 10).millisecondsSinceEpoch,
          amountCents: 200, units: 200, flavorIndex: 0, flavorName: 'Лимон', coinsCents: 0,
        ));
        await CardPaymentStore.close('manual_refund_needed', const {});
        await CardPaymentStore.writePending(CardPaymentRecord(
          id: 'b', approvedAtMs: DateTime(2026, 10, 22, 11).millisecondsSinceEpoch,
          amountCents: 300, units: 300, flavorIndex: 2, flavorName: 'Хвоя', coinsCents: 50,
        ));
      });
      CardTerminalService.status.value = const CardTerminalStatus(
        state: 'OFFLINE', stateTitle: 'терминал недоступен', consecutiveFailures: 3, recoveryPending: true,
      );
      final n = notifier()..setLanguage('ru');
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: Scaffold(body: CardStatusTab())),
      ));
      await settle(tester);
      expect(find.text('карта (MDB)'), findsOneWidget);
      expect(find.text('терминал недоступен'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.textContaining('3.00 € · Хвоя'), findsOneWidget);
      expect(find.textContaining('Лимон · нужен ручной возврат'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('тип не mdb — подсказка, где включить', (tester) async {
      final n = notifier()..config = notifier().config.copyWith(paymentTerminalType: PaymentTerminalType.pulse);
      n.setLanguage('ru');
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: Scaffold(body: CardStatusTab())),
      ));
      await settle(tester);
      expect(find.textContaining('Оплата картой по MDB выключена'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
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
