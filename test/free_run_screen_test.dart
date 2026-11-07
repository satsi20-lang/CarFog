import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/hardware_profile.dart';
import 'package:dry_fog_app/screens/free_run_screen.dart';
import 'package:dry_fog_app/screens/service/service_menu.dart';
import 'package:dry_fog_app/screens/service/service_pin.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/free_run_service.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:dry_fog_app/services/security_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Бесплатный запуск: кнопка на экране PIN и экран ввода кода (без входа в
// сервисное меню). Код и хеш — заведомо тестовые (123456).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => I18n.load());
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = ['com.carfog.dryfog/modbus', 'com.carfog.dryfog/system', 'com.carfog.dryfog/storage'];

  const refHash = 'c6f9170ad191ffc5606ab2d615bee43cda9545f16b9bec9357bb996c30de44aa';
  const refSalt = '0102030405060708090a0b0c0d0e0f10';

  AppConfig cfg({bool on = true}) => AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: true,
        servicePin: '4821',
        freeRunEnabled: on,
        freeRunCodeHash: on ? refHash : '',
        freeRunCodeSalt: on ? refSalt : '',
      );

  late AppNotifier n;
  late DateTime now;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudService.resetQueueForTest();
    FreeRunService.resetForTest();
    now = DateTime(2026, 11, 8, 12);
    FreeRunService.clock = () => now;
    FreeRunService.reporter = (t, d) async {};
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (call) async => null);
    }
    n = AppNotifier()..config = cfg();
    n.setBusHealthy(true);
    n.setLanguage('en');
  });

  tearDown(() {
    FreeRunService.resetForTest();
    HardwareProfile.current = HardwareProfile.fallback;
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
  });

  Future<void> pump(WidgetTester t, Widget screen, {bool landscape = false}) async {
    HardwareProfile.current = landscape ? HardwareProfile.ixp101m1 : HardwareProfile.fallback;
    t.view.devicePixelRatio = 1.5;
    t.view.physicalSize = landscape ? const Size(1280, 800) : const Size(1080, 1920);
    addTearDown(t.view.reset);
    await t.pumpWidget(
      ChangeNotifierProvider<AppNotifier>.value(value: n, child: MaterialApp(home: screen)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }

  Future<void> end(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 31));
  }

  Future<void> type(WidgetTester t, String digits) async {
    for (final d in digits.split('')) {
      await t.tap(find.byKey(Key('free_run_key_$d')));
      await t.pump();
    }
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await t.pump();
  }

  group('кнопка на экране PIN', () {
    for (final landscape in [false, true]) {
      final tag = landscape ? 'альбом' : 'портрет';
      testWidgets('функция выключена — кнопки нет ($tag)', (t) async {
        n.config = cfg(on: false);
        await pump(t, const ServicePinScreen(), landscape: landscape);
        expect(find.byKey(const Key('free_run_button')), findsNothing);
        expect(find.text('Free run'), findsNothing);
        await end(t);
      });

      testWidgets('функция включена — кнопка есть и открывает ввод кода ($tag)', (t) async {
        n.transition(AppState.servicePinEntry);
        await pump(t, const ServicePinScreen(), landscape: landscape);
        expect(find.byKey(const Key('free_run_button')), findsOneWidget);
        expect(tester(t), isNull);
        await t.ensureVisible(find.byKey(const Key('free_run_button')));
        await t.tap(find.byKey(const Key('free_run_button')));
        await t.pump();
        expect(n.state, AppState.freeRunEntry);
        await end(t);
      });
    }

    testWidgets('включена, но хеш битый — кнопки нет', (t) async {
      n.config = cfg().copyWith(freeRunCodeHash: 'zz');
      await pump(t, const ServicePinScreen());
      expect(find.byKey(const Key('free_run_button')), findsNothing);
      await end(t);
    });

    testWidgets('блок кода: «Заблокировано, осталось N мин», ввод не открывается', (t) async {
      for (var i = 0; i < 5; i++) {
        await FreeRunService.tryCode(n.config, '00000$i');
      }
      n.transition(AppState.servicePinEntry);
      await pump(t, const ServicePinScreen());
      await t.pump(const Duration(seconds: 2)); // обновление блока по таймеру
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await t.pump(const Duration(seconds: 1));
      expect(find.textContaining('Locked, time left 15'), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('free_run_button')));
      await t.tap(find.byKey(const Key('free_run_button')), warnIfMissed: false);
      await t.pump();
      expect(n.state, AppState.servicePinEntry);
      await end(t);
    });
  });

  group('экран ввода кода', () {
    for (final landscape in [false, true]) {
      testWidgets('верный код → выбор аромата и «взвод»; PIN-экран не нужен (${landscape ? 'альбом' : 'портрет'})', (t) async {
        n.transition(AppState.freeRunEntry);
        await pump(t, const FreeRunScreen(), landscape: landscape);
        await type(t, '123456');
        expect(n.state, AppState.selectFlavor);
        expect(FreeRunService.armed, isTrue);
        expect(n.state, isNot(AppState.serviceMenu));
        await end(t);
      });
    }

    testWidgets('неверный код: сообщение, запуска нет, сервисное меню не открывается', (t) async {
      n.transition(AppState.freeRunEntry);
      await pump(t, const FreeRunScreen());
      await type(t, '000000');
      expect(n.state, AppState.freeRunEntry);
      expect(FreeRunService.armed, isFalse);
      expect(t.widget<Text>(find.byKey(const Key('free_run_message'))).data, contains('4'));
      await end(t);
    });

    testWidgets('сервисный PIN (4 цифры) здесь не принимается и ничего не открывает', (t) async {
      n.transition(AppState.freeRunEntry);
      await pump(t, const FreeRunScreen());
      await type(t, '4821');
      expect(n.state, AppState.freeRunEntry);
      expect(find.byKey(const Key('free_run_dots')), findsOneWidget);
      await end(t);
    });

    testWidgets('после 5 неверных — блок 15 минут, верный код во время блока не работает', (t) async {
      n.transition(AppState.freeRunEntry);
      await pump(t, const FreeRunScreen());
      for (var i = 0; i < 5; i++) {
        await type(t, '00000$i');
      }
      expect(t.widget<Text>(find.byKey(const Key('free_run_message'))).data, contains('15:00'));
      await type(t, '123456');
      expect(n.state, AppState.freeRunEntry);
      await end(t);
    });

    testWidgets('30 секунд без касаний — заставка; касание продлевает', (t) async {
      n.transition(AppState.freeRunEntry);
      await pump(t, const FreeRunScreen());
      await t.pump(const Duration(seconds: 20));
      await t.tap(find.byKey(const Key('free_run_key_1')));
      await t.pump(const Duration(seconds: 20));
      expect(n.state, AppState.freeRunEntry);
      await t.pump(const Duration(seconds: 11));
      expect(n.state, AppState.standby);
    });

    testWidgets('«Отмена» — на заставку', (t) async {
      n.transition(AppState.freeRunEntry);
      await pump(t, const FreeRunScreen());
      await t.tap(find.byKey(const Key('free_run_cancel')));
      await t.pump();
      expect(n.state, AppState.standby);
      await end(t);
    });
  });

  group('выбор аромата в режиме бесплатного запуска', () {
    testWidgets('30 секунд без касаний — заставка, взвод снят', (t) async {
      n.transition(AppState.selectFlavor);
      FreeRunService.arm(onTimeout: () => n.transition(AppState.standby));
      await t.pump(const Duration(seconds: 29));
      expect(n.state, AppState.selectFlavor);
      await t.pump(const Duration(seconds: 2));
      expect(n.state, AppState.standby);
      expect(FreeRunService.armed, isFalse);
    });

    testWidgets('касание продлевает ожидание', (t) async {
      n.transition(AppState.selectFlavor);
      FreeRunService.arm(onTimeout: () => n.transition(AppState.standby));
      await t.pump(const Duration(seconds: 20));
      FreeRunService.touch();
      await t.pump(const Duration(seconds: 20));
      expect(n.state, AppState.selectFlavor);
      await t.pump(const Duration(seconds: 11));
      expect(n.state, AppState.standby);
    });

    testWidgets('выбран аромат — ожидание снято, запуск без оплаты', (t) async {
      n.transition(AppState.selectFlavor);
      FreeRunService.arm(onTimeout: () => n.transition(AppState.standby));
      n.selectFlavor(0);
      expect(n.state, AppState.preparing);
      await t.pump(const Duration(seconds: 40));
      expect(n.state, AppState.preparing, reason: 'таймер не должен сбросить идущий процесс');
    });
  });

  group('счётчики раздельные', () {
    test('ошибки кода не трогают блок PIN, ошибки PIN не трогают код', () async {
      for (var i = 0; i < 4; i++) {
        await FreeRunService.tryCode(n.config, '00000$i');
      }
      expect(await SecurityService.attemptsLeft(), SecurityService.maxAttempts);
      expect(await SecurityService.isLocked(), isFalse);

      await SecurityService.tryPin('0000', '4821');
      await SecurityService.tryPin('0001', '4821');
      expect(await FreeRunService.attemptsLeft(), 1, reason: '5 − 4 ошибки кода');
      // верный PIN не сбрасывает счётчик кода
      expect(await SecurityService.tryPin('4821', '4821'), PinResult.ok);
      expect(await FreeRunService.attemptsLeft(), 1);
    });

    test('блок кода не блокирует PIN и наоборот', () async {
      for (var i = 0; i < 5; i++) {
        await FreeRunService.tryCode(n.config, '00000$i');
      }
      expect(await FreeRunService.remainingLock(), greaterThan(Duration.zero));
      expect(await SecurityService.tryPin('4821', '4821'), PinResult.ok);

      SharedPreferences.setMockInitialValues({});
      for (var i = 0; i < 3; i++) {
        await SecurityService.tryPin('000$i', '4821');
      }
      expect(await SecurityService.isLocked(), isTrue);
      expect(await FreeRunService.tryCode(n.config, '123456'), FreeRunResult.ok);
    });

    test('код бесплатного запуска не проходит как PIN и мастер-код', () async {
      expect(await SecurityService.tryPin('123456', '4821'), PinResult.wrong);
      expect(await FreeRunService.tryCode(n.config, '4821'), FreeRunResult.wrong);
    });
  });

  testWidgets('в сервисном меню вкладки «Бесплатный запуск» больше нет (функция включена)', (t) async {
    n.transition(AppState.serviceMenu);
    await pump(t, const ServiceMenuScreen(), landscape: true);
    for (final label in ['Бесплатный запуск', 'Free run', 'Tasuta käivitus']) {
      expect(find.text(label), findsNothing);
    }
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
  });
}

Object? tester(WidgetTester t) => t.takeException();
