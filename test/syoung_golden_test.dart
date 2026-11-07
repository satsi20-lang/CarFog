@Tags(['golden'])
library;

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
import 'package:dry_fog_app/screens/service/service_pin.dart';
import 'package:dry_fog_app/screens/treating.dart';
import 'package:dry_fog_app/services/i18n_service.dart';

// Портрет SY156-A510 (720x1280 dp) не должен меняться ни на пиксель: эталоны
// test/goldens/syoung/*.png сняты с main до альбомной раскладки IXP101M1
// (03.11.2026). Заставка не входит: её QR-картинка декодируется асинхронно и
// делает снимок зависимым от порядка тестов (её проверяет
// portrait_layout_test).
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

  final screens = <String, Widget Function()>{
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

  for (final e in screens.entries) {
    for (final pumps in e.key == 'select_flavor' ? [4, 8] : [4]) {
      final name = pumps == 8 ? '${e.key}_8' : e.key;
      testWidgets('SY156-A510 $name совпадает с эталоном', (tester) async {
        tester.view.devicePixelRatio = 1.5;
        tester.view.physicalSize = const Size(1080, 1920);
        addTearDown(tester.view.reset);
        final n = AppNotifier()
          ..config = AppConfig(
            thermoInstalled: true,
            energyMeterInstalled: e.key != 'preparing',
            specPumps: pumps,
          );
        n.setLanguage('ru');
        n.updateLevels([true, false, true, true, true, true, true, true]);
        if (e.key == 'error') n.goToError('heater_timeout');
        await tester.pumpWidget(
          ChangeNotifierProvider<AppNotifier>.value(
            value: n,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              home: RepaintBoundary(
                key: const ValueKey('shot'),
                child: e.value(),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 900));
        await expectLater(
          find.byKey(const ValueKey('shot')),
          matchesGoldenFile('goldens/syoung/$name.png'),
        );
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 6; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
      });
    }
  }
}
