import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/remote_limits.dart';
import 'package:dry_fog_app/screens/language_select.dart';
import 'package:dry_fog_app/screens/select_flavor.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/card_terminal_service.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/session_service.dart';

// 1.11.6: возврат на заставку при бездействии на выборе языка и запаха.
// Время подставное (fake async testWidgets): tester.pump двигает часы.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const system = MethodChannel('com.carfog.dryfog/system');
  const storage = MethodChannel('com.carfog.dryfog/storage');
  const modbus = MethodChannel('com.carfog.dryfog/modbus');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.resetForTest();
    CardTerminalService.resetForTest();
    for (final c in [system, storage, modbus]) {
      messenger.setMockMethodCallHandler(c, (_) async => null);
    }
  });
  tearDown(() {
    SessionService.discard();
    CardTerminalService.resetForTest();
    for (final c in [system, storage, modbus]) {
      messenger.setMockMethodCallHandler(c, null);
    }
  });

  AppNotifier notifier(AppState s, {int idleS = 60}) {
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: true,
        idleReturnS: idleS,
        specLangs: const ['et', 'en', 'ru'],
      );
    n.setBusHealthy(true);
    n.updateLevels(List.filled(8, true));
    n.transition(s);
    return n;
  }

  // Мини-роутер: экран есть, пока стоит его состояние (как AppRouter).
  Future<void> pumpScreens(WidgetTester tester, AppNotifier n) async {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1080, 1920);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: MaterialApp(
          home: Consumer<AppNotifier>(
            builder: (_, n, _) => switch (n.state) {
              AppState.selectFlavor => const SelectFlavorScreen(),
              AppState.selectLanguage => const LanguageSelectScreen(),
              _ => const SizedBox.shrink(key: ValueKey('other')),
            },
          ),
        ),
      ),
    );
  }

  // testWidgets + сброс журнала AppLog в конце (его секундный таймер иначе
  // остаётся висеть после теста).
  void testIdle(String name, Future<void> Function(WidgetTester) body) =>
      testWidgets(name, (tester) async {
        await body(tester);
        await tester.pump(const Duration(seconds: 2));
      });

  // Касание пустого места экрана (не кнопки).
  Future<void> touch(WidgetTester tester) async {
    await tester.tapAt(const Offset(20, 300));
    await tester.pump();
  }

  for (final s in [AppState.selectFlavor, AppState.selectLanguage]) {
    group(s.name, () {
      testIdle('60 с без касаний → заставка, не раньше', (tester) async {
        final n = notifier(s);
        await pumpScreens(tester, n);
        await tester.pump(const Duration(seconds: 59));
        expect(n.state, s);
        await tester.pump(const Duration(seconds: 1));
        expect(n.state, AppState.standby);
        expect(find.byKey(const ValueKey('other')), findsOneWidget);
      });

      testIdle('касание сбрасывает отсчёт', (tester) async {
        final n = notifier(s);
        await pumpScreens(tester, n);
        await tester.pump(const Duration(seconds: 40));
        await touch(tester);
        expect(n.state, s, reason: 'касание пустого места состояние не меняет');
        await tester.pump(const Duration(seconds: 59));
        expect(n.state, s, reason: '99 с с открытия, но 59 с с касания');
        await tester.pump(const Duration(seconds: 1));
        expect(n.state, AppState.standby);
      });

      testIdle('время берётся из настройки (15 с)', (tester) async {
        final n = notifier(s, idleS: 15);
        await pumpScreens(tester, n);
        await tester.pump(const Duration(seconds: 14));
        expect(n.state, s);
        await tester.pump(const Duration(seconds: 1));
        expect(n.state, AppState.standby);
      });
    });
  }

  group('отмена', () {
    testIdle('ушли с экрана (оплата) — таймер отменён, на заставку не уходим', (
      tester,
    ) async {
      final n = notifier(AppState.selectFlavor);
      await pumpScreens(tester, n);
      await tester.pump(const Duration(seconds: 30));
      n.transition(AppState.payment);
      await tester.pump();
      expect(find.byType(SelectFlavorScreen), findsNothing);
      await tester.pump(const Duration(minutes: 5));
      expect(n.state, AppState.payment);
    });

    testIdle('экран ещё на месте, но состояние сменилось — не срабатывает', (
      tester,
    ) async {
      final n = notifier(AppState.selectFlavor);
      await pumpScreens(tester, n);
      // Экран без роутера: смена состояния его не убирает.
      await tester.pumpWidget(
        ChangeNotifierProvider<AppNotifier>.value(
          value: n,
          child: const MaterialApp(home: SelectFlavorScreen()),
        ),
      );
      n.transition(AppState.serviceMenu);
      await tester.pump(const Duration(seconds: 61));
      expect(n.state, AppState.serviceMenu);
    });

    testIdle(
      'другие экраны (оплата, обработка, ошибка, сервис) таймера не имеют',
      (tester) async {
        for (final s in [
          AppState.payment,
          AppState.treating,
          AppState.error,
          AppState.serviceMenu,
        ]) {
          final n = notifier(s);
          await pumpScreens(tester, n);
          await tester.pump(const Duration(minutes: 5));
          expect(n.state, s, reason: s.name);
        }
      },
    );
  });

  group('деньги', () {
    testIdle(
      'идёт сессия (оплачено) — не уходим, отсчёт заново; кончилась — уходим',
      (tester) async {
        final n = notifier(AppState.selectFlavor);
        await tester.runAsync(
          () => SessionService.start(
            flavorIndex: 0,
            flavorNameRu: 'Лимон',
            priceCents: 200,
            paidCents: 200,
            readStartEnergy: false,
          ),
        );
        expect(SessionService.currentSessionId, isNotNull);
        await pumpScreens(tester, n);
        await tester.pump(const Duration(seconds: 60));
        expect(n.state, AppState.selectFlavor);
        await tester.pump(const Duration(seconds: 120));
        expect(n.state, AppState.selectFlavor);
        expect(
          SessionService.currentSessionId,
          isNotNull,
          reason: 'сессия не тронута',
        );
        SessionService.discard();
        await tester.pump(const Duration(seconds: 60));
        expect(n.state, AppState.standby);
      },
    );

    for (final (label, status) in <(String, CardTerminalStatus)>[
      (
        'сессия терминала открыта',
        const CardTerminalStatus(state: 'READY', inSession: true),
      ),
      (
        'оплата картой в процессе',
        const CardTerminalStatus(state: 'READY', paymentState: 'VENDING'),
      ),
      (
        'ожидается возврат после перезапуска',
        const CardTerminalStatus(state: 'READY', recoveryPending: true),
      ),
    ]) {
      testIdle('$label — не уходим', (tester) async {
        final n = notifier(AppState.selectFlavor);
        CardTerminalService.status.value = status;
        await pumpScreens(tester, n);
        await tester.pump(const Duration(seconds: 180));
        expect(n.state, AppState.selectFlavor);
        CardTerminalService.status.value = const CardTerminalStatus(
          state: 'READY',
        );
        await tester.pump(const Duration(seconds: 60));
        expect(n.state, AppState.standby);
      });
    }

    testIdle('карта приложена без выбора запаха — отсчёт заново', (
      tester,
    ) async {
      final n = notifier(AppState.selectFlavor);
      await pumpScreens(tester, n);
      await tester.pump(const Duration(seconds: 50));
      CardTerminalService.tappedWithoutFlavorAt.value = DateTime(
        2026,
        10,
        27,
        12,
      );
      await tester.pump(const Duration(seconds: 59));
      expect(n.state, AppState.selectFlavor);
      await tester.pump(const Duration(seconds: 1));
      expect(n.state, AppState.standby);
    });
  });

  group('настройка', () {
    test('по умолчанию 60 с, пределы 15–300', () {
      expect(AppConfig().idleReturnS, 60);
      expect(ConfigLimits.range('idleReturnS'), (min: 15, max: 300));
      expect(
        ConfigLimits.numericFields,
        isNot(contains('idleReturnS')),
        reason: 'удалённо не меняется',
      );
    });

    test('сохраняется и загружается; вне 15–300 или мусор — 60', () async {
      await ConfigService.save(AppConfig(idleReturnS: 120));
      expect((await ConfigService.load()).idleReturnS, 120);
      for (final bad in [14, 301, '90', null]) {
        SharedPreferences.setMockInitialValues({
          'app_config': '{"idleReturnS": ${bad is String ? '"$bad"' : bad}}',
        });
        expect((await ConfigService.load()).idleReturnS, 60, reason: '$bad');
      }
      expect(
        AppConfig(idleReturnS: 45).reportedSnapshot()['idle_return_s'],
        45,
      );
    });
  });
}
