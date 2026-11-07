@Tags(['golden'])
library;

import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/brand/brand.dart';
import 'package:dry_fog_app/brand/brand_colors.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/hardware_profile.dart';
import 'package:dry_fog_app/screens/standby.dart';
import 'package:dry_fog_app/services/i18n_service.dart';

// Заставка с тестовым брендом acme (свои цвета, логотип, слоган, QR из ссылки,
// контакты) в обоих профилях. Эталоны test/goldens/brand/*.png — НОВЫЕ файлы;
// эталоны Syoung и ixp101m1 этим тестом не затрагиваются.
const acmeColors = BrandColors(
  primary: Color(0xFFE4572E),
  primaryAlt: Color(0xFFF28C28),
  background: Color(0xFF101820),
  backgroundStandby: Color(0xFF1B2A41),
  surface: Color(0xFF26344A),
  textPrimary: Color(0xFFFFFFFF),
  textSecondary: Color(0xFFB8C4D6),
);

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
  late Directory tmp;
  File logo = File('/nonexistent/logo.png');
  File qr = File('/nonexistent/qr.png');

  // Простой логотип: оранжевый скруглённый квадрат с белым кругом.
  Future<File> makePng(String name, Color c) async {
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 240, 120),
        const Radius.circular(24),
      ),
      Paint()..color = c,
    );
    canvas.drawCircle(const Offset(60, 60), 34, Paint()..color = Colors.white);
    final img = await rec.endRecording().toImage(240, 120);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('${tmp.path}/$name');
    await f.writeAsBytes(data!.buffer.asUint8List());
    return f;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (call) async => null);
    }
    tmp = await Directory.systemTemp.createTemp('brandstandby');
  });

  tearDown(() async {
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
    BrandController.instance.setActive(Brand.builtin);
    HardwareProfile.current = HardwareProfile.fallback;
    await tmp.delete(recursive: true);
  });

  Brand acme({String? qrPath}) => Brand(
    id: 'acme',
    version: 2,
    name: 'ACME Clean',
    slogan: 'Fresh air, every ride',
    colors: acmeColors,
    logoPath: logo.path,
    qrPath: qrPath,
  );

  AppConfig acmeConfig() => AppConfig(
    qrUrl: 'https://acme.ee/start',
    sellerPhone: '+372 5555 5555',
    sellerEmail: 'info@acme.ee',
    sellerSite: 'https://acme.ee',
    sellerLegal: 'ACME OÜ, reg 12345678',
  );

  Future<void> pumpStandby(
    WidgetTester tester, {
    required bool landscape,
    required AppConfig config,
  }) async {
    HardwareProfile.current =
        landscape ? HardwareProfile.ixp101m1 : HardwareProfile.fallback;
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize =
        landscape ? const Size(1280, 800) : const Size(1080, 1920);
    addTearDown(tester.view.reset);
    final n = AppNotifier()..config = config;
    n.setLanguage('en');
    // Картинки из файлов декодируются асинхронно: прогреваем кэш ДО того, как
    // они попали в дерево (иначе загрузка зависнет в fake-async зоне теста).
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.runAsync(() async {
      final ctx = tester.element(find.byType(SizedBox));
      for (final f in [logo, qr]) {
        if (await f.exists()) await precacheImage(FileImage(f), ctx);
      }
    });
    await tester.pumpWidget(
      ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: ListenableBuilder(
          listenable: BrandController.instance,
          builder: (_, _) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              extensions: [BrandController.instance.active.colors],
            ),
            home: RepaintBoundary(
              key: const ValueKey('shot'),
              child: const StandbyScreen(),
            ),
          ),
        ),
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

  for (final landscape in [false, true]) {
    final prof = landscape ? 'ixp101m1 (альбом)' : 'sy156-a510 (портрет)';
    final tag = landscape ? 'landscape' : 'portrait';

    testWidgets('встроенный CaRFog, $prof: название, подпись, «Powered by», без контактов',
        (tester) async {
      logo = (await tester.runAsync(() => makePng('logo.png', const Color(0xFFE4572E))))!;
      qr = (await tester.runAsync(() => makePng('qr.png', Colors.black)))!;
      await pumpStandby(tester, landscape: landscape, config: AppConfig());
      expect(find.text('CaRFog OÜ'), findsOneWidget);
      expect(find.textContaining('DRY FOG'), findsOneWidget); // встроенная подпись
      expect(find.byKey(const ValueKey('powered_by')), findsOneWidget);
      expect(find.text('Powered by CaRFog'), findsOneWidget);
      expect(find.byKey(const ValueKey('standby_qr_builtin')), findsOneWidget);
      expect(find.byKey(const ValueKey('standby_logo')), findsNothing);
      expect(find.byKey(const ValueKey('standby_contacts')), findsNothing);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    });

    testWidgets('бренд acme, $prof: название вместо «CaRFog OÜ», слоган, логотип, QR из ссылки, контакты',
        (tester) async {
      logo = (await tester.runAsync(() => makePng('logo.png', const Color(0xFFE4572E))))!;
      qr = (await tester.runAsync(() => makePng('qr.png', Colors.black)))!;
      BrandController.instance.setActive(acme());
      await pumpStandby(tester, landscape: landscape, config: acmeConfig());
      expect(find.text('ACME Clean'), findsOneWidget);
      expect(find.text('CaRFog OÜ'), findsNothing);
      expect(find.text('Fresh air, every ride'), findsOneWidget);
      expect(find.textContaining('DRY FOG'), findsNothing); // слоган заменил подпись
      expect(find.byKey(const ValueKey('standby_logo')), findsOneWidget);
      expect(find.byKey(const ValueKey('standby_qr_url')), findsOneWidget);
      expect(find.byKey(const ValueKey('standby_qr_builtin')), findsNothing);
      expect(find.byKey(const ValueKey('standby_contacts')), findsOneWidget);
      for (final t in ['+372 5555 5555', 'info@acme.ee', 'https://acme.ee', 'ACME OÜ, reg 12345678']) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      // «Powered by CaRFog» остаётся при любом бренде.
      expect(find.text('Powered by CaRFog'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(const ValueKey('shot')),
        matchesGoldenFile('goldens/brand/acme_standby_$tag.png'),
      );
      await dispose(tester);
    });

    testWidgets('acme без ссылки QR, $prof: картинка qr_default.png бренда; без контактов блока нет',
        (tester) async {
      logo = (await tester.runAsync(() => makePng('logo.png', const Color(0xFFE4572E))))!;
      qr = (await tester.runAsync(() => makePng('qr.png', Colors.black)))!;
      BrandController.instance.setActive(acme(qrPath: qr.path));
      await pumpStandby(tester, landscape: landscape, config: AppConfig());
      expect(find.byKey(const ValueKey('standby_qr_brand')), findsOneWidget);
      expect(find.byKey(const ValueKey('standby_qr_url')), findsNothing);
      expect(find.byKey(const ValueKey('standby_contacts')), findsNothing);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    });

    testWidgets('ссылка QR есть, а бренда с QR нет, $prof: QR из ссылки со встроенным логотипом в центре',
        (tester) async {
      logo = (await tester.runAsync(() => makePng('logo.png', const Color(0xFFE4572E))))!;
      qr = (await tester.runAsync(() => makePng('qr.png', Colors.black)))!;
      await pumpStandby(
        tester,
        landscape: landscape,
        config: AppConfig(qrUrl: 'https://carfog.eu/x'),
      );
      expect(find.byKey(const ValueKey('standby_qr_url')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await dispose(tester);
    });
  }

  testWidgets('смена бренда на лету перекрашивает заставку (тема следует за контроллером)',
      (tester) async {
    logo = (await tester.runAsync(() => makePng('logo.png', const Color(0xFFE4572E))))!;
    qr = (await tester.runAsync(() => makePng('qr.png', Colors.black)))!;
    await pumpStandby(tester, landscape: false, config: AppConfig());
    Color bg() => tester
        .widgetList<ColoredBox>(find.byType(ColoredBox))
        .firstWhere((c) => c.color == BrandController.instance.active.colors.backgroundStandby)
        .color;
    expect(bg(), BrandColors.carfog.backgroundStandby);
    BrandController.instance.setActive(acme());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // анимация темы
    expect(bg(), acmeColors.backgroundStandby);
    await dispose(tester);
  });
}
