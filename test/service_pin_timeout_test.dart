import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/screens/service/service_menu.dart';
import 'package:dry_fog_app/screens/service/service_pin.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/security_service.dart';

// 1.12.1 (требование владельца 2026-11-05): экран ввода PIN без касаний
// 30 с — назад на заставку; сервисное меню без таймаута.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = [
    MethodChannel('com.carfog.dryfog/system'),
    MethodChannel('com.carfog.dryfog/storage'),
    MethodChannel('com.carfog.dryfog/modbus'),
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudService.resetQueueForTest();
    for (final c in channels) {
      messenger.setMockMethodCallHandler(c, (call) async => null);
    }
  });
  tearDown(() {
    for (final c in channels) {
      messenger.setMockMethodCallHandler(c, null);
    }
  });

  // Асинхронная работа SharedPreferences (tryPin, счётчик попыток) — в
  // реальном времени; таймеры экрана — в поддельном (pump).
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 5; i++) {
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 40)));
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<AppNotifier> open(WidgetTester t, List<AppState> seen) async {
    t.view.devicePixelRatio = 1.5;
    t.view.physicalSize = const Size(1080, 1920);
    addTearDown(t.view.reset);
    final n = AppNotifier()
      ..config = AppConfig(servicePin: '7351')
      ..setLanguage('ru')
      ..transition(AppState.servicePinEntry);
    n.addListener(() {
      if (seen.isEmpty || seen.last != n.state) seen.add(n.state);
    });
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: n,
        child: const MaterialApp(home: ServicePinScreen()),
      ),
    );
    await settle(t);
    return n;
  }

  // Закрашенные кружки ввода (введённые цифры).
  int filledDots(WidgetTester t) => t
      .widgetList<Container>(find.byType(Container))
      .where((c) {
        final d = c.decoration;
        return d is BoxDecoration &&
            d.shape == BoxShape.circle &&
            d.color == const Color(0xFF00C6B2);
      })
      .length;

  test('таймаут — константа 30 с', () {
    expect(ServicePinScreen.idleTimeout, const Duration(seconds: 30));
  });

  testWidgets('30 с без касаний — заставка; раньше — нет', (t) async {
    final seen = <AppState>[];
    final n = await open(t, seen);
    await t.pump(const Duration(seconds: 28));
    expect(n.state, AppState.servicePinEntry);
    await t.pump(const Duration(seconds: 2));
    expect(n.state, AppState.standby);
    // Один переход, без повторов.
    await t.pump(const Duration(seconds: 90));
    expect(seen.where((s) => s == AppState.standby), hasLength(1));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('нажатие клавиши и стирание сбрасывают отсчёт', (t) async {
    final n = await open(t, []);
    await t.pump(const Duration(seconds: 20));
    await t.tap(find.text('1'));
    await t.pump(const Duration(seconds: 20)); // 40 с от открытия
    expect(n.state, AppState.servicePinEntry);
    await t.tap(find.text('⌫'));
    await t.pump(const Duration(seconds: 29));
    expect(n.state, AppState.servicePinEntry);
    await t.pump(const Duration(seconds: 2));
    expect(n.state, AppState.standby);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('касание пустого места экрана тоже сбрасывает отсчёт', (t) async {
    final n = await open(t, []);
    await t.pump(const Duration(seconds: 25));
    await t.tapAt(const Offset(20, 900)); // пустое место экрана
    await t.pump(const Duration(seconds: 25));
    expect(n.state, AppState.servicePinEntry);
    await t.pump(const Duration(seconds: 6));
    expect(n.state, AppState.standby);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('верный PIN до таймаута — меню; таймер после этого не уводит',
      (t) async {
    final seen = <AppState>[];
    final n = await open(t, seen);
    await t.pump(const Duration(seconds: 25));
    for (final d in '7351'.split('')) {
      await t.tap(find.text(d));
      await t.pump(const Duration(milliseconds: 30));
    }
    await settle(t);
    expect(n.state, AppState.serviceMenu);
    await t.pump(const Duration(seconds: 120));
    expect(n.state, AppState.serviceMenu);
    expect(seen, isNot(contains(AppState.standby)));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('по таймауту цифры стираются, попытка не засчитывается',
      (t) async {
    final n = await open(t, []);
    final before = (await t.runAsync(SecurityService.attemptsLeft))!;
    await t.tap(find.text('7'));
    await t.pump(const Duration(milliseconds: 30));
    await t.tap(find.text('3'));
    await t.pump(const Duration(milliseconds: 30));
    expect(filledDots(t), 2);
    await t.pump(const Duration(seconds: 31));
    expect(n.state, AppState.standby);
    await t.pump();
    expect(filledDots(t), 0);
    await settle(t);
    expect((await t.runAsync(SecurityService.attemptsLeft))!, before);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('уход с экрана отменяет таймер: нет перехода и двойного перехода',
      (t) async {
    final seen = <AppState>[];
    final n = await open(t, seen);
    await t.pump(const Duration(seconds: 10));
    // «Отмена» — на заставку сразу; экран снимается.
    n.transition(AppState.standby);
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: n,
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    n.transition(AppState.selectLanguage);
    await t.pump(const Duration(seconds: 60));
    expect(n.state, AppState.selectLanguage);
    expect(seen.where((s) => s == AppState.standby), hasLength(1));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('сервисное меню: без таймаута', (t) async {
    t.view.devicePixelRatio = 1.5;
    t.view.physicalSize = const Size(1080, 1920);
    addTearDown(t.view.reset);
    final n = AppNotifier()
      ..config = AppConfig(servicePin: '7351')
      ..setLanguage('ru')
      ..transition(AppState.serviceMenu);
    await t.pumpWidget(
      ChangeNotifierProvider.value(
        value: n,
        child: const MaterialApp(home: ServiceMenuScreen()),
      ),
    );
    await t.pump(const Duration(milliseconds: 600));
    await t.pump(const Duration(minutes: 5));
    expect(n.state, AppState.serviceMenu);
    await t.pumpWidget(const SizedBox());
  });
}
