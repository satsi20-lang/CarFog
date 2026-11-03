import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/main.dart' show preferredOrientations;
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/hardware_profile.dart';
import 'package:dry_fog_app/screens/error.dart';
import 'package:dry_fog_app/screens/finished.dart';
import 'package:dry_fog_app/screens/language_select.dart';
import 'package:dry_fog_app/screens/out_of_service.dart';
import 'package:dry_fog_app/screens/payment.dart';
import 'package:dry_fog_app/screens/preparing.dart';
import 'package:dry_fog_app/screens/select_flavor.dart';
import 'package:dry_fog_app/screens/service/service_menu.dart';
import 'package:dry_fog_app/screens/service/service_pin.dart';
import 'package:dry_fog_app/screens/standby.dart';
import 'package:dry_fog_app/screens/treating.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:dry_fog_app/widgets/portrait_ui.dart';

// Альбомный макет профиля ixp101m1 (CARFOG-001): физически 1280x800,
// плотность 240 (devicePixelRatio 1.5) → 853x533 dp. Каждый клиентский экран
// помещается без переполнения И без прокрутки на ru/en/et; вкладки
// сервисного меню могут прокручиваться, но отрисовываются без исключений.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => I18n.load());

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = [
    'com.carfog.dryfog/system',
    'com.carfog.dryfog/modbus',
    'com.carfog.dryfog/storage',
  ];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (call) async => null);
    }
    HardwareProfile.current = HardwareProfile.ixp101m1;
  });

  tearDown(() {
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
    HardwareProfile.current = HardwareProfile.fallback;
  });

  void landscape(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(tester.view.reset);
  }

  AppNotifier notifier(
    String lang, {
    List<bool>? levels,
    String? error,
    bool meter = true,
    int pumps = 4,
  }) {
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: meter,
        specPumps: pumps,
      );
    n.setLanguage(lang);
    if (levels != null) n.updateLevels(levels);
    if (error != null) n.goToError(error);
    return n;
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen,
    AppNotifier n,
  ) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: MaterialApp(home: screen),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  // Ни один прокручиваемый блок экрана не прокручивается: всё помещается.
  void expectNoScroll(WidgetTester tester, String what) {
    for (final s in tester.stateList<ScrollableState>(find.byType(Scrollable))) {
      final pos = s.position;
      if (!pos.hasContentDimensions) continue;
      expect(pos.maxScrollExtent, lessThanOrEqualTo(0.5), reason: what);
    }
  }

  group('профиль ixp101m1', () {
    test('альбом 853x533 dp, ориентации landscape', () {
      const p = HardwareProfile.ixp101m1;
      expect(p.orientation, ScreenOrientation.landscape);
      expect(p.logicalWidthDp.round(), 853);
      expect(p.logicalHeightDp.round(), 533);
      expect(preferredOrientations(p), [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      expect(preferredOrientations(HardwareProfile.sy156a510), [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    });

    test('минимумы альбома: кнопки ≥ 56, текст ≥ 18, заголовки ≥ 28, касание ≥ 48', () {
      const u = UiMetrics.landscape;
      expect(u.buttonH, greaterThanOrEqualTo(56));
      expect(u.minButtonH, greaterThanOrEqualTo(56));
      expect(u.bodySp, greaterThanOrEqualTo(18));
      expect(u.minBodySp, greaterThanOrEqualTo(18));
      expect(u.titleSp, greaterThanOrEqualTo(28));
      expect(u.minTitleSp, greaterThanOrEqualTo(28));
      expect(u.minTouch, greaterThanOrEqualTo(48));
      expect(u.langH, greaterThanOrEqualTo(48));
      expect(PUi.landscape, isTrue);
      expect(PUi.m, same(UiMetrics.landscape));
    });
  });

  final screens = <String, Widget Function()>{
    'standby': () => const StandbyScreen(),
    'language_select': () => const LanguageSelectScreen(),
    'select_flavor': () => const SelectFlavorScreen(),
    'payment': () => const PaymentScreen(),
    'preparing': () => const PreparingScreen(),
    'treating': () => const TreatingScreen(),
    'finished': () => const FinishedScreen(),
    'error': () => const ErrorScreen(),
    'out_of_service': () => const OutOfServiceScreen(),
    'service_pin': () => const ServicePinScreen(),
  };

  for (final lang in ['ru', 'en', 'et']) {
    for (final e in screens.entries) {
      testWidgets('${e.key} [$lang] 853x533 без переполнения и прокрутки', (
        tester,
      ) async {
        landscape(tester);
        final n = notifier(
          lang,
          levels: [true, false, true, true, true, true, true, true],
          error: e.key == 'error' ? 'bus_unavailable' : null,
          meter: e.key != 'preparing',
        );
        await pumpScreen(tester, e.value(), n);
        expect(tester.takeException(), isNull);
        expectNoScroll(tester, '${e.key} [$lang]');
        await dispose(tester);
      });
    }

    for (final pumps in [5, 6, 7, 8]) {
      testWidgets('select_flavor [$lang] $pumps ароматов в альбоме', (
        tester,
      ) async {
        landscape(tester);
        final n = notifier(
          lang,
          pumps: pumps,
          levels: [true, false, true, true, true, true, true, true],
        );
        await pumpScreen(tester, const SelectFlavorScreen(), n);
        expect(tester.takeException(), isNull);
        expectNoScroll(tester, 'select_flavor $pumps [$lang]');
        await dispose(tester);
      });
    }

    testWidgets('error с отсчётом [$lang] в альбоме', (tester) async {
      landscape(tester);
      await pumpScreen(
        tester,
        const ErrorScreen(),
        notifier(lang, error: 'heater_timeout'),
      );
      expect(tester.takeException(), isNull);
      expectNoScroll(tester, 'error heater_timeout [$lang]');
      await dispose(tester);
    });
  }

  // Панель навигации видна (запасной вариант SystemBarsLift): интерфейс
  // поднят на 48 dp, экраны не переполняются, «Отмена» выше полоски.
  group('панель навигации видна', () {
    tearDown(() => SystemBarsLift.barsVisible.value = false);

    Future<void> pumpLifted(
      WidgetTester tester,
      Widget screen,
      AppNotifier n,
    ) async {
      SystemBarsLift.barsVisible.value = true;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppNotifier>.value(
          value: n,
          child: MaterialApp(
            builder: (context, child) => SystemBarsLift(child: child!),
            home: screen,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
    }

    for (final lang in ['ru', 'en', 'et']) {
      for (final e in screens.entries) {
        testWidgets('${e.key} [$lang] 853x485 без переполнения', (tester) async {
          landscape(tester);
          final n = notifier(
            lang,
            levels: [true, false, true, true, true, true, true, true],
            error: e.key == 'error' ? 'bus_unavailable' : null,
            meter: e.key != 'preparing',
          );
          await pumpLifted(tester, e.value(), n);
          expect(tester.takeException(), isNull);
          await dispose(tester);
        });
      }
    }

    testWidgets('«Отмена» выбора аромата выше полоски навигации', (
      tester,
    ) async {
      landscape(tester);
      await pumpLifted(
        tester,
        const SelectFlavorScreen(),
        notifier('ru', pumps: 8, levels: List.filled(8, true)),
      );
      final cancel = find.byType(LandscapeCancelButton);
      expect(cancel, findsOneWidget);
      expect(
        tester.getRect(cancel).bottom,
        lessThanOrEqualTo(533.4 - SystemBarsLift.navBarDp),
      );
      await dispose(tester);
    });

    testWidgets('панель спрятана — интерфейс на прежнем месте', (tester) async {
      landscape(tester);
      SystemBarsLift.barsVisible.value = false;
      await tester.pumpWidget(
        ChangeNotifierProvider<AppNotifier>.value(
          value: notifier('ru'),
          child: MaterialApp(
            builder: (context, child) => SystemBarsLift(child: child!),
            home: const SelectFlavorScreen(),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      final bottom = tester.getRect(find.byType(LandscapeCancelButton)).bottom;
      expect(bottom, greaterThan(533.4 - SystemBarsLift.navBarDp));
      await dispose(tester);
    });
  });

  testWidgets('выбор аромата: 8 карточек в 2 ряда по 4', (tester) async {
    landscape(tester);
    await pumpScreen(
      tester,
      const SelectFlavorScreen(),
      notifier('en', pumps: 8, levels: List.filled(8, true)),
    );
    final prices = find.byKey(const ValueKey('flavor_price'));
    expect(prices, findsNWidgets(8));
    final ys = {
      for (var i = 0; i < 8; i++)
        tester
            .getTopLeft(
              find
                  .ancestor(
                    of: prices.at(i),
                    matching: find.byType(AnimatedContainer),
                  )
                  .first,
            )
            .dy
            .round(),
    };
    expect(ys.length, 2);
    await dispose(tester);
  });

  for (final lang in ['ru', 'en', 'et']) {
    for (var i = 0; i < 10; i++) {
      testWidgets('сервисное меню, вкладка $i [$lang] 853x533', (tester) async {
        landscape(tester);
        await pumpScreen(tester, const ServiceMenuScreen(), notifier(lang));
        final scroll = find.byType(SingleChildScrollView).first;
        final tabRow = find.descendant(
          of: scroll,
          matching: find.byType(GestureDetector),
        );
        await tester.ensureVisible(tabRow.at(i));
        await tester.tap(tabRow.at(i), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await dispose(tester);
      });
    }
  }
}
