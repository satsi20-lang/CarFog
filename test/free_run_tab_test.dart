import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/screens/service/free_run_tab.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/free_run_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Вкладка «Бесплатный запуск»: ввод 6 цифр, неверный код, блок, таймаут 30 с.
void main() {
  const refHash = 'c6f9170ad191ffc5606ab2d615bee43cda9545f16b9bec9357bb996c30de44aa';
  const refSalt = '0102030405060708090a0b0c0d0e0f10';

  late AppNotifier n;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudService.resetQueueForTest();
    FreeRunService.resetForTest();
    FreeRunService.reporter = (t, d) async {};
    n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: true,
        freeRunEnabled: true,
        freeRunCodeHash: refHash,
        freeRunCodeSalt: refSalt,
      );
    n.setBusHealthy(true);
    n.transition(AppState.serviceMenu);
  });

  tearDown(FreeRunService.resetForTest);

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(
      ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: Scaffold(body: FreeRunTab())),
      ),
    );
    await t.pump();
  }

  Future<void> type(WidgetTester t, String digits) async {
    for (final d in digits.split('')) {
      await t.tap(find.byKey(Key('free_run_key_$d')));
      await t.pump();
    }
    // Проверка PBKDF2 идёт настоящими вычислениями.
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
    await t.pump();
  }

  testWidgets('верный код: взвод и экран выбора аромата', (t) async {
    await pump(t);
    await type(t, '123456');
    expect(n.state, AppState.selectFlavor);
    expect(FreeRunService.armed, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 31));
  });

  testWidgets('неверный код: сообщение с числом попыток, поле очищено, запуска нет', (t) async {
    await pump(t);
    await type(t, '000000');
    expect(n.state, AppState.serviceMenu);
    expect(FreeRunService.armed, isFalse);
    final msg = t.widget<Text>(find.byKey(const Key('free_run_message'))).data!;
    expect(msg, contains('4'));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 31));
  });

  testWidgets('после 5 неверных ввод заблокирован, кнопки не работают', (t) async {
    await pump(t);
    for (var i = 0; i < 5; i++) {
      await type(t, '00000$i');
    }
    final msg = t.widget<Text>(find.byKey(const Key('free_run_message'))).data!;
    expect(msg, contains('15:00'));
    await type(t, '123456'); // верный, но блок
    expect(n.state, AppState.serviceMenu);
    expect(FreeRunService.armed, isFalse);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 31));
  });

  testWidgets('30 секунд без касаний — назад на заставку; касание продлевает', (t) async {
    await pump(t);
    await t.pump(const Duration(seconds: 20));
    await t.tap(find.byKey(const Key('free_run_key_1')));
    await t.pump(const Duration(seconds: 20));
    expect(n.state, AppState.serviceMenu, reason: 'касание продлило ожидание');
    await t.pump(const Duration(seconds: 11));
    expect(n.state, AppState.standby);
  });
}
