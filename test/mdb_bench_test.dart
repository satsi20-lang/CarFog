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
    String? warning;
    int? holdMs;

    setUp(() {
      calls.clear();
      hasSetup = false;
      testActive = false;
      warning = null;
      holdMs = null;
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
              'sessionWarning': warning,
              'holdRemainingMs': holdMs,
              'testMode': 'тест А (задержка)',
              'queueSize': 0,
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

    // Ленивый список строит нижние элементы только при прокрутке.
    Future<Finder> reveal(WidgetTester tester, Finder f) async {
      if (f.evaluate().isEmpty) {
        await tester.dragUntilVisible(f, find.byType(ListView).first, const Offset(0, -300));
      }
      await tester.ensureVisible(f);
      return f;
    }

    Future<void> tapVend(WidgetTester tester) async {
      final btn = await reveal(tester, find.widgetWithText(ElevatedButton, 'Запрос оплаты'));
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
        final f = await reveal(tester, find.widgetWithText(ElevatedButton, label));
        final b = tester.widget<ElevatedButton>(f);
        expect(b.onPressed, isNull, reason: label);
      }
      final abort = tester.widget<ElevatedButton>(
          await reveal(tester, find.widgetWithText(ElevatedButton, 'Прервать')));
      expect(abort.onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('предупреждение «сессия может висеть» видно сверху', (tester) async {
      warning = 'сессия может висеть, нажмите done';
      await pumpTab(tester);
      expect(find.text('Внимание: сессия может висеть, нажмите done'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    Future<void> startViaDialog(WidgetTester tester, String label) async {
      final btn = find.widgetWithText(ElevatedButton, label);
      await tester.ensureVisible(btn);
      await tester.tap(btn);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Будет списано 0,10 € с карты'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Списать'));
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('тест А передаёт выбранную задержку только после «Списать»', (tester) async {
      await pumpTab(tester);
      expect(find.text('Реальное списание 0,10 € в каждом тесте.'), findsOneWidget);
      await startViaDialog(tester, 'Тест А (задержка)');
      final start = calls.where((c) => c.method == 'testStart').single;
      expect(start.arguments['mode'], 'delay');
      expect(start.arguments['delaySec'], 30);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('тест Б запускается в режиме возврата', (tester) async {
      await pumpTab(tester);
      await startViaDialog(tester, 'Тест Б (возврат)');
      final start = calls.where((c) => c.method == 'testStart').single;
      expect(start.arguments['mode'], 'refund');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('обратный отсчёт теста А виден сверху', (tester) async {
      testActive = true;
      holdMs = 41200;
      await pumpTab(tester);
      expect(find.text('До 13 02 осталось 42 с'), findsOneWidget);
      for (final label in ['Тест А (задержка)', 'Тест Б (возврат)']) {
        final b = tester.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, label));
        expect(b.onPressed, isNull, reason: label);
      }
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('неверный raw не отправляется', (tester) async {
      await pumpTab(tester);
      final field = find.widgetWithText(TextField, 'hex, например 14 01');
      await reveal(tester, field);
      await tester.enterText(field, '14 0');
      await tester.tap(find.widgetWithText(ElevatedButton, 'Отправить'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls.where((c) => c.method == 'raw'), isEmpty);
      expect(find.text('нужна чётная длина'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
