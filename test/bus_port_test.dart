import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/bus_map.dart';
import 'package:dry_fog_app/models/hardware_profile.dart';
import 'package:dry_fog_app/screens/service/bus_port_section.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/remote_commands.dart';

// Порт шины RS485 — настройка (AppConfig.busPort), а не константа.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BusParams.resetPortForTest();
  });

  group('проверка порта', () {
    test('допустимые узлы', () {
      for (final p in [
        '/dev/ttyS0', '/dev/ttyS4', '/dev/ttyS12', '/dev/ttyUSB3', '/dev/ttyACM0',
      ]) {
        expect(BusPortPolicy.check(p), BusPortCheck.ok, reason: p);
      }
    });

    test('запрещённые узлы: ttyS1 и модем 4G ttyUSB0..2', () {
      for (final p in [
        '/dev/ttyS1', '/dev/ttyUSB0', '/dev/ttyUSB1', '/dev/ttyUSB2',
      ]) {
        expect(BusPortPolicy.check(p), BusPortCheck.forbidden, reason: p);
      }
      expect(BusPortPolicy.forbidden.length, 4);
    });

    test('прочее отклоняется (формат)', () {
      for (final p in [
        '', 'ttyS4', '/dev/ttyS', '/dev/ttyS4 ', '/dev/ttyS4\n', '/dev/null',
        '/dev/ttyS4/../ttyS1', '/dev/ttyP0', '/dev/tty', '/dev/ttyS-1',
        '/data/local/tmp/x', '/dev/ttyS1x', '/dev/TTYS4', '/dev//ttyS4',
      ]) {
        expect(BusPortPolicy.check(p), BusPortCheck.badFormat, reason: '"$p"');
      }
    });

    test('ttyS01 (с нулём) допустим по формату, но не равен запрещённому ttyS1', () {
      // Узел с таким именем в системе не бывает; важно лишь, что запрет
      // не обходится изменением написания: имя сверяется точно.
      expect(BusPortPolicy.check('/dev/ttyS01'), BusPortCheck.ok);
    });
  });

  group('значение по умолчанию и применение', () {
    test('по умолчанию /dev/ttyS4 — из профиля', () {
      expect(HardwareProfile.defaultBusPort, '/dev/ttyS4');
      expect(AppConfig().busPort, '/dev/ttyS4');
      expect(BusParams.port, '/dev/ttyS4');
    });

    test('applyConfigured принимает допустимый и отклоняет запрещённый', () {
      expect(BusParams.applyConfigured('/dev/ttyS3'), isTrue);
      expect(BusParams.port, '/dev/ttyS3');
      expect(BusParams.applyConfigured('/dev/ttyS1'), isFalse);
      expect(BusParams.applyConfigured('/dev/ttyUSB1'), isFalse);
      expect(BusParams.applyConfigured('мусор'), isFalse);
      expect(BusParams.applyConfigured(null), isFalse);
      expect(BusParams.port, '/dev/ttyS3'); // прежний остался
    });
  });

  group('хранение', () {
    test('круг: сохранённый порт читается обратно', () async {
      await ConfigService.save(AppConfig(busPort: '/dev/ttyS2'));
      expect((await ConfigService.load()).busPort, '/dev/ttyS2');
    });

    test('конфигурация без поля busPort (старая) даёт значение по умолчанию', () async {
      SharedPreferences.setMockInitialValues({
        'app_config': jsonEncode({'treatmentPriceCents': 300}),
      });
      final c = await ConfigService.load();
      expect(c.treatmentPriceCents, 300);
      expect(c.busPort, '/dev/ttyS4');
    });

    test('сохранённый запрещённый/мусорный порт не применяется', () async {
      for (final bad in ['/dev/ttyS1', '/dev/ttyUSB0', 'abc', '']) {
        SharedPreferences.setMockInitialValues({
          'app_config': jsonEncode({'busPort': bad}),
        });
        expect((await ConfigService.load()).busPort, '/dev/ttyS4', reason: bad);
      }
    });

    test('слепок для облака содержит порт и профиль, без секретов', () {
      final snap = AppConfig(busPort: '/dev/ttyS3', cloudToken: 'секрет-токен').reportedSnapshot();
      expect(snap['bus_port'], '/dev/ttyS3');
      expect(snap['hardware_profile'], 'sy156-a510');
      expect(jsonEncode(snap), isNot(contains('секрет-токен')));
    });

    test('заводской сброс по команде не трогает порт', () async {
      final n = AppNotifier()
        ..config = AppConfig(busPort: '/dev/ttyS3', treatmentPriceCents: 500)
        ..transition(AppState.standby);
      final o = await RemoteCommands.handle(
        CloudCommand(id: 'fr-p', action: 'factory_reset', createdAt: DateTime.now()),
        n,
      );
      expect(o.ok, isTrue, reason: o.result);
      expect(n.config.busPort, '/dev/ttyS3');
      expect(n.config.treatmentPriceCents, 200); // остальное сброшено
    });

    test('update_config не меняет порт (поле не входит в команду)', () async {
      final n = AppNotifier()
        ..config = AppConfig(busPort: '/dev/ttyS3')
        ..transition(AppState.standby);
      await RemoteCommands.handle(
        CloudCommand(
          id: 'uc-p',
          action: 'update_config',
          params: {'price_cents': 250, 'busPort': '/dev/ttyS2', 'bus_port': '/dev/ttyS2'},
          createdAt: DateTime.now(),
        ),
        n,
      );
      expect(n.config.busPort, '/dev/ttyS3');
    });
  });

  group('ModbusService не открывает запрещённые узлы', () {
    final calls = <String>[];
    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(const MethodChannel('com.carfog.dryfog/modbus'),
          (c) async {
        calls.add('${c.method}:${(c.arguments as Map)['port']}');
        return c.method == 'open' ? {'ok': true} : null;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(
        const MethodChannel('com.carfog.dryfog/modbus'), null));

    test('open на запрещённый узел: канал не вызывается', () async {
      for (final p in ['/dev/ttyS1', '/dev/ttyUSB0', '/dev/ttyUSB2', 'x']) {
        final r = await ModbusService.open(port: p);
        expect(r.ok, isFalse, reason: p);
        expect(r.code, 'BAD_PORT');
      }
      expect(calls, isEmpty);
    });

    test('baudSweep и openWithParity на запрещённый узел — отказ без вызова', () async {
      expect(await ModbusService.baudSweep(slaveId: 1, port: '/dev/ttyS1'), isNull);
      expect(await ModbusService.openWithParity(port: '/dev/ttyUSB1', parity: 'none'), isFalse);
      expect(calls, isEmpty);
    });

    test('без аргумента берётся настроенный порт', () async {
      BusParams.applyConfigured('/dev/ttyS3');
      await ModbusService.open();
      expect(calls, ['open:/dev/ttyS3']);
    });
  });

  test('литерала ttyS5 нет ни в lib/, ни в android/ (исходники)', () {
    final hits = <String>[];
    for (final root in ['lib', 'android/app/src']) {
      for (final f in Directory(root).listSync(recursive: true).whereType<File>()) {
        if (!RegExp(r'\.(dart|kt|java|xml|gradle|kts)$').hasMatch(f.path)) continue;
        if (f.readAsStringSync().contains('ttyS5')) hits.add(f.path);
      }
    }
    expect(hits, isEmpty);
  });

  test('Kotlin: порт обязателен, запасного значения нет', () {
    final src = File('android/app/src/main/kotlin/com/example/dry_fog_app/ModbusChannel.kt')
        .readAsStringSync();
    expect(src, isNot(contains('?: "/dev/tty')));
    expect(src, contains('requirePort(call, result)'));
    expect(src, contains('NO_PORT'));
  });

  group('секция в сервисном меню', () {
    Future<AppNotifier> pump(WidgetTester tester, {String pin = '4821'}) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      final n = AppNotifier()..config = AppConfig(servicePin: pin);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppNotifier>.value(
          value: n,
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: BusPortSection(
                  discover: (cur) => ['/dev/ttyS0', '/dev/ttyS1', '/dev/ttyS3', '/dev/ttyS4', '/dev/ttyUSB1'],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return n;
    }

    testWidgets('запрещённый узел — предупреждение, порт не меняется', (tester) async {
      final n = await pump(tester);
      expect(find.textContaining('техподдержки'), findsOneWidget);
      await tester.tap(find.textContaining('/dev/ttyS1'));
      await tester.pump();
      expect(find.textContaining('запрещён:'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(n.config.busPort, '/dev/ttyS4');
    });

    testWidgets('неверный PIN — порт не меняется', (tester) async {
      final n = await pump(tester);
      await tester.tap(find.text('/dev/ttyS3'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.enterText(find.byType(TextField), '0000');
      await tester.tap(find.text('Сменить'));
      await tester.pumpAndSettle();
      expect(n.config.busPort, '/dev/ttyS4');
      expect(find.text('Неверный PIN'), findsOneWidget);
    });

    testWidgets('верный PIN — порт сохранён и записан в облако', (tester) async {
      final n = await pump(tester);
      await tester.tap(find.text('/dev/ttyS3'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '4821');
      await tester.tap(find.text('Сменить'));
      await tester.pumpAndSettle();
      expect(n.config.busPort, '/dev/ttyS3');
      expect((await ConfigService.load()).busPort, '/dev/ttyS3');
      // живой порт не меняется до перезапуска
      expect(BusParams.port, '/dev/ttyS4');
      // отложенная запись журнала (AppLog) — дать ей сработать
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
