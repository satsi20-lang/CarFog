import 'dart:convert';

import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/out_of_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/free_run_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/remote_commands.dart';
import 'package:dry_fog_app/services/session_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Бесплатный запуск по коду. Код во всех тестах заведомо тестовый (123456).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channels = ['com.carfog.dryfog/modbus', 'com.carfog.dryfog/system', 'com.carfog.dryfog/storage'];

  const code = '123456';
  final salt = List<int>.generate(16, (i) => i + 1);
  // PBKDF2-HMAC-SHA256(123456, salt=01..10, 10000, 32), посчитано независимо
  // (python hashlib.pbkdf2_hmac) — сверка формата с порталом и приложением.
  const refHash = 'c6f9170ad191ffc5606ab2d615bee43cda9545f16b9bec9357bb996c30de44aa';
  const refSalt = '0102030405060708090a0b0c0d0e0f10';

  late DateTime now;
  late List<Map<String, dynamic>> sent;

  AppConfig enabledCfg() => AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: true,
        freeRunEnabled: true,
        freeRunCodeHash: refHash,
        freeRunCodeSalt: refSalt,
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ModbusService.paymentBlocked = false;
    CloudService.resetQueueForTest();
    FreeRunService.resetForTest();
    now = DateTime(2026, 11, 8, 12);
    FreeRunService.clock = () => now;
    sent = [];
    FreeRunService.reporter = (type, data) async => sent.add({'type': type, ...data});
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), (call) async => null);
    }
  });

  tearDown(() {
    FreeRunService.resetForTest();
    for (final c in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
  });

  group('хеш и проверка', () {
    test('формат совпадает с независимым расчётом', () {
      final h = FreeRunService.hashForTest(code, salt);
      expect(h.hash, refHash);
      expect(h.salt, refSalt);
    });

    test('верный код → ok, неверный → wrong, не 6 цифр → wrong', () async {
      expect(await FreeRunService.tryCode(enabledCfg(), '654321'), FreeRunResult.wrong);
      expect(await FreeRunService.tryCode(enabledCfg(), '12345'), FreeRunResult.wrong);
      expect(await FreeRunService.tryCode(enabledCfg(), '12345a'), FreeRunResult.wrong);
      expect(await FreeRunService.tryCode(enabledCfg(), code), FreeRunResult.ok);
    });

    test('верный код сбрасывает счётчик неверных', () async {
      for (var i = 0; i < 3; i++) {
        await FreeRunService.tryCode(enabledCfg(), '000000');
      }
      expect(await FreeRunService.attemptsLeft(), 2);
      await FreeRunService.tryCode(enabledCfg(), code);
      expect(await FreeRunService.attemptsLeft(), 5);
    });
  });

  group('по умолчанию выключено', () {
    test('нет настройки — функции нет, код не принимается', () async {
      final cfg = AppConfig();
      expect(FreeRunService.isEnabled(cfg), isFalse);
      expect(await FreeRunService.tryCode(cfg, code), FreeRunResult.disabled);
    });

    test('включено без хеша или с битым хешем — выключено', () async {
      expect(FreeRunService.isEnabled(AppConfig(freeRunEnabled: true)), isFalse);
      expect(FreeRunService.isEnabled(AppConfig(freeRunEnabled: true, freeRunCodeHash: 'zz', freeRunCodeSalt: refSalt)), isFalse);
      expect(FreeRunService.isEnabled(AppConfig(freeRunCodeHash: refHash, freeRunCodeSalt: refSalt)), isFalse,
          reason: 'хеш есть, но флаг не включён');
    });

    test('слепок для облака: только признак, без хеша и соли', () {
      final off = AppConfig().reportedSnapshot();
      expect(off['free_run_enabled'], false);
      final on = enabledCfg().reportedSnapshot();
      expect(on['free_run_enabled'], true);
      final text = jsonEncode(on);
      expect(text, isNot(contains(refHash)));
      expect(text, isNot(contains(refSalt)));
    });
  });

  group('перебор', () {
    test('5 неверных → блок 15 минут и событие free_run_locked без цифр', () async {
      for (var i = 0; i < 4; i++) {
        expect(await FreeRunService.tryCode(enabledCfg(), '00000$i'), FreeRunResult.wrong);
      }
      expect(sent, isEmpty);
      expect(await FreeRunService.tryCode(enabledCfg(), '000009'), FreeRunResult.locked);
      expect(sent, hasLength(1));
      expect(sent.single['type'], 'free_run_locked');
      expect(sent.single['attempts'], 5);
      expect(sent.single['lockout_minutes'], 15);
      expect(jsonEncode(sent), isNot(contains('00000')));
      // верный код во время блока не принимается
      expect(await FreeRunService.tryCode(enabledCfg(), code), FreeRunResult.locked);
      expect((await FreeRunService.remainingLock()).inMinutes, 15);
    });

    test('блок переживает перезапуск приложения (состояние в хранилище)', () async {
      for (var i = 0; i < 5; i++) {
        await FreeRunService.tryCode(enabledCfg(), '00000$i');
      }
      // «Перезапуск»: служебное состояние в памяти сброшено, хранилище то же.
      FreeRunService.resetForTest();
      FreeRunService.clock = () => now;
      expect(await FreeRunService.tryCode(enabledCfg(), code), FreeRunResult.locked);
    });

    test('через 15 минут блок снимается', () async {
      for (var i = 0; i < 5; i++) {
        await FreeRunService.tryCode(enabledCfg(), '00000$i');
      }
      now = now.add(const Duration(minutes: 15, seconds: 1));
      expect(await FreeRunService.remainingLock(), Duration.zero);
      expect(await FreeRunService.tryCode(enabledCfg(), code), FreeRunResult.ok);
    });

    test('часы отведены назад: блок не длиннее 15 минут', () async {
      for (var i = 0; i < 5; i++) {
        await FreeRunService.tryCode(enabledCfg(), '00000$i');
      }
      now = now.subtract(const Duration(hours: 5));
      expect(await FreeRunService.remainingLock(), Duration.zero);
    });
  });

  group('настройка из облака (update_config)', () {
    test('типы и длина проверяются, значения в ответ не попадают', () {
      expect(RemoteCommands.validateConfigParams({'free_run_enabled': 'yes'}), 'bad_type:free_run_enabled');
      expect(RemoteCommands.validateConfigParams({'free_run_code_hash': 'abc'}), 'bad_type:free_run_code_hash');
      expect(RemoteCommands.validateConfigParams({'free_run_code_salt': 5}), 'bad_type:free_run_code_salt');
      expect(
        RemoteCommands.validateConfigParams({
          'free_run_enabled': true,
          'free_run_code_hash': refHash,
          'free_run_code_salt': refSalt,
        }),
        isNull,
      );
    });

    test('сохранение и загрузка настроек: хеш и соль есть, кода нет', () async {
      final n = AppNotifier()..config = AppConfig();
      await n.saveConfig(enabledCfg());
      final loaded = await ConfigService.load();
      expect(loaded.freeRunEnabled, isTrue);
      expect(loaded.freeRunCodeHash, refHash);
      expect(loaded.freeRunCodeSalt, refSalt);
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getKeys().map((k) => '$k=${prefs.get(k)}').join('\n');
      expect(raw, isNot(contains(code)));
    });

    test('испорченное значение в сохранённых настройках → выключено', () async {
      SharedPreferences.setMockInitialValues({
        'app_config': jsonEncode({'freeRunEnabled': true, 'freeRunCodeHash': 'broken', 'freeRunCodeSalt': refSalt}),
      });
      final loaded = await ConfigService.load();
      expect(FreeRunService.isEnabled(loaded), isFalse);
    });
  });

  group('один запуск и возврат на заставку', () {
    AppNotifier makeNotifier() {
      final n = AppNotifier()..config = enabledCfg();
      n.setBusHealthy(true);
      n.transition(AppState.standby);
      return n;
    }

    test('взведено → выбор аромата идёт сразу на подготовку, без оплаты, один раз', () async {
      final n = makeNotifier();
      n.transition(AppState.selectFlavor);
      FreeRunService.arm();
      n.selectFlavor(1);
      expect(n.state, AppState.preparing);
      expect(FreeRunService.armed, isFalse);
      expect(SessionService.currentSessionId, isNotNull);
      await SessionService.complete();
      n.resetSession();
      expect(n.state, AppState.standby);
      // следующий запуск — обычный: оплата
      n.transition(AppState.selectFlavor);
      n.selectFlavor(1);
      expect(n.state, AppState.payment);
    });

    test('ушли с экрана выбора — взвод снят', () {
      final n = makeNotifier();
      n.transition(AppState.selectFlavor);
      FreeRunService.arm();
      n.transition(AppState.standby);
      expect(FreeRunService.armed, isFalse);
      n.transition(AppState.selectFlavor);
      n.selectFlavor(0);
      expect(n.state, AppState.payment);
    });

    test('функцию выключили, пока выбирали аромат — запуска нет', () {
      final n = makeNotifier();
      n.transition(AppState.selectFlavor);
      FreeRunService.arm();
      n.config = enabledCfg().copyWith(freeRunEnabled: false);
      n.selectFlavor(0);
      expect(n.state, AppState.standby);
    });

    test('шина недоступна — бесплатного запуска нет, как и платного', () {
      final n = makeNotifier();
      n.setBusHealthy(false);
      n.transition(AppState.selectFlavor);
      FreeRunService.arm();
      n.selectFlavor(0);
      expect(n.state, AppState.error);
      expect(FreeRunService.armed, isFalse);
      expect(SessionService.currentSessionId, isNull);
    });

    test('выведен из обслуживания — бесплатный запуск не идёт', () {
      final n = makeNotifier();
      n.transition(AppState.selectFlavor);
      FreeRunService.arm();
      n.enterOutOfService(_oos());
      n.selectFlavor(0);
      expect(n.state, AppState.outOfService);
      expect(FreeRunService.armed, isFalse);
    });

    test('событие free_run без кода; session_complete не создаётся', () async {
      final n = makeNotifier();
      n.transition(AppState.selectFlavor);
      FreeRunService.arm();
      n.selectFlavor(2);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await SessionService.complete();
      final events = await CloudService.history();
      expect(events.where((e) => e.type == CloudEventType.sessionComplete), isEmpty);
      final free = events.where((e) => e.type == CloudEventType.freeRun).toList();
      expect(free, hasLength(1));
      final d = free.single.data;
      expect(d['payment'], 'free_code');
      expect(d['flavor_index'], 2);
      expect(d['completed'], true);
      expect(d['result'], 'completed');
      expect(d.containsKey('duration_s'), isTrue);
      expect(d.containsKey('started_at'), isTrue);
      expect(d.containsKey('paid_cents'), isFalse);
      expect(d.containsKey('price_cents'), isFalse);
      final text = jsonEncode(d);
      expect(text, isNot(contains(code)));
      expect(text, isNot(contains(refHash)));
    });

    test('прерванный запуск: free_run с причиной, не продажа', () async {
      final n = makeNotifier();
      n.transition(AppState.selectFlavor);
      FreeRunService.arm();
      n.selectFlavor(0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await SessionService.interrupt('overheat', serviceNotDelivered: true);
      final events = await CloudService.history();
      expect(events.where((e) => e.type == CloudEventType.sessionComplete), isEmpty);
      final d = events.singleWhere((e) => e.type == CloudEventType.freeRun).data;
      expect(d['completed'], false);
      expect(d['result'], 'overheat');
    });

    test('обычная продажа по-прежнему даёт session_complete', () async {
      await SessionService.start(
        flavorIndex: 0,
        flavorNameRu: 'Лимон',
        priceCents: 200,
        paidCents: 200,
        readStartEnergy: false,
      );
      await SessionService.complete();
      final events = await CloudService.history();
      expect(events.where((e) => e.type == CloudEventType.sessionComplete), hasLength(1));
      expect(events.where((e) => e.type == CloudEventType.freeRun), isEmpty);
    });

    test('возврат по карте для бесплатного запуска не вызывается', () async {
      var called = 0;
      SessionService.onFinished = (id, ok, reason, [extra]) => called++;
      addTearDown(() => SessionService.onFinished = null);
      await SessionService.start(
        flavorIndex: 0,
        flavorNameRu: 'Лимон',
        priceCents: 0,
        paidCents: 0,
        readStartEnergy: false,
        free: true,
      );
      await SessionService.complete();
      expect(called, 0);
    });
  });
}

OutOfServiceState _oos() => OutOfServiceState(code: OutOfServiceCode.overheat, since: DateTime(2026, 11, 8), details: const {});
