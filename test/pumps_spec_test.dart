import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/bus_map.dart';
import 'package:dry_fog_app/screens/select_flavor.dart';
import 'package:dry_fog_app/screens/service/service_menu.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/level_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/output_watchdog_service.dart';

// Число насосов 4…8 берётся из spec: безопасность каналов, названия, уровни,
// сессия, сетка выбора аромата.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  const system = MethodChannel('com.carfog.dryfog/system');
  const storage = MethodChannel('com.carfog.dryfog/storage');

  AppNotifier ready({int pumps = 4}) => AppNotifier()
    ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: true, specPumps: pumps);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ModbusService.activePumps = 4;
    ModbusService.paymentBlocked = false;
    CloudService.resetQueueForTest();
    messenger.setMockMethodCallHandler(system, (c) async => null);
    messenger.setMockMethodCallHandler(storage, (c) async => null);
  });
  tearDown(() {
    for (final c in [modbus, system, storage]) {
      messenger.setMockMethodCallHandler(c, null);
    }
    ModbusService.activePumps = 4;
    LevelService.stop();
    OutputWatchdogService.stop();
  });

  group('число активных ароматов из spec', () {
    test('по умолчанию 4; 4…8 как есть; вне диапазона/мусор — 4', () {
      expect(AppConfig().activeFlavorCount, 4);
      for (final n in [4, 5, 6, 7, 8]) {
        expect(AppConfig(specPumps: n).activeFlavorCount, n);
      }
      for (final bad in [0, 3, 9, 10, -1, 99]) {
        expect(AppConfig(specPumps: bad).activeFlavorCount, 4, reason: '$bad');
      }
    });

    test('слепок: flavor_count и названия — по активному числу', () {
      final snap = AppConfig(specPumps: 6).reportedSnapshot();
      expect(snap['flavor_count'], 6);
      expect((snap['flavor_names_ru'] as List).length, 6);
      expect((AppConfig().reportedSnapshot()['flavor_names_ru'] as List).length, 4);
    });

    test('изменение конфигурации в работе передаётся слою шины', () {
      final n = AppNotifier();
      expect(ModbusService.activePumps, 4);
      n.config = AppConfig(specPumps: 7);
      expect(ModbusService.activePumps, 7);
      n.updateConfig(AppConfig(specPumps: 5));
      expect(ModbusService.activePumps, 5);
    });
  });

  group('названия ароматов (хранилище на 8)', () {
    Future<AppConfig> load(Map<String, dynamic> j) async {
      SharedPreferences.setMockInitialValues({'app_config': jsonEncode(j)});
      return ConfigService.load();
    }

    Map<String, dynamic> four() => {
      'treatmentPriceCents': 350,
      'servicePin': '7351',
      'flavorNames': {
        'ru': ['Мой лимон', 'Вишня', 'Хвоя', 'Лаванда'],
        'en': ['My lemon', 'Cherry', 'Pine', 'Lavender'],
        'et': ['Minu sidrun', 'Kirss', 'Mänd', 'Lavendel'],
      },
    };

    test('старые настройки с 4 названиями: добавлены нейтральные 5…8, прежние на месте', () async {
      final c = await load(four());
      expect(c.treatmentPriceCents, 350);
      expect(c.servicePin, '7351');
      expect(c.flavorNames['ru']!.sublist(0, 4), ['Мой лимон', 'Вишня', 'Хвоя', 'Лаванда']);
      expect(c.flavorNames['ru']!.sublist(4), ['Аромат 5', 'Аромат 6', 'Аромат 7', 'Аромат 8']);
      expect(c.flavorNames['en']!.sublist(4), ['Flavor 5', 'Flavor 6', 'Flavor 7', 'Flavor 8']);
      expect(c.flavorNames['et']!.sublist(4), ['Aroma 5', 'Aroma 6', 'Aroma 7', 'Aroma 8']);
      expect(c.flavorNames['en']![0], 'My lemon');
    });

    test('настройки с 8 названиями не меняются', () async {
      final j = four();
      j['flavorNames'] = {
        for (final l in ['ru', 'en', 'et']) l: List.generate(8, (i) => '$l-$i'),
      };
      final c = await load(j);
      expect(c.flavorNames['ru'], List.generate(8, (i) => 'ru-$i'));
      expect(c.flavorNames['et'], List.generate(8, (i) => 'et-$i'));
    });

    test('фикстуры 1.7.0/1.8.0 (8 названий) загружаются без изменений', () async {
      for (final f in ['app_config_1_7_0.json', 'app_config_1_8_0.json']) {
        final raw = File('test/fixtures/$f').readAsStringSync().trim();
        SharedPreferences.setMockInitialValues({'app_config': raw});
        final c = await ConfigService.load();
        expect(c.flavorNames['ru']![0], 'Мой лимон');
        expect(c.flavorNames['ru']!.length, 8);
        expect(c.flavorNames['en']![4], 'Ocean');
      }
    });

    test('смена числа насосов 4 → 6 → 4: названия 5…8 не стираются', () async {
      final n = AppNotifier()..config = await load(four());
      await n.saveConfig(n.config.copyWith(specPumps: 6));
      // техник правит название 6-го
      final names = {for (final e in n.config.flavorNames.entries) e.key: List<String>.from(e.value)};
      names['ru']![5] = 'Шестой';
      await n.saveConfig(n.config.copyWith(flavorNames: names));
      await n.saveConfig(n.config.copyWith(specPumps: 4));
      expect(n.config.activeFlavorCount, 4);
      expect(n.config.flavorNames['ru']![5], 'Шестой'); // осталось в хранилище
      expect(n.config.flavorNames['ru']![0], 'Мой лимон');
      final back = await ConfigService.load();
      expect(back.flavorNames['ru']![5], 'Шестой');
      expect(back.specPumps, 4);
      await n.saveConfig(n.config.copyWith(specPumps: 6));
      expect((await ConfigService.load()).flavorNames['ru']![5], 'Шестой');
    });

    test('сохранённая неверная spec (9 насосов) → по умолчанию 4', () async {
      final c = await load({'specPumps': 9, 'specLangs': ['et'], 'specDefaultLang': 'et'});
      expect(c.specPumps, 4);
      expect(c.activeFlavorCount, 4);
    });
  });

  group('безопасность каналов', () {
    final calls = <String>[];
    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(modbus, (c) async {
        calls.add('${c.method}:${(c.arguments is Map) ? (c.arguments as Map)['channel'] : ''}');
        return true;
      });
    });

    test('таблица canWriteDO при 4 активных', () {
      ModbusService.activePumps = 4;
      for (var i = 0; i < 4; i++) {
        expect(ModbusService.canWriteDO(i, true), isTrue, reason: 'насос $i');
      }
      for (var i = 4; i < 8; i++) {
        expect(ModbusService.canWriteDO(i, true), isFalse, reason: 'неактивный насос $i вкл');
        expect(ModbusService.canWriteDO(i, false), isTrue, reason: 'выключение $i допустимо');
      }
      for (final ch in [8, 9, 10, 11]) {
        expect(ModbusService.canWriteDO(ch, true), isTrue, reason: 'DO$ch');
        expect(ModbusService.canWriteDO(ch, false), isTrue);
      }
      for (final ch in [12, 13, 14, 15, 16, -1, 100]) {
        expect(ModbusService.canWriteDO(ch, true), isFalse, reason: 'DO$ch вкл');
        expect(ModbusService.canWriteDO(ch, false), isFalse, reason: 'DO$ch выкл');
      }
    });

    test('граница следует за spec: 6 активных', () {
      ModbusService.activePumps = 6;
      expect(ModbusService.canWriteDO(5, true), isTrue);
      expect(ModbusService.canWriteDO(6, true), isFalse);
      ModbusService.activePumps = 8;
      expect(ModbusService.canWriteDO(7, true), isTrue);
    });

    test('setPump/setDO: включение неактивного насоса и DO12–15 не доходят до шины', () async {
      ModbusService.activePumps = 4;
      expect(await ModbusService.setPump(4, true), isFalse);
      expect(await ModbusService.setPump(7, true), isFalse);
      expect(await ModbusService.setDO(12, true), isFalse);
      expect(await ModbusService.setDO(15, false), isFalse);
      expect(calls, isEmpty);
      expect(await ModbusService.setPump(3, true), isTrue);
      expect(await ModbusService.setPump(6, false), isTrue); // выключить можно
      expect(await ModbusService.setCompressor(true), isTrue);
      expect(await ModbusService.setHeater(false), isTrue);
      expect(calls, ['setDO:3', 'setDO:6', 'setDO:8', 'setDO:9']);
    });

    test('удалённые команды не умеют управлять выходами (белый список)', () {
      // update_config меняет только настройки; насосов/выходов в списке нет.
      final src = File('lib/services/remote_commands.dart').readAsStringSync();
      expect(src, isNot(contains('setPump')));
      expect(src, isNot(contains('setDO')));
    });

    test('диапазон safeAllOff не зависит от spec', () {
      expect(EmergencyAllOff.startAddr, 0);
      expect(EmergencyAllOff.coilCount, 10);
      final kt = File('android/app/src/main/kotlin/com/example/dry_fog_app/ModbusChannel.kt')
          .readAsStringSync();
      expect(kt, contains('safeAllOff'));
      ModbusService.activePumps = 4;
      // spec никак не попадает в вызов safeAllOff (нет аргументов)
    });

    test('сторож замечает поднятый выход ЛЮБОГО из 0..9 (в том числе 4…7 при spec=4)', () async {
      for (final idx in [0, 3, 4, 5, 7, 8, 9]) {
        calls.clear();
        var off = false;
        messenger.setMockMethodCallHandler(modbus, (c) async {
          calls.add(c.method);
          if (c.method == 'safeAllOff') {
            off = true;
            return true;
          }
          if (c.method == 'readCoils') {
            return List.generate(12, (i) => i == idx && !off);
          }
          return true;
        });
        final n = ready(pumps: 4)..transition(AppState.standby);
        OutputWatchdogService.start(n);
        for (var k = 0; k < 40 && !calls.contains('safeAllOff'); k++) {
          await Future.delayed(const Duration(milliseconds: 20));
        }
        OutputWatchdogService.stop();
        expect(calls, contains('safeAllOff'), reason: 'выход $idx');
      }
    });

    test('сторож игнорирует светодиоды 10/11', () async {
      calls.clear();
      messenger.setMockMethodCallHandler(modbus, (c) async {
        calls.add(c.method);
        if (c.method == 'readCoils') return List.generate(12, (i) => i >= 10);
        return true;
      });
      final n = ready()..transition(AppState.standby);
      OutputWatchdogService.start(n);
      await Future.delayed(const Duration(milliseconds: 300));
      OutputWatchdogService.stop();
      expect(calls, contains('readCoils'));
      expect(calls, isNot(contains('safeAllOff')));
    });

    test('DO12–DO15 нигде в коде не пишутся: нет записи по номерам 12–15', () {
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final s = f.readAsStringSync();
        expect(RegExp(r'setDO\(\s*1[2-5]\b').hasMatch(s), isFalse, reason: f.path);
      }
    });
  });

  group('сессия и число насосов', () {
    AppNotifier inFlavor(int pumps) {
      final n = ready(pumps: pumps)..transition(AppState.standby);
      n.setBusHealthy(true);
      n.transition(AppState.selectFlavor);
      return n;
    }

    test('выбор аромата вне активного числа отклоняется', () {
      final n = inFlavor(4);
      n.selectFlavor(4);
      expect(n.selectedFlavor, isNull);
      expect(n.state, AppState.selectFlavor);
      n.selectFlavor(-1);
      expect(n.selectedFlavor, isNull);
      n.selectFlavor(3);
      expect(n.selectedFlavor, 3);
      expect(n.state, AppState.payment);
    });

    test('6 → 4: сессия на канале 5 отменяется, safeAllOff, событие', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(modbus, (c) async {
        calls.add(c.method);
        return true;
      });
      final n = inFlavor(6);
      n.selectFlavor(5);
      expect(n.selectedFlavor, 5);
      await n.saveConfig(n.config.copyWith(specPumps: 4));
      await Future.delayed(const Duration(milliseconds: 100));
      expect(n.selectedFlavor, isNull);
      expect(n.state, AppState.standby);
      expect(calls, contains('safeAllOff'));
      final ev = await CloudService.history();
      expect(ev.where((e) => e.data['code'] == 'session_cancelled_pump_count_changed'), isNotEmpty);
    });

    test('уменьшение с сохранением выбранного в пределах: сессия не трогается', () async {
      final n = inFlavor(6);
      n.selectFlavor(2);
      await n.saveConfig(n.config.copyWith(specPumps: 4));
      expect(n.selectedFlavor, 2);
      expect(n.state, AppState.payment);
    });
  });

  group('уровни канистр: только активные каналы', () {
    test('неактивный датчик не создаёт события; активный — создаёт', () async {
      var phase = 0;
      messenger.setMockMethodCallHandler(modbus, (c) async {
        if (c.method == 'readAllInputs') {
          // DI0..7 = уровни, DI8.. = прочее. phase 0: всё есть; phase 1: DI2
          // (активный) и DI5 (неактивный при spec=4) пропали.
          return List.generate(16, (i) => phase == 0 ? true : !(i == 2 || i == 5));
        }
        return true;
      });
      final n = ready(pumps: 4)..transition(AppState.standby);
      LevelService.start(n);
      await Future.delayed(const Duration(milliseconds: 200));
      expect(n.levels.length, 8);
      phase = 1;
      await Future.delayed(const Duration(milliseconds: 3400));
      LevelService.stop();
      final ev = await CloudService.history();
      final low = ev.where((e) => e.type == CloudEventType.lowLiquid).toList();
      expect(low.map((e) => e.data['channel']), [2]); // канал 5 неактивен
      expect(n.levels.length, 8);
    });
  });

  group('экран выбора аромата 4…8', () {
    Future<void> pumpGrid(WidgetTester tester, int pumps, String lang,
        {List<bool>? levels, Map<String, List<String>>? names}) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      final n = ready(pumps: pumps);
      n.setLanguage(lang);
      if (levels != null) n.updateLevels(levels);
      if (names != null) n.config = n.config.copyWith(flavorNames: names);
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: SelectFlavorScreen()),
      ));
      await tester.pump(const Duration(milliseconds: 600));
    }

    for (final lang in ['ru', 'en', 'et']) {
      for (final count in [4, 5, 6, 7, 8]) {
        testWidgets('$count карточек [$lang]: ровно столько, без переполнения', (tester) async {
          await pumpGrid(tester, count, lang,
              levels: [true, false, true, true, true, false, true, true]);
          expect(tester.takeException(), isNull);
          final names = AppConfig().flavorNames[lang]!;
          for (var i = 0; i < 8; i++) {
            expect(find.text(names[i]), i < count ? findsOneWidget : findsNothing,
                reason: 'карточка $i при $count');
          }
          // зона касания и положение: нечётная последняя — по центру
          for (var i = 0; i < count; i++) {
            final r = tester.getRect(find.ancestor(
              of: find.text(names[i]),
              matching: find.byType(GestureDetector),
            ).first);
            expect(r.height, greaterThanOrEqualTo(56), reason: 'карточка $i');
            expect(r.width, greaterThanOrEqualTo(56));
            expect(r.right, lessThanOrEqualTo(720.01));
            expect(r.left, greaterThanOrEqualTo(-0.01));
          }
          if (count.isOdd) {
            final last = tester.getRect(find.ancestor(
              of: find.text(names[count - 1]),
              matching: find.byType(GestureDetector),
            ).first);
            expect((last.center.dx - 360).abs(), lessThan(1.0), reason: 'последняя по центру');
          }
        });
      }
    }

    testWidgets('длинные названия (ru/et) на 8 карточках: перенос, без переполнения', (tester) async {
      final long = {
        'ru': List.generate(8, (i) => 'Очень длинное название аромата номер ${i + 1}'),
        'en': List.generate(8, (i) => 'A really long fragrance name number ${i + 1}'),
        'et': List.generate(8, (i) => 'Väga pikk lõhna nimetus number ${i + 1} lõpuni'),
      };
      for (final lang in ['ru', 'et', 'en']) {
        await pumpGrid(tester, 8, lang, names: long);
        expect(tester.takeException(), isNull, reason: lang);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('число карточек меняется во время работы без падения', (tester) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      final n = ready(pumps: 8);
      n.setLanguage('en');
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: SelectFlavorScreen()),
      ));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Mint'), findsOneWidget);
      n.updateConfig(n.config.copyWith(specPumps: 5));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Mint'), findsNothing);
      expect(find.text('Ocean'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('сервисное меню: вкладка «Ароматы» и тест насосов', () {
    testWidgets('поля названий только для активных (6 → 18 полей, 4 → 12)', (tester) async {
      for (final pumps in [4, 6]) {
        tester.view.devicePixelRatio = 1.5;
        tester.view.physicalSize = const Size(1080, 1920);
        final n = ready(pumps: pumps);
        n.setLanguage('ru');
        await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
          value: n,
          child: const MaterialApp(home: ServiceMenuScreen()),
        ));
        await tester.pump(const Duration(milliseconds: 500));
        final dlg = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton));
        if (dlg.evaluate().isNotEmpty) {
          await tester.tap(dlg.last);
          await tester.pump(const Duration(milliseconds: 500));
        }
        final tabRow = find.descendant(
          of: find.byType(SingleChildScrollView).first,
          matching: find.byType(GestureDetector),
        );
        await tester.tap(tabRow.at(1), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(TextField), findsNWidgets(pumps * 3), reason: 'spec=$pumps');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 1));
        tester.view.reset();
      }
    });
  });
}
