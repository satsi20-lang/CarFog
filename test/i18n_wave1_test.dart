import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/device_spec.dart';
import 'package:dry_fog_app/screens/error.dart';
import 'package:dry_fog_app/screens/finished.dart';
import 'package:dry_fog_app/screens/language_select.dart';
import 'package:dry_fog_app/screens/out_of_service.dart';
import 'package:dry_fog_app/screens/payment.dart';
import 'package:dry_fog_app/screens/preparing.dart';
import 'package:dry_fog_app/screens/select_flavor.dart';
import 'package:dry_fog_app/screens/standby.dart';
import 'package:dry_fog_app/screens/treating.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:dry_fog_app/widgets/lang_switcher.dart';

// Переводы, волна 1 (lv, lt, fi, sv, pl, de, fr): ЧЕРНОВИКИ машинного
// перевода, статус draft. Проверяются файлы, длины, макет и то, что на боевом
// аппарате они не показываются. Скриншоты de/fr/fi:
// SCREENSHOT_DIR=/путь flutter test test/i18n_wave1_test.dart (не в репозиторий).
const wave1 = ['lv', 'lt', 'fi', 'sv', 'pl', 'de', 'fr'];

// Перевод дословно равен en — допустимо только здесь (единица «s» та же).
const sameAsEnAllowed = {'treating.seconds'};

