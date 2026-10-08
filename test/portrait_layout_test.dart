import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:dry_fog_app/widgets/lang_switcher.dart';
import 'package:dry_fog_app/widgets/portrait_ui.dart';

// Портретный макет под Syoung SY156-A510: физически 1080x1920, плотность 240
// (devicePixelRatio 1.5) → логические 720x1280 dp. Каждый экран клиента и
// вкладки сервисного меню должны отрисоваться без исключений (в том числе
// переполнения RenderFlex) на ru/en/et.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  void portrait(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1080, 1920);
    addTearDown(tester.view.reset);
  }

  AppNotifier notifier(String lang,
      {List<bool>? levels, String? error, bool meter = true}) {
    final n = AppNotifier()
      ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: meter);
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
    // Дать досрочно сработать одноразовым таймерам сервисов (проверка
    // мощности ТЭН, подтверждение выключения), запущенным из initState.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  test('профиль: логический размер соответствует 1080x1920 при density 240', () {
    expect(HardwareProfile.screenWidthPx / (HardwareProfile.densityDpi / 160),
        HardwareProfile.logicalWidthDp);
    expect(HardwareProfile.screenHeightPx / (HardwareProfile.densityDpi / 160),
        HardwareProfile.logicalHeightDp);
    expect(HardwareProfile.orientation, 'portrait');
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
      testWidgets('${e.key} [$lang] 720x1280 без переполнения', (tester) async {
        portrait(tester);
        final n = notifier(
          lang,
          // Один аромат «недоступен» — самый длинный текст карточки.
          levels: [true, false, true, true, true, true, true, true],
          error: e.key == 'error' ? 'bus_unavailable' : null,
          // preparing при установленном счётчике ждёт мощность по реальному
          // времени (DateTime.now) — для проверки макета счётчик не нужен.
          meter: e.key != 'preparing',
        );
        await pumpScreen(tester, e.value(), n);
        expect(tester.takeException(), isNull);
        await dispose(tester);
      });
    }
  }

  testWidgets('переключатель языка: высота не меньше 64 dp, ширина кнопки ≥ 64',
      (tester) async {
    portrait(tester);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: LangSwitcher(current: 'et', onChanged: (_) {}))),
    );
    final items = find.text('ET');
    final box = tester.getSize(find
        .ancestor(of: items, matching: find.byType(Container))
        .first);
    expect(box.height, greaterThanOrEqualTo(PUi.langH));
    expect(box.width, greaterThanOrEqualTo(64));
    expect(PUi.langH, greaterThanOrEqualTo(64));
  });

  test('константы размеров не мельче требований', () {
    expect(PUi.titleSp, greaterThanOrEqualTo(36));
    expect(PUi.minTitleSp, greaterThanOrEqualTo(36));
    expect(PUi.bodySp, greaterThanOrEqualTo(22));
    expect(PUi.minBodySp, greaterThanOrEqualTo(22));
    expect(PUi.buttonH, greaterThanOrEqualTo(72));
    expect(PUi.minButtonH, greaterThanOrEqualTo(72));
    expect(PUi.minTouch, greaterThanOrEqualTo(56));
  });

  const tabNames = {
    'ru': ['Настройки', 'Ароматы', 'Диагностика', 'Датчики', 'Журнал', 'Облако', 'Сканер', 'Киоск'],
  };

  for (final lang in ['ru', 'en', 'et']) {
    for (var i = 0; i < 8; i++) {
      testWidgets('сервисное меню, вкладка $i [$lang] 720x1280', (tester) async {
        portrait(tester);
        final n = notifier(lang);
        await pumpScreen(tester, const ServiceMenuScreen(), n);
        // Вкладки — в горизонтальной прокрутке; листаем до нужной по позиции.
        final scroll = find.byType(SingleChildScrollView).first;
        final tabRow = find.descendant(of: scroll, matching: find.byType(GestureDetector));
        await tester.ensureVisible(tabRow.at(i));
        await tester.tap(tabRow.at(i), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await dispose(tester);
      });
    }
  }
  // Чтобы список имён не считался неиспользуемым.
  test('вкладок восемь', () => expect(tabNames['ru']!.length, 8));
}
