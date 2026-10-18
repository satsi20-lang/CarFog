import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/screens/service/service_pin.dart';

// 1.10.10: компактная клавиатура PIN, введённые цифры — точками.
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
      messenger.setMockMethodCallHandler(
        MethodChannel(c),
        (call) async => null,
      );
    }
  });

  tearDown(() {
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
  });

  Future<void> pumpPin(WidgetTester tester, Size physical, double dpr) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = physical;
    addTearDown(tester.view.reset);
    final n = AppNotifier()..setLanguage('ru');
    await tester.pumpWidget(
      ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: ServicePinScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 600));
  }

  // Кружки индикатора ввода: (всего, закрашенных).
  (int, int) dots(WidgetTester tester) {
    final circles = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle)
        .toList();
    final filled = circles.where((d) => d.color != Colors.transparent).length;
    return (circles.length, filled);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  // Портрет SY156-A510 (1080x1920, density 240) и старый тестовый планшет
  // в альбоме (1280x800, density 160).
  final sizes = {
    'портрет 1080x1920': (const Size(1080, 1920), 1.5),
    'альбом 1280x800': (const Size(1280, 800), 1.0),
  };

  for (final e in sizes.entries) {
    testWidgets('PIN: кнопки 80x56 dp, без переполнения [${e.key}]', (
      tester,
    ) async {
      await pumpPin(tester, e.value.$1, e.value.$2);
      expect(tester.takeException(), isNull);
      for (final d in ['0', '1', '5', '9', '⌫']) {
        final size = tester.getSize(
          find
              .ancestor(
                of: find.text(d),
                matching: find.byType(GestureDetector),
              )
              .first,
        );
        expect(size.width, closeTo(80, 0.5), reason: 'ширина кнопки $d');
        expect(size.height, closeTo(56, 0.5), reason: 'высота кнопки $d');
        expect(size.shortestSide, greaterThanOrEqualTo(48));
      }
      expect(tester.widget<Text>(find.text('5')).style?.fontSize, 22);
      await dispose(tester);
    });
  }

  testWidgets('PIN: введённые цифры показываются точками, не цифрами', (
    tester,
  ) async {
    await pumpPin(tester, const Size(1080, 1920), 1.5);
    expect(dots(tester), (4, 0));

    await tester.tap(find.text('5'));
    await tester.pump();
    await tester.tap(find.text('8'));
    await tester.pump();

    expect(dots(tester), (4, 2));
    // Цифры «5» и «8» есть только на самих кнопках, введённый код нигде
    // текстом не выводится.
    expect(find.text('5'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('58'), findsNothing);
    expect(find.textContaining('58'), findsNothing);

    await tester.tap(find.text('⌫'));
    await tester.pump();
    expect(dots(tester), (4, 1));
    await dispose(tester);
  });
}