// Длина перевода > 1,8 × en допустима только для коротких строк en (≤ 12
// символов), где естественный перевод длиннее; макет этих экранов проверен
// ниже. Список — в отчёте и в листе носителя.
const longAllowed = {
  'fr': {'standby.subtitle'}, // BROUILLARD SEC / DRY FOG
  'fi': {'payment.paid'}, // Maksettu / Paid
  'pl': {'treating.cancel_yes'}, // Przerwać / Stop
  'lv': {'standby.tap_to_start', 'payment.paid', 'treating.cancel_yes'},
  'lt': {'standby.tap_to_start', 'treating.cancel_yes'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shotDir = Platform.environment['SCREENSHOT_DIR'];
  const dir = 'assets/i18n';
  Map<String, String> read(String code) =>
      (jsonDecode(File('$dir/$code.json').readAsStringSync()) as Map).cast<String, String>();
  final en = read('en');
  final manifest = (jsonDecode(File('$dir/manifest.json').readAsStringSync()) as Map)['languages'] as Map;

  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = ['com.carfog.dryfog/system', 'com.carfog.dryfog/modbus', 'com.carfog.dryfog/storage'];
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (call) async => null);
    }
    await I18n.load();
  });
  tearDown(() {
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
    I18n.showDrafts = false;
  });

  group('файлы волны 1', () {
    for (final l in wave1) {
      test('$l: ключи, параметры, пустые, равные en, длина', () {
        final raw = File('$dir/$l.json').readAsStringSync();
        expect(() => utf8.decode(File('$dir/$l.json').readAsBytesSync()), returnsNormally);
        final d = read(l);
        expect(d.keys.toSet(), en.keys.toSet());
        expect(d.length, 64);
        final tooLong = <String>[];
        for (final k in en.keys) {
          final v = d[k]!;
          expect(v.trim(), isNotEmpty, reason: '$l $k');
          expect(I18n.paramsOf(v), I18n.paramsOf(en[k]!), reason: '$l $k');
          if (!sameAsEnAllowed.contains(k)) expect(v, isNot(en[k]), reason: '$l $k равен en');
          if (v.length / en[k]!.length > 1.8 && !(longAllowed[l]?.contains(k) ?? false)) tooLong.add(k);
        }
        expect(tooLong, isEmpty, reason: '$l: длиннее en в 1,8 раза');
        // Заглавные заголовки остаются заглавными.
        for (final k in en.keys.where((k) => en[k] == en[k]!.toUpperCase() && RegExp('[A-Z]').hasMatch(en[k]!))) {
          expect(d[k], d[k]!.toUpperCase(), reason: '$l $k');
        }
        expect(raw.contains('�'), isFalse);
      });
    }

    test('manifest: семь языков — draft, version 1; released по-прежнему et/en/ru', () {
      for (final l in wave1) {
        expect(manifest[l]['status'], 'draft', reason: l);
        expect(manifest[l]['version'], 1, reason: l);
      }
      expect(I18n.releasedLangs.toSet(), {'et', 'en', 'ru'});
      expect(I18n.availableLangs.toSet(), {'et', 'en', 'ru'});
      for (final l in wave1) {
        expect(I18n.hasFile(l), isTrue, reason: l);
      }
    });
  });

  group('показ', () {
    test('spec с языками волны: без тумблера только et/en/ru, с тумблером — в порядке spec', () {
      final s = DeviceSpec.tryParse({
        'langs': ['de', 'et', 'fi', 'en', 'lv', 'ru', 'sv', 'pl', 'lt', 'fr'],
        'default_lang': 'de',
      })!;
      expect(s.displayLangs, ['et', 'en', 'ru']);
      expect(s.displayDefaultLang, 'et');
      I18n.showDrafts = true;
      expect(s.displayLangs, ['de', 'et', 'fi', 'en', 'lv', 'ru', 'sv', 'pl', 'lt', 'fr']);
      expect(s.displayDefaultLang, 'de');
    });
  });

  void portrait(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1080, 1920);
    addTearDown(tester.view.reset);
  }

  AppNotifier notifierFor(String lang, {bool meter = false, List<String>? langs}) {
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: meter,
        specLangs: langs ?? ['et', 'en', 'ru', ...wave1],
        specDefaultLang: 'et',
      );
    n.initLanguage();
    n.setLanguage(lang);
    n.updateLevels([true, false, true, true, true, true, true, true]);
    return n;
  }

  Future<void> disposeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  final screens = <String, Widget Function()>{
    'standby': () => const StandbyScreen(),
    'language_select': () => const LanguageSelectScreen(),
    'select_flavor': () => const SelectFlavorScreen(),
    'payment': () => const PaymentScreen(),
    'payment_card': () => const PaymentScreen(),
    'preparing': () => const PreparingScreen(),
    'treating': () => const TreatingScreen(),
    'finished': () => const FinishedScreen(),
    'error': () => const ErrorScreen(),
    'out_of_service': () => const OutOfServiceScreen(),
  };

  group('макет 720x1280', () {
    for (final l in wave1) {
      for (final e in screens.entries) {
        testWidgets('${e.key} [$l] без переполнения', (tester) async {
          portrait(tester);
          I18n.showDrafts = true;
          final n = notifierFor(l, meter: e.key != 'preparing');
          if (e.key == 'payment_card') n.config = n.config.copyWith(paymentTerminalEnabled: true);
          if (e.key == 'error') n.goToError('heater_failure');
          await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
            value: n,
            child: MaterialApp(home: e.value()),
          ));
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull);
          expect(I18n.missingKeys, isEmpty);
          if (e.key == 'treating') {
            await tester.tap(find.byType(OutlinedButton));
            await tester.pump(const Duration(milliseconds: 400));
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          await disposeScreen(tester);
        });
      }
      testWidgets('все коды ошибок [$l] без переполнения', (tester) async {
        portrait(tester);
        I18n.showDrafts = true;
        for (final code in ['overheat', 'timeout', 'sensor', 'generic', 'bus_unavailable',
            'coin_acceptor_unavailable', 'heater_failure', 'heater_sensor_fault']) {
          final n = notifierFor(l)..goToError(code);
          await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
            value: n,
            child: const MaterialApp(home: ErrorScreen()),
          ));
          await tester.pump(const Duration(milliseconds: 600));
          expect(tester.takeException(), isNull, reason: code);
          await disposeScreen(tester);
        }
      });
    }

    testWidgets('выбор языка при 10 языках (et en ru + 7 черновиков): сетка, без переполнения', (tester) async {
      portrait(tester);
      I18n.showDrafts = true;
      final n = notifierFor('et');
      expect(n.displayLangs.length, 10);
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: LanguageSelectScreen()),
      ));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.byType(ElevatedButton), findsNWidgets(10));
      for (final name in ['Latviešu', 'Lietuvių', 'Suomi', 'Svenska', 'Polski', 'Deutsch', 'Français']) {
        await tester.ensureVisible(find.text(name));
        expect(find.text(name), findsOneWidget);
      }
      // и окно переключателя на экране
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: MaterialApp(
          home: Scaffold(body: LangSwitcher(current: 'et', langs: n.displayLangs, onChanged: (_) {})),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey('lang_compact')));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });

  group('скриншоты de/fr/fi', () {
    Future<void> loadFonts() async {
      final sdk = Platform.environment['FLUTTER_ROOT'] ?? '/usr/local/share/flutter';
      final base = '$sdk/bin/cache/artifacts/material_fonts';
      Future<ByteData> bytes(String n) async => ByteData.sublistView(await File('$base/$n').readAsBytes());
      final roboto = FontLoader('Roboto')
        ..addFont(bytes('Roboto-Regular.ttf'))
        ..addFont(bytes('Roboto-Bold.ttf'));
      await roboto.load();
      final icons = FontLoader('MaterialIcons')..addFont(bytes('MaterialIcons-Regular.otf'));
      await icons.load();
    }

    final shots = <String, Widget Function()>{
      'language_select': () => const LanguageSelectScreen(),
      'payment': () => const PaymentScreen(),
      'treating': () => const TreatingScreen(),
      'error': () => const ErrorScreen(),
    };
    for (final l in ['de', 'fr', 'fi']) {
      for (final e in shots.entries) {
        testWidgets('снимок ${e.key} [$l]', (tester) async {
          await tester.runAsync(loadFonts);
          portrait(tester);
          I18n.showDrafts = true;
          final n = notifierFor(l, meter: true);
          if (e.key == 'payment') n.config = n.config.copyWith(paymentTerminalEnabled: true);
          if (e.key == 'error') n.goToError('heater_failure');
          final key = GlobalKey();
          await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
            value: n,
            child: RepaintBoundary(
              key: key,
              child: MaterialApp(theme: ThemeData(fontFamily: 'Roboto'), home: e.value()),
            ),
          ));
          await tester.pump(const Duration(milliseconds: 800));
          await tester.runAsync(() async {
            final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
            final img = await b.toImage(pixelRatio: 1.5);
            final data = await img.toByteData(format: ui.ImageByteFormat.png);
            final f = File('$shotDir/${e.key}_$l.png');
            await f.create(recursive: true);
            await f.writeAsBytes(data!.buffer.asUint8List());
          });
          expect(tester.takeException(), isNull);
          await disposeScreen(tester);
        }, skip: shotDir == null);
      }
    }
  });
}
