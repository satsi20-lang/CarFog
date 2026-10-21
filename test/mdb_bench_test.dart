import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dry_fog_app/screens/service/mdb_bench_tab.dart';
import 'package:dry_fog_app/services/mdb_bench_service.dart';

// Стенд терминала MDB (1.10.9): Dart-сторона без железа — проверка hex-ввода
// и то, что вкладка не шлёт vend без ответа на setup. Протокол и цикл
// чтения проверяются Kotlin-тестами (MdbCashlessProtocolTest, MdbFrameReaderTest).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.carfog.dryfog/mdb_bench');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('проверка hex-ввода', () {
    expect(MdbBenchService.validateHex('14 01'), isNull);
    expect(MdbBenchService.validateHex('0a'), isNull);
    expect(MdbBenchService.validateHex(''), isNotNull);
    expect(MdbBenchService.validateHex('140'), isNotNull);
    expect(MdbBenchService.validateHex('GG'), isNotNull);
    expect(MdbBenchService.validateHex('14-01'), isNotNull);
  });

  group('вкладка стенда', () {
    final calls = <MethodCall>[];
    var hasSetup = false;
    var testActive = false;

    setUp(() {
      calls.clear();
      hasSetup = false;
      testActive = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'status':
            return {
              'open': true,
              'device': '/dev/bus/usb/001/002',
              'setupScale': hasSetup ? 1 : null,
              'setupDecimals': hasSetup ? 2 : null,
              'logFile': null,
              'enabled': testActive,
              'testActive': testActive,
              'testState': testActive ? 'приложите карту (ждём 10 03)' : 'не запущена',
            };
          case 'getLog':
            return <Map>[];
          case 'vendPreview':
            return {
              'units': 10,
              'scale': 1,
              'decimals': 2,
              'amount': '0.10',
              'hex': '13 00 00 0A 00 01',
            };
          case 'command':
            return '13 00 00 0A 00 01';
        }
        return null;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<void> pumpTab(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(backgroundColor: Colors.black, body: MdbBenchTab()),
      ));
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> tapVend(WidgetTester tester) async {
      final btn = find.widgetWithText(ElevatedButton, 'Запрос оплаты');
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('без ответа на setup vend не отправляется', (tester) async {
      await pumpTab(tester);
      expect(find.textContaining('Тестовый режим: реальное списание'), findsOneWidget);
      await tapVend(tester);
      expect(calls.where((c) => c.method == 'command'), isEmpty);
      expect(find.textContaining('Нет ответа на setup'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('«Отмена» в окне подтверждения — vend не уходит', (tester) async {
      hasSetup = true;
      await pumpTab(tester);
      await tapVend(tester);
      expect(find.text('Списать 0.10 € с карты? Это реальная оплата.'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls.where((c) => c.method == 'command'), isEmpty);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('«Списать» отправляет ровно показанные единицы', (tester) async {
      hasSetup = true;
      await pumpTab(tester);
      await tapVend(tester);
      expect(calls.where((c) => c.method == 'command'), isEmpty,
          reason: 'до нажатия «Списать» ничего не уходит');
      await tester.tap(find.widgetWithText(TextButton, 'Списать'));
      await tester.pump(const Duration(milliseconds: 300));
      final preview = calls.where((c) => c.method == 'vendPreview').single;
      expect(preview.arguments['amount'], '0.10');
      final vend = calls.where((c) => c.method == 'command').single;
      expect(vend.arguments['name'], 'vend');
      expect(vend.arguments['units'], 10);
      expect(vend.arguments['scale'], 1);
      expect(vend.arguments['decimals'], 2);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('тестовая оплата стартует только после «Списать»', (tester) async {
      await pumpTab(tester);
      final btn = find.widgetWithText(ElevatedButton, 'Тестовая оплата 0,10 €');
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Будет списано 0,10 € с карты'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls.where((c) => c.method == 'testStart'), isEmpty);
      await tester.tap(btn);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.widgetWithText(TextButton, 'Списать'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls.where((c) => c.method == 'testStart'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('во время тестовой оплаты ручные команды недоступны', (tester) async {
      testActive = true;
      await pumpTab(tester);
      for (final label in ['setup', 'id', 'Запрос оплаты', 'Отправить', 'Тестовая оплата 0,10 €']) {
        final b = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, label));
        expect(b.onPressed, isNull, reason: label);
      }
      final abort = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'Прервать'));
      expect(abort.onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('неверный raw не отправляется', (tester) async {
      await pumpTab(tester);
      final field = find.widgetWithText(TextField, 'hex, например 14 01');
      await tester.ensureVisible(field);
      await tester.enterText(field, '14 0');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Отправить'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls.where((c) => c.method == 'raw'), isEmpty);
      expect(find.text('нужна чётная длина'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
