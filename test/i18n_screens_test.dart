import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/screens/error.dart';
import 'package:dry_fog_app/screens/finished.dart';
import 'package:dry_fog_app/screens/language_select.dart';
import 'package:dry_fog_app/screens/out_of_service.dart';
import 'package:dry_fog_app/screens/payment.dart';
import 'package:dry_fog_app/screens/preparing.dart';
import 'package:dry_fog_app/screens/select_flavor.dart';
import 'package:dry_fog_app/screens/standby.dart';
import 'package:dry_fog_app/screens/treating.dart';

// Тексты клиентских экранов на et/en/ru те же, что были до переноса таблиц в
// assets/i18n (эталон test/fixtures/i18n_baseline.json снят на коде 1.9.1+24).
// Сравниваются наборы строк экрана (порядок строк многоязычных заголовков
// теперь задаёт spec, поэтому сравнение без учёта порядка).
// Пересъёмка эталона: I18N_CAPTURE=1 flutter test test/i18n_screens_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final capture = Platform.environment['I18N_CAPTURE'] == '1';
  const fixture = 'test/fixtures/i18n_baseline.json';
  final captured = <String, List<String>>{};

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
  });

  tearDown(() {
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
  });

  tearDownAll(() {
    if (!capture) return;
    final sorted = Map.fromEntries(
      captured.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    File(fixture).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(sorted)}\n',
    );
  });

  const errorCodes = [
    'overheat',
    'timeout',
    'sensor',
    'generic',
    'bus_unavailable',
    'coin_acceptor_unavailable',
    'heater_failure',
    'heater_sensor_fault',
  ];

  // Сценарий: имя → (экран, донастройка уведомителя, действие после показа).
  final scenarios = <String, (Widget Function(), void Function(AppNotifier)?, Future<void> Function(WidgetTester)?)>{
    'standby': (() => const StandbyScreen(), null, null),
    'language_select': (() => const LanguageSelectScreen(), null, null),
    'select_flavor': (() => const SelectFlavorScreen(), null, null),
    'payment': (() => const PaymentScreen(), null, null),
    'payment_card': (
      () => const PaymentScreen(),
      (n) => n.config = n.config.copyWith(paymentTerminalEnabled: true),
      null,
    ),
    'preparing': (() => const PreparingScreen(), null, null),
    'treating': (() => const TreatingScreen(), null, null),
    'treating_cancel_dialog': (
      () => const TreatingScreen(),
      null,
      (tester) async {
        await tester.tap(find.byType(OutlinedButton));
        await tester.pump(const Duration(milliseconds: 400));
      },
    ),
    'finished': (() => const FinishedScreen(), null, null),
    'out_of_service': (() => const OutOfServiceScreen(), null, null),
    for (final code in errorCodes)
      'error_$code': (() => const ErrorScreen(), (n) => n.goToError(code), null),
  };

  Map<String, dynamic>? baseline;
  if (!capture) {
    baseline = jsonDecode(File(fixture).readAsStringSync()) as Map<String, dynamic>;
  }

  for (final lang in ['et', 'en', 'ru']) {
    for (final e in scenarios.entries) {
      final name = '${e.key}/$lang';
      testWidgets('тексты экрана $name совпадают с эталоном', (tester) async {
        tester.view.devicePixelRatio = 1.5;
        tester.view.physicalSize = const Size(1080, 1920);
        addTearDown(tester.view.reset);
        final n = AppNotifier()
          ..config = AppConfig(
            thermoInstalled: true,
            // preparing при установленном счётчике ждёт мощность по реальному
            // времени — для текстов счётчик не нужен.
            energyMeterInstalled: !e.key.startsWith('preparing'),
          );
        n.setLanguage(lang);
        n.updateLevels([true, false, true, true, true, true, true, true]);
        e.value.$2?.call(n);
        await tester.pumpWidget(
          ChangeNotifierProvider<AppNotifier>.value(
            value: n,
            child: MaterialApp(home: e.value.$1()),
          ),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await e.value.$3?.call(tester);
        final texts = tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
            .toList()
          ..sort();
        expect(tester.takeException(), isNull);
        if (capture) {
          captured[name] = texts;
        } else {
          final want = (baseline![name] as List).cast<String>();
          expect(texts, want, reason: name);
        }
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
      });
    }
  }
}
