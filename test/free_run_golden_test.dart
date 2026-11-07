import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/hardware_profile.dart';
import 'package:dry_fog_app/screens/free_run_screen.dart';
import 'package:dry_fog_app/screens/service/service_pin.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/free_run_service.dart';
import 'package:dry_fog_app/services/i18n_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// НОВЫЕ эталоны test/goldens/free_run/*.png: экран PIN с кнопкой «Бесплатный
// запуск» и экран ввода кода — в обоих профилях. Эталоны Syoung и прежние
// (в том числе service_pin без кнопки) этим тестом не затрагиваются.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => I18n.load());
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = ['com.carfog.dryfog/modbus', 'com.carfog.dryfog/system', 'com.carfog.dryfog/storage'];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudService.resetQueueForTest();
    FreeRunService.resetForTest();
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (call) async => null);
    }
  });
  tearDown(() {
    FreeRunService.resetForTest();
    HardwareProfile.current = HardwareProfile.fallback;
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
  });

  final screens = <String, Widget Function()>{
    'pin_with_button': () => const ServicePinScreen(),
    'code_entry': () => const FreeRunScreen(),
  };

  for (final landscape in [false, true]) {
    final tag = landscape ? 'landscape' : 'portrait';
    for (final e in screens.entries) {
      testWidgets('${e.key}, ${landscape ? 'ixp101m1' : 'sy156-a510'}', (t) async {
        HardwareProfile.current = landscape ? HardwareProfile.ixp101m1 : HardwareProfile.fallback;
        t.view.devicePixelRatio = 1.5;
        t.view.physicalSize = landscape ? const Size(1280, 800) : const Size(1080, 1920);
        addTearDown(t.view.reset);
        final n = AppNotifier()
          ..config = AppConfig(
            freeRunEnabled: true,
            freeRunCodeHash: 'c6f9170ad191ffc5606ab2d615bee43cda9545f16b9bec9357bb996c30de44aa',
            freeRunCodeSalt: '0102030405060708090a0b0c0d0e0f10',
          );
        n.setLanguage('en');
        await t.pumpWidget(
          ChangeNotifierProvider<AppNotifier>.value(
            value: n,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              home: RepaintBoundary(key: const ValueKey('shot'), child: e.value()),
            ),
          ),
        );
        await t.pump(const Duration(milliseconds: 300));
        expect(t.takeException(), isNull);
        await expectLater(
          find.byKey(const ValueKey('shot')),
          matchesGoldenFile('goldens/free_run/${e.key}_$tag.png'),
        );
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 31));
      });
    }
  }
}
