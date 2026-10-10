import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:dry_fog_app/screens/service/service_menu.dart';
import 'package:dry_fog_app/screens/service/service_pin.dart';
import 'package:dry_fog_app/screens/standby.dart';
import 'package:dry_fog_app/screens/treating.dart';

// Снимки экранов в портрете 720x1280 dp (1080x1920 px) для визуальной
// проверки. Запуск: SCREENSHOT_DIR=/путь flutter test test/portrait_screenshots_test.dart
// Без переменной тест пропускается; снимки в репозиторий НЕ кладутся.
// Шрифты Roboto/MaterialIcons берутся из кэша Flutter SDK (в тестах по
// умолчанию рисуются квадраты).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Platform.environment['SCREENSHOT_DIR'];

  Future<void> loadFonts() async {
    final sdk = Platform.environment['FLUTTER_ROOT'] ?? '/usr/local/share/flutter';
    final base = '$sdk/bin/cache/artifacts/material_fonts';
    Future<ByteData> bytes(String n) async =>
        ByteData.sublistView(await File('$base/$n').readAsBytes());
    final roboto = FontLoader('Roboto')
      ..addFont(bytes('Roboto-Regular.ttf'))
      ..addFont(bytes('Roboto-Bold.ttf'));
    await roboto.load();
    final icons = FontLoader('MaterialIcons')..addFont(bytes('MaterialIcons-Regular.otf'));
    await icons.load();
  }

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final shots = <String, Widget Function()>{
    '01_language': () => const LanguageSelectScreen(),
    '02_standby': () => const StandbyScreen(),
    '03_select_flavor': () => const SelectFlavorScreen(),
    '03b_flavor_5': () => const SelectFlavorScreen(),
    '03c_flavor_6': () => const SelectFlavorScreen(),
    '03d_flavor_7': () => const SelectFlavorScreen(),
    '03e_flavor_8': () => const SelectFlavorScreen(),
    '04_payment': () => const PaymentScreen(),
    '05_preparing': () => const PreparingScreen(),
    '06_treating': () => const TreatingScreen(),
    '07_finished': () => const FinishedScreen(),
    '08_error': () => const ErrorScreen(),
    '09_out_of_service': () => const OutOfServiceScreen(),
    '10_service_pin': () => const ServicePinScreen(),
    '11_service_menu_settings': () => const ServiceMenuScreen(),
    '12_service_menu_diagnostics_port': () => const ServiceMenuScreen(),
  };

  for (final lang in ['ru', 'et']) {
    for (final e in shots.entries) {
      testWidgets('снимок ${e.key} [$lang]', (tester) async {
        SharedPreferences.setMockInitialValues({});
        for (final c in ['system', 'modbus', 'storage']) {
          messenger.setMockMethodCallHandler(
              MethodChannel('com.carfog.dryfog/$c'), (call) async => null);
        }
        await tester.runAsync(loadFonts);
        tester.view.devicePixelRatio = 1.5;
        tester.view.physicalSize = const Size(1080, 1920);
        addTearDown(tester.view.reset);
        final pumps = {'03b_flavor_5': 5, '03c_flavor_6': 6, '03d_flavor_7': 7, '03e_flavor_8': 8}[e.key] ?? 4;
        final n = AppNotifier()
          ..config = AppConfig(
              specPumps: pumps,
              thermoInstalled: true, energyMeterInstalled: e.key != '05_preparing')
          ..updateLevels([true, false, true, true, true, true, true, true]);
        n.setLanguage(lang);
        if (e.key == '08_error') n.goToError('bus_unavailable');
        final key = GlobalKey();
        await tester.pumpWidget(
          ChangeNotifierProvider<AppNotifier>.value(
            value: n,
            child: RepaintBoundary(
              key: key,
              child: MaterialApp(
                theme: ThemeData(fontFamily: 'Roboto'),
                home: e.value(),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 800));
        if (e.key.startsWith('12_')) {
          // Окно «Мастер-код этого аппарата» закрываем (оно открывается при
          // первом входе), затем вкладка «Диагностика» (третья) — там
          // секция «Порт шины RS485».
          final dlg = find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextButton),
          );
          if (dlg.evaluate().isNotEmpty) {
            await tester.tap(dlg.last);
            await tester.pump(const Duration(milliseconds: 600));
          }
          final tabRow = find.descendant(
            of: find.byType(SingleChildScrollView).first,
            matching: find.byType(GestureDetector),
          );
          await tester.tap(tabRow.at(2), warnIfMissed: false);
          await tester.pump(const Duration(milliseconds: 800));
        }
        await tester.runAsync(() async {
          final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final img = await b.toImage(pixelRatio: 1.5);
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          final f = File('$dir/${e.key}_$lang.png');
          await f.create(recursive: true);
          await f.writeAsBytes(data!.buffer.asUint8List());
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
      }, skip: dir == null);
    }
  }
}
