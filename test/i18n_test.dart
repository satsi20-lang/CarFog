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
import 'package:dry_fog_app/screens/service/service_menu.dart';
import 'package:dry_fog_app/screens/standby.dart';
import 'package:dry_fog_app/screens/treating.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:dry_fog_app/widgets/lang_switcher.dart';
import 'package:dry_fog_app/widgets/portrait_ui.dart';

// Переводы в файлах (часть 3a спецификации аппарата): содержимое
// assets/i18n, запасная цепочка, повреждённые файлы, набор показываемых
// языков, язык по умолчанию, названия ароматов, переключатель, макет экрана
// выбора языка и длинные строки. Скриншоты экрана выбора языка (1/3/5/8/24
// языков): SCREENSHOT_DIR=/путь flutter test test/i18n_test.dart — в
// репозиторий не кладутся.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shotDir = Platform.environment['SCREENSHOT_DIR'];

  const dir = 'assets/i18n';
  final manifestRaw = File('$dir/manifest.json').readAsStringSync();
  final manifest =
      (jsonDecode(manifestRaw) as Map<String, dynamic>)['languages'] as Map<String, dynamic>;
  Map<String, String> readDict(String code) =>
      (jsonDecode(File('$dir/$code.json').readAsStringSync()) as Map).cast<String, String>();
  final files = {
    for (final code in manifest.keys)
      if (File('$dir/$code.json').existsSync()) code: File('$dir/$code.json').readAsStringSync(),
  };

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

  // Все языки каталога «с файлом» (копия en) и статусом draft, кроме
  // et/en/ru: имитация переведённых, но не выпущенных языков.
  // Заголовок «Язык» для черновиков (тестовые данные, проверка длинного
  // многоязычного заголовка и глифов; не перевод для аппарата).
  const languageWord = {
    'bg': 'ЕЗИК', 'cs': 'JAZYK', 'da': 'SPROG', 'de': 'SPRACHE', 'el': 'ΓΛΩΣΣΑ',
    'es': 'IDIOMA', 'fi': 'KIELI', 'fr': 'LANGUE', 'ga': 'TEANGA', 'hr': 'JEZIK',
    'hu': 'NYELV', 'it': 'LINGUA', 'lt': 'KALBA', 'lv': 'VALODA', 'mt': 'LINGWA',
    'nl': 'TAAL', 'pl': 'JĘZYK', 'pt': 'IDIOMA', 'ro': 'LIMBĂ', 'sk': 'JAZYK',
    'sl': 'JEZIK', 'sv': 'SPRÅK', 'uk': 'МОВА', 'no': 'SPRÅK',
  };

  void loadDraftCatalog({Map<String, Map<String, String>> override = const {}}) {
    final en = readDict('en');
    Map<String, String> draft(String code) =>
        {...en, if (languageWord[code] != null) 'language_select.title': languageWord[code]!};
    I18n.loadFromStrings(
      manifest: manifestRaw,
      files: {
        for (final code in DeviceSpec.catalog)
          code: jsonEncode(override[code] ?? (files.containsKey(code) ? readDict(code) : draft(code))),
      },
    );
  }

  void portrait(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1080, 1920);
    addTearDown(tester.view.reset);
  }

  AppNotifier notifierFor({
    List<String> langs = const ['et', 'en', 'ru'],
    String? defaultLang,
    String? lang,
    Map<String, List<String>>? flavorNames,
    bool meter = false,
  }) {
    // meter: счётчик отмечен установленным — без него оплата заблокирована
    // (для экранов после выбора аромата); preparing без него не ждёт мощность.
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: meter,
        specLangs: langs,
        specDefaultLang: defaultLang ?? langs.first,
        flavorNames: flavorNames,
      );
    n.initLanguage();
    if (lang != null) n.setLanguage(lang);
    n.updateLevels([true, false, true, true, true, true, true, true]);
    return n;
  }

  Future<void> pump(WidgetTester tester, Widget screen, AppNotifier n) async {
    await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
      value: n,
      child: MaterialApp(home: screen),
    ));
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> disposeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  group('файлы переводов', () {
    test('manifest: 27 языков каталога, родные названия, released только et/en/ru', () {
      expect(manifest.keys.toSet(), DeviceSpec.catalog.toSet());
      const names = {
        'bg': 'Български', 'cs': 'Čeština', 'da': 'Dansk', 'de': 'Deutsch', 'el': 'Ελληνικά',
        'en': 'English', 'es': 'Español', 'et': 'Eesti', 'fi': 'Suomi', 'fr': 'Français',
        'ga': 'Gaeilge', 'hr': 'Hrvatski', 'hu': 'Magyar', 'it': 'Italiano', 'lt': 'Lietuvių',
        'lv': 'Latviešu', 'mt': 'Malti', 'nl': 'Nederlands', 'no': 'Norsk', 'pl': 'Polski',
        'pt': 'Português', 'ro': 'Română', 'ru': 'Русский', 'sk': 'Slovenčina',
        'sl': 'Slovenščina', 'sv': 'Svenska', 'uk': 'Українська',
      };
      for (final e in manifest.entries) {
        final v = e.value as Map<String, dynamic>;
        expect(v['name'], names[e.key], reason: e.key);
        expect(v['status'], anyOf('released', 'draft'), reason: e.key);
        expect(v['version'], isA<int>(), reason: e.key);
      }
      final released = manifest.entries.where((e) => e.value['status'] == 'released').map((e) => e.key);
      expect(released.toSet(), {'et', 'en', 'ru'});
      expect(I18n.releasedLangs.toSet(), {'et', 'en', 'ru'});
      expect(I18n.nativeName('el'), 'Ελληνικά');
    });

    test('у каждого файла: плоский словарь строк, ключи как в en, те же параметры {…}', () {
      final en = readDict('en');
      expect(en, isNotEmpty);
      for (final code in files.keys) {
        expect(manifest.containsKey(code), isTrue, reason: 'файл $code.json без строки в manifest');
        final raw = jsonDecode(files[code]!) as Map<String, dynamic>;
        for (final v in raw.values) {
          expect(v, isA<String>(), reason: code);
        }
        final d = raw.cast<String, String>();
        expect(d.keys.toSet().difference(en.keys.toSet()), isEmpty, reason: 'лишние ключи в $code');
        expect(en.keys.toSet().difference(d.keys.toSet()), isEmpty, reason: 'нет ключей в $code');
        for (final k in d.keys) {
          expect(I18n.paramsOf(d[k]!), I18n.paramsOf(en[k]!), reason: '$code: $k');
        }
        if (manifest[code]['status'] == 'released') {
          for (final e in d.entries) {
            expect(e.value.trim(), isNotEmpty, reason: '$code: пустая строка ${e.key}');
          }
        }
      }
    });

    test('ключи — с префиксом клиентского экрана', () {
      const screens = {
        'standby', 'language_select', 'select_flavor', 'payment', 'preparing',
        'treating', 'finished', 'error', 'out_of_service',
      };
      for (final k in readDict('en').keys) {
        expect(screens.contains(k.split('.').first), isTrue, reason: k);
      }
    });
  });

  group('запасная цепочка и повреждённые файлы', () {
    test('язык → en → ключ; пустая строка — как отсутствующая; параметры', () {
      I18n.loadFromStrings(
        manifest: jsonEncode({
          'languages': {
            'en': {'name': 'English', 'status': 'released', 'version': 1},
            'de': {'name': 'Deutsch', 'status': 'draft', 'version': 0},
          },
        }),
        files: {
          'en': jsonEncode({'a': 'A en', 'b': 'B en', 'p': 'Wait {seconds} s, {missing}'}),
          'de': jsonEncode({'a': 'A de', 'b': ''}),
        },
      );
      expect(I18n.tr('de', 'a'), 'A de');
      expect(I18n.tr('de', 'b'), 'B en');
      expect(I18n.tr('fr', 'a'), 'A en'); // языка нет вовсе
      expect(I18n.tr('de', 'p', params: {'seconds': 5}), 'Wait 5 s, {missing}');
      expect(I18n.missingKeys, isEmpty);
      expect(I18n.tr('de', 'zzz'), 'zzz'); // нет и в en: показан ключ
      expect(I18n.missingKeys, {'zzz'}); // …и в тестах это видно как ошибка
    });

    test('повреждённые файлы и manifest не роняют приложение', () {
      expect(
        () => I18n.loadFromStrings(
          manifest: manifestRaw,
          files: {'en': files['en'], 'et': '{не json', 'ru': '[1, 2]', 'de': '"строка"'},
        ),
        returnsNormally,
      );
      expect(I18n.availableLangs, ['en']);
      expect(I18n.tr('et', 'payment.title'), 'PAYMENT'); // et сломан → en
      expect(const DeviceSpec().displayLangs, ['en']);

      // Повреждён manifest: языков нет вовсе, текст — ключ, без исключения.
      expect(() => I18n.loadFromStrings(manifest: '{{{', files: {'en': files['en']}), returnsNormally);
      expect(I18n.availableLangs, isEmpty);
      expect(const DeviceSpec().displayLangs, ['en']);
      expect(I18n.tr('en', 'payment.title'), 'PAYMENT');
      expect(() => I18n.loadFromStrings(manifest: null, files: {}), returnsNormally);
      expect(I18n.tr('et', 'payment.title'), 'payment.title');
    });

    test('загрузка из пакета, где файлов нет или они битые — без исключения', () async {
      await I18n.load(bundle: _BrokenBundle({'assets/i18n/manifest.json': manifestRaw, 'assets/i18n/en.json': '{'}));
      expect(I18n.availableLangs, isEmpty);
      await I18n.load(bundle: _BrokenBundle({}));
      expect(I18n.availableLangs, isEmpty);
      expect(I18n.tr('et', 'x.y'), 'x.y');
    });

    testWidgets('экраны при повреждённом en показывают ключи, не падают', (tester) async {
      portrait(tester);
      I18n.loadFromStrings(manifest: manifestRaw, files: {'en': '{', 'et': files['et']});
      final n = notifierFor(lang: 'ru');
      await pump(tester, const PaymentScreen(), n);
      expect(tester.takeException(), isNull);
      expect(find.text('payment.title'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('какие языки показываются', () {
    test('displayLangs = spec ∩ released, порядок spec; draft не показывается', () {
      loadDraftCatalog();
      final s = DeviceSpec.tryParse({'langs': ['de', 'ru', 'fr', 'et'], 'default_lang': 'de'})!;
      expect(s.displayLangs, ['ru', 'et']);
      expect(s.unsupportedLangs, ['de', 'fr']);
      expect(s.displayDefaultLang, 'ru');
      final only = DeviceSpec.tryParse({'langs': ['de', 'fr']})!;
      expect(only.displayLangs, ['en']);
    });

    test('тумблер «показывать черновые переводы»: draft с файлом виден, без файла — нет', () {
      I18n.loadFromStrings(manifest: manifestRaw, files: {...files, 'de': files['en']});
      final s = DeviceSpec.tryParse({'langs': ['de', 'ru', 'fr', 'et'], 'default_lang': 'de'})!;
      expect(s.displayLangs, ['ru', 'et']);
      I18n.showDrafts = true;
      expect(s.displayLangs, ['de', 'ru', 'et']); // fr без файла
      expect(s.displayDefaultLang, 'de');
      I18n.showDrafts = false;
      expect(s.displayLangs, ['ru', 'et']);
    });

    testWidgets('тумблер в сервисном меню (Диагностика): по умолчанию выкл, переключает показ', (tester) async {
      portrait(tester);
      I18n.loadFromStrings(manifest: manifestRaw, files: {...files, 'de': files['en']});
      final n = notifierFor(langs: ['et', 'de', 'en'], lang: 'ru');
      expect(n.displayLangs, ['et', 'en']);
      await pump(tester, const ServiceMenuScreen(), n);
      final dlg = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton));
      if (dlg.evaluate().isNotEmpty) {
        await tester.tap(dlg.last);
        await tester.pump(const Duration(milliseconds: 500));
      }
      final tabRow = find.descendant(of: find.byType(SingleChildScrollView).first, matching: find.byType(GestureDetector));
      await tester.tap(tabRow.at(2), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
      final toggle = find.byKey(const ValueKey('diag_show_drafts'));
      await tester.scrollUntilVisible(toggle, 300, scrollable: find.byType(Scrollable).last);
      final sw = find.descendant(of: toggle, matching: find.byType(Switch));
      expect(tester.widget<Switch>(sw).value, isFalse);
      await tester.tap(sw);
      await tester.pump(const Duration(milliseconds: 300));
      expect(I18n.showDrafts, isTrue);
      expect(n.displayLangs, ['et', 'de', 'en']);
      await tester.tap(sw);
      await tester.pump(const Duration(milliseconds: 300));
      expect(I18n.showDrafts, isFalse);
      expect(n.displayLangs, ['et', 'en']);
      expect(tester.takeException(), isNull);
      await disposeScreen(tester);
    });
  });

  group('язык по умолчанию и экран выбора языка', () {
    test('старт: язык из spec, один язык — без экрана выбора', () {
      final n = notifierFor(langs: ['et', 'en', 'ru'], defaultLang: 'ru');
      expect(n.lang, 'ru');
      expect(n.state, AppState.selectLanguage);
      final one = notifierFor(langs: ['en'], defaultLang: 'en');
      expect(one.lang, 'en');
      expect(one.state, AppState.standby);
      // Из spec показывается один язык (остальные без перевода).
      final de = notifierFor(langs: ['de', 'ru'], defaultLang: 'de');
      expect(de.displayLangs, ['ru']);
      expect(de.lang, 'ru');
      expect(de.state, AppState.standby);
    });

    test('после конца сессии (сброс, таймаут) — язык по умолчанию', () {
      final n = notifierFor(langs: ['et', 'en', 'ru'], defaultLang: 'et');
      n.setLanguage('ru');
      n.transition(AppState.standby);
      n.resetSession();
      expect(n.lang, 'et');
      n.setLanguage('en');
      n.resetLanguage();
      expect(n.lang, 'et');
    });

    test('сервисное меню: ru/en/et, иначе en; выбранный там язык вне spec не остаётся клиенту', () {
      loadDraftCatalog();
      I18n.showDrafts = true;
      final n = notifierFor(langs: ['de', 'fr'], defaultLang: 'de');
      expect(n.lang, 'de');
      expect(n.serviceLang, 'en');
      n.transition(AppState.serviceMenu);
      n.setLanguage('ru');
      expect(n.serviceLang, 'ru');
      n.transition(AppState.standby);
      expect(n.lang, 'de');
    });

    testWidgets('сервисное меню при языке de — на en, не падает', (tester) async {
      portrait(tester);
      loadDraftCatalog();
      I18n.showDrafts = true;
      final n = notifierFor(langs: ['de', 'en'], defaultLang: 'de');
      expect(n.lang, 'de');
      await pump(tester, const ServiceMenuScreen(), n);
      expect(tester.takeException(), isNull);
      expect(find.text('Service menu'), findsOneWidget);
      await disposeScreen(tester);
    });
  });

  group('названия ароматов для любого языка', () {
    test('язык → en → ru → любое непустое → Flavor N', () {
      final c = AppConfig(flavorNames: {
        'ru': ['Лимон', 'Вишня', '', ''],
        'en': ['Lemon', '', '', ''],
        'et': ['', '', 'Mänd', ''],
      });
      expect(c.flavorNameFor('de', 0), 'Lemon');
      expect(c.flavorNameFor('et', 0), 'Lemon');
      expect(c.flavorNameFor('de', 1), 'Вишня');
      expect(c.flavorNameFor('de', 2), 'Mänd');
      expect(c.flavorNameFor('de', 3), 'Flavor 4');
      expect(c.flavorNameFor('de', 7), 'Flavor 8');
      expect(c.flavorNameFor('ru', 0), 'Лимон');
    });

    testWidgets('аппарат на de без списка de: названия из en на всех экранах, без падения', (tester) async {
      portrait(tester);
      loadDraftCatalog();
      I18n.showDrafts = true;
      for (final screen in <Widget Function()>[
        () => const SelectFlavorScreen(),
        () => const PaymentScreen(),
        () => const TreatingScreen(),
      ]) {
        final n = notifierFor(langs: ['de', 'en'], defaultLang: 'de', meter: true);
        n.transition(AppState.standby);
        n.setBusHealthy(true);
        expect(n.config.flavorNames.containsKey('de'), isFalse);
        if (screen().runtimeType != SelectFlavorScreen) n.selectFlavor(0);
        expect(n.lang, 'de');
        await pump(tester, screen(), n);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('Lemon'), findsWidgets, reason: '${screen().runtimeType}');
        await disposeScreen(tester);
      }
    });
  });

  group('переключатель языка', () {
    testWidgets('до 3 языков — кнопки кодов в порядке spec; один — нет', (tester) async {
      portrait(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LangSwitcher(current: 'en', langs: const ['ru', 'en'], onChanged: (_) {})),
      ));
      expect(find.text('RU'), findsOneWidget);
      expect(find.text('EN'), findsOneWidget);
      expect(tester.getTopLeft(find.text('RU')).dx, lessThan(tester.getTopLeft(find.text('EN')).dx));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: LangSwitcher(current: 'en', langs: const ['en'], onChanged: (_) {})),
      ));
      expect(find.text('EN'), findsNothing);
    });

    testWidgets('больше 3 — компактная кнопка (≥ 64 dp) и окно с родными названиями', (tester) async {
      portrait(tester);
      loadDraftCatalog();
      String? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LangSwitcher(
            current: 'de',
            langs: const ['de', 'el', 'bg', 'uk', 'sl', 'en'],
            onChanged: (l) => picked = l,
          ),
        ),
      ));
      final btn = find.byKey(const ValueKey('lang_compact'));
      expect(tester.getSize(btn).height, greaterThanOrEqualTo(64));
      expect(find.text('DE'), findsOneWidget);
      await tester.tap(btn);
      await tester.pumpAndSettle();
      for (final name in ['Deutsch', 'Ελληνικά', 'Български', 'Українська', 'Slovenščina', 'English']) {
        expect(find.text(name), findsOneWidget, reason: name);
        expect(tester.getSize(find.ancestor(of: find.text(name), matching: find.byType(ElevatedButton))).height,
            greaterThanOrEqualTo(PUi.minTouch));
      }
      await tester.tap(find.text('Ελληνικά'));
      await tester.pumpAndSettle();
      expect(picked, 'el');
      expect(find.byType(Dialog), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('смена языка из окна на экране оплаты не прерывает оплату', (tester) async {
      portrait(tester);
      loadDraftCatalog();
      I18n.showDrafts = true;
      final n = notifierFor(langs: ['de', 'en', 'el', 'fr', 'et'], defaultLang: 'de', meter: true);
      n.transition(AppState.standby);
      n.setBusHealthy(true);
      n.selectFlavor(0);
      expect(n.state, AppState.payment);
      await pump(tester, const PaymentScreen(), n);
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('1:57'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('lang_compact')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('lang_el')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(n.lang, 'el');
      expect(n.state, AppState.payment);
      expect(n.selectedFlavor, 0);
      // Таймер оплаты шёл и пока было открыто окно, не сбросился.
      expect(find.text('1:56'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('1:55'), findsOneWidget);
      expect(find.text(I18n.tr('el', 'payment.title')), findsOneWidget);
      expect(tester.takeException(), isNull);
      n.resetSession();
      await disposeScreen(tester);
    });
  });

  group('экран выбора языка: макет 720x1280', () {
    final order = ['et', 'en', 'ru', 'de', 'el', 'bg', 'uk', 'sl', 'lv', 'lt', 'fi', 'sv', 'pl', 'cs',
        'sk', 'hu', 'ro', 'hr', 'pt', 'es', 'fr', 'it', 'nl', 'da', 'ga', 'mt', 'no'];
    for (final count in [1, 2, 3, 5, 6, 7, 8, 12, 24]) {
      testWidgets('$count языков: без переполнения, кнопки ≥ 72 dp, текст ≥ 28 sp', (tester) async {
        portrait(tester);
        loadDraftCatalog();
        I18n.showDrafts = true;
        final langs = order.take(count).toList();
        final n = notifierFor(langs: langs);
        await pump(tester, const LanguageSelectScreen(), n);
        expect(tester.takeException(), isNull);
        final buttons = find.byType(ElevatedButton);
        expect(buttons, findsNWidgets(count));
        final tops = <double>{};
        for (var i = 0; i < count; i++) {
          final b = find.byKey(ValueKey('lang_${langs[i]}'));
          await tester.ensureVisible(b);
          await tester.pump();
          final r = tester.getRect(b);
          expect(r.height, greaterThanOrEqualTo(PUi.minButtonH), reason: langs[i]);
          expect(r.width, greaterThanOrEqualTo(PUi.minTouch));
          expect(r.left, greaterThanOrEqualTo(-0.01));
          expect(r.right, lessThanOrEqualTo(720.01));
          tops.add(r.top.roundToDouble());
          final text = tester.widget<Text>(find.descendant(of: b, matching: find.byType(Text)));
          expect(text.style!.fontSize, greaterThanOrEqualTo(28));
          expect(text.data, I18n.nativeName(langs[i]));
        }
        // Один столбец — каждая кнопка в своём ряду; сетка — по 2 в ряду.
        expect(tops.length, count > LanguageSelectScreen.maxSingleColumn ? (count + 1) ~/ 2 : count,
            reason: 'столбцы');
        // Заголовок — на каждом показываемом языке.
        for (final l in langs) {
          expect(find.textContaining(I18n.tr(l, 'language_select.title')), findsOneWidget, reason: l);
        }
        // Нажатие — выбор языка и заставка.
        final last = find.byKey(ValueKey('lang_${langs.last}'));
        await tester.ensureVisible(last);
        await tester.pump();
        await tester.tap(last);
        await tester.pump();
        expect(n.lang, langs.last);
        expect(n.state, AppState.standby);
        await disposeScreen(tester);
      });
    }
  });

  group('длинные строки', () {
    // Псевдоперевод: строки en удлинены на 40 % повтором последнего слова.
    String longer(String s) {
      final words = s.split(' ');
      final last = words.last.isEmpty ? 'x' : words.last.replaceAll(RegExp(r'\{\w+\}'), 'X');
      var out = s;
      while (out.length < s.length * 1.4) {
        out = '$out $last';
      }
      return out;
    }

    // «Немецкий»: соседние слова склеены в длинные составные слова и строка
    // удлинена на 40 %.
    String german(String s) {
      final words = s.split(' ');
      final merged = <String>[];
      for (var i = 0; i < words.length; i += 3) {
        merged.add(words.sublist(i, (i + 3).clamp(0, words.length)).join().replaceAll(RegExp(r'[^{}\w]'), '') +
            (i + 3 >= words.length ? '' : 'ungs'));
      }
      var out = merged.join(' ');
      while (out.length < s.length * 1.4) {
        out = '${out}verwaltung';
      }
      return out;
    }

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
    };

    for (final variant in ['pseudo', 'german']) {
      for (final e in screens.entries) {
        testWidgets('${e.key} [$variant] 720x1280 без переполнения', (tester) async {
          portrait(tester);
          final f = variant == 'pseudo' ? longer : german;
          final en = readDict('en');
          final long = {for (final k in en.keys) k: f(en[k]!)};
          // Параметры сохраняются (подстановка работает и в длинной строке).
          for (final k in en.keys) {
            expect(I18n.paramsOf(long[k]!), I18n.paramsOf(en[k]!), reason: k);
          }
          loadDraftCatalog(override: {'de': long, 'el': long, 'fi': long, 'sl': long});
          I18n.showDrafts = true;
          final langs = ['de', 'el', 'fi', 'sl'];
          final n = notifierFor(
            langs: langs,
            flavorNames: {
              'de': List.generate(8, (i) => f('Zitronengrasfrische Aromamischung ${i + 1}')),
            },
          );
          if (e.key == 'error') n.goToError('heater_sensor_fault');
          await pump(tester, e.value(), n);
          expect(tester.takeException(), isNull);
          await disposeScreen(tester);
        });
      }
      testWidgets('окно отмены обработки [$variant] без переполнения', (tester) async {
        portrait(tester);
        final f = variant == 'pseudo' ? longer : german;
        final en = readDict('en');
        loadDraftCatalog(override: {'de': {for (final k in en.keys) k: f(en[k]!)}});
        I18n.showDrafts = true;
        final n = notifierFor(langs: ['de', 'en']);
        await pump(tester, const TreatingScreen(), n);
        await tester.tap(find.byType(OutlinedButton));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await disposeScreen(tester);
      });
    }
  });

  group('скриншоты экрана выбора языка', () {
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

    final order = ['et', 'en', 'ru', 'de', 'el', 'bg', 'uk', 'sl', 'lv', 'lt', 'fi', 'sv', 'pl', 'cs',
        'sk', 'hu', 'ro', 'hr', 'pt', 'es', 'fr', 'it', 'nl', 'ga'];
    final shots = <String, (int, Widget Function())>{
      'lang_select_01': (1, () => const LanguageSelectScreen()),
      'standby_01': (1, () => const StandbyScreen()),
      'lang_select_03': (3, () => const LanguageSelectScreen()),
      'lang_select_05': (5, () => const LanguageSelectScreen()),
      'lang_select_08': (8, () => const LanguageSelectScreen()),
      'lang_select_24': (24, () => const LanguageSelectScreen()),
      'payment_08_switcher': (8, () => const PaymentScreen()),
      'payment_08_picker': (8, () => const PaymentScreen()),
    };
    for (final e in shots.entries) {
      testWidgets('снимок ${e.key}', (tester) async {
        await tester.runAsync(loadFonts);
        portrait(tester);
        // et/en/ru — свои файлы, остальные — draft (копия en) при включённом
        // показе черновиков.
        loadDraftCatalog();
        I18n.showDrafts = true;
        final langs = order.take(e.value.$1).toList();
        final n = notifierFor(langs: langs, meter: e.key.startsWith('payment'));
        if (e.key.startsWith('payment')) {
          n.transition(AppState.standby);
          n.setBusHealthy(true);
          n.selectFlavor(0);
        }
        final key = GlobalKey();
        await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
          value: n,
          child: RepaintBoundary(
            key: key,
            child: MaterialApp(theme: ThemeData(fontFamily: 'Roboto'), home: e.value.$2()),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 800));
        if (e.key.endsWith('picker')) {
          await tester.tap(find.byKey(const ValueKey('lang_compact')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 800));
          expect(find.byType(Dialog), findsOneWidget);
        }
        await tester.runAsync(() async {
          final b = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
          final img = await b.toImage(pixelRatio: 1.5);
          final data = await img.toByteData(format: ui.ImageByteFormat.png);
          final f = File('$shotDir/${e.key}.png');
          await f.create(recursive: true);
          await f.writeAsBytes(data!.buffer.asUint8List());
        });
        expect(tester.takeException(), isNull);
        n.resetSession();
        await disposeScreen(tester);
      }, skip: shotDir == null);
    }
  });
}

// Пакет ассетов, в котором есть только переданные файлы (остальные —
// исключение, как при отсутствии файла).
class _BrokenBundle extends CachingAssetBundle {
  _BrokenBundle(this.files);
  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final s = files[key];
    if (s == null) throw FlutterError('нет $key');
    return ByteData.sublistView(utf8.encode(s));
  }
}
