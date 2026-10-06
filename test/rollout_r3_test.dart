import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/privileged_installer.dart';
import 'package:dry_fog_app/services/rollout_service.dart';
import 'package:dry_fog_app/services/update_service.dart';

// R3: раскатка по целевой версии (приложение). Серверная часть — в
// supabase/migrations/…_r3_rollouts.sql и supabase/tests/rls_rollouts.sql.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const rolloutId = '123e4567-e89b-12d3-a456-426614174001';
  const releaseId = '123e4567-e89b-12d3-a456-426614174002';
  const release2 = '123e4567-e89b-12d3-a456-426614174003';

  RolloutTarget target({int code = 10, String release = releaseId}) => RolloutTarget(
    rolloutId: rolloutId,
    releaseId: release,
    versionName: '1.6.0',
    versionCode: code,
  );

  // ================================================== разбор ответа сервера
  group('разбор target', () {
    test('годная цель', () {
      final t = RolloutTarget.tryParse({
        'rollout_id': rolloutId, 'release_id': releaseId,
        'version_name': '1.6.0', 'version_code': 14,
      });
      expect(t, isNotNull);
      expect(t!.versionCode, 14);
      expect(t.releaseId, releaseId);
    });

    test('нет поля, null, не Map, неполная или негодная цель — как «цели нет»', () {
      for (final bad in [
        null, 5, 'x', <String, dynamic>{},
        {'rollout_id': rolloutId, 'release_id': releaseId, 'version_name': 'a'},
        {'rollout_id': 'not-uuid', 'release_id': releaseId, 'version_name': 'a', 'version_code': 3},
        {'rollout_id': rolloutId, 'release_id': releaseId, 'version_name': 'a', 'version_code': 0},
        {'rollout_id': rolloutId, 'release_id': releaseId, 'version_name': 'a', 'version_code': '14'},
      ]) {
        expect(RolloutTarget.tryParse(bad), isNull, reason: '$bad');
      }
    });

    Future<CloudPollResult> poll(Map<String, dynamic> body) => http.runWithClient(
      () => SupabaseTransport(
        baseUrl: 'https://x.supabase.co',
        anonKey: 'k',
        deviceToken: 't',
      ).fetchCommands('D1'),
      () => MockClient((req) async => http.Response(jsonEncode(body), 200)),
    );

    test('ответ device_poll с target попадает в CloudPollResult', () async {
      final r = await poll({
        'ok': true, 'commands': [], 'server_time': '2026-10-06T10:00:00Z',
        'target': {'rollout_id': rolloutId, 'release_id': releaseId, 'version_name': '1.6.0', 'version_code': 14},
      });
      expect(r.ok, isTrue);
      expect(r.target?.versionCode, 14);
    });

    test('старый сервер (нет поля target) и target=null не ломают разбор', () async {
      final old = await poll({'ok': true, 'commands': [], 'server_time': '2026-10-06T10:00:00Z'});
      expect(old.ok, isTrue);
      expect(old.target, isNull);
      final nul = await poll({'ok': true, 'commands': [], 'target': null});
      expect(nul.ok, isTrue);
      expect(nul.target, isNull);
    });
  });

  // ============================================================== сервис
  group('RolloutService', () {
    late Directory tmp;
    late _Installer installer;
    late List<int> bytes;
    late AppNotifier n;
    var tickets = 0;
    var shaOk = true;
    var installedCode = 9;

    AppNotifier notifier({AppState state = AppState.standby}) => AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: false,
        deviceId: 'TEST-001',
        cloudUrl: 'https://proj.supabase.co',
        cloudAnonKey: 'anon',
        cloudToken: 'tok',
      )
      ..transition(state);

    void wire() {
      UpdateService.dirProvider = () async => Directory('${tmp.path}/update');
      UpdateService.installer = installer;
      UpdateService.ticketFetcher = (cfg, id) async {
        tickets++;
        return ReleaseTicket(
          url: Uri.parse('https://proj.supabase.co/signed'),
          sha256: shaOk ? sha256.convert(bytes).toString() : 'a' * 64,
          sizeBytes: bytes.length,
          versionCode: 10,
          versionName: '1.6.0',
        );
      };
      UpdateService.downloader = (url, f, max) async => f.writeAsBytes(bytes);
      UpdateService.apkVerifier = (path) async => const ApkInfo(
        packageName: 'ee.test.pkg', versionCode: 10, versionName: '1.6.0', signatureMatches: true,
      );
      UpdateService.appInfoProvider = () async => AppInfo('ee.test.pkg', installedCode, '1.5.1');
      UpdateService.diskFreeProvider = () async => 1 << 40;
    }

    void at(DateTime t) {
      RolloutService.clock = () => t;
      UpdateService.clock = () => t;
    }

    final t0 = DateTime(2026, 10, 6, 3);
    Duration m(int x) => Duration(minutes: x);

    // Сброс «в пути» между попытками в одном тесте.
    void settle() {
      UpdateService.inProgress = false;
      n.setMaintenance(false);
    }

    Future<List<CloudEvent>> events(String type) async =>
        (await CloudService.history()).where((e) => e.type == type).toList();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      CloudService.resetQueueForTest();
      CloudService.transport = LocalLogTransport();
      UpdateService.resetForTest();
      RolloutService.resetForTest();
      tmp = await Directory.systemTemp.createTemp('r3');
      installer = _Installer();
      bytes = List<int>.generate(2048, (i) => i % 251);
      tickets = 0;
      shaOk = true;
      installedCode = 9;
      n = notifier();
      wire();
      at(t0);
      messenger.setMockMethodCallHandler(modbus, (c) async {
        if (c.method == 'readCoils') return List.generate(12, (_) => false);
        return true;
      });
    });

    tearDown(() async {
      UpdateService.resetForTest();
      RolloutService.resetForTest();
      messenger.setMockMethodCallHandler(modbus, null);
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('цель новее: обновление запускается, скрипт стартует без ack, source=rollout', () async {
      await RolloutService.onPoll(n, target(code: 10));
      expect(installer.started, hasLength(1));
      expect(installer.started.single.targetVersionCode, 10);
      final ev = (await events(CloudEventType.updateStarted)).single;
      expect(ev.data['source'], 'rollout');
      expect(ev.data['rollout_id'], rolloutId);
      expect(RolloutService.targetCode, 10);
      settle();
    });

    test('ручная команда: source=command, rollout_id нет', () async {
      final r = await UpdateService.startUpdate(n, releaseId);
      expect(r.ok, isTrue);
      final ev = (await events(CloudEventType.updateStarted)).single;
      expect(ev.data['source'], 'command');
      expect(ev.data.containsKey('rollout_id'), isFalse);
      settle();
    });

    test('цель равна или старше установленной — игнор', () async {
      installedCode = 10;
      await RolloutService.onPoll(n, target(code: 10));
      await RolloutService.onPoll(n, target(code: 9));
      expect(installer.started, isEmpty);
      expect(tickets, 0);
      expect(RolloutService.targetCode, 9); // видимая цель всё равно отдаётся в слепок
    });

    test('нет цели (null) — ничего не делает, targetCode сбрасывается', () async {
      await RolloutService.onPoll(n, null);
      expect(installer.started, isEmpty);
      expect(RolloutService.targetCode, isNull);
    });

    test('аппарат занят (выбор аромата, оплата, подготовка, обработка, сервисное меню) — не запускается', () async {
      for (final s in [
        AppState.selectLanguage, AppState.selectFlavor, AppState.payment,
        AppState.preparing, AppState.treating, AppState.finished, AppState.serviceMenu,
      ]) {
        final busy = notifier(state: s);
        await RolloutService.onPoll(busy, target(code: 10));
        expect(installer.started, isEmpty, reason: s.name);
      }
      expect(tickets, 0);
    });

    test('идёт обслуживание/обновление — не запускается', () async {
      n.setMaintenance(true);
      await RolloutService.onPoll(n, target(code: 10));
      n.setMaintenance(false);
      UpdateService.inProgress = true;
      await RolloutService.onPoll(n, target(code: 10));
      UpdateService.inProgress = false;
      expect(installer.started, isEmpty);
    });

    test('тестовая сборка (SKIP_HEALTH_SIGNAL) раскатку не получает', () async {
      UpdateService.skipHealthSignal = true;
      await RolloutService.onPoll(n, target(code: 10));
      expect(installer.started, isEmpty);
      expect(tickets, 0);
    });

    test('блок после автоматического отката: той же версии повторно нет, большей — есть', () async {
      // автооткат версии 10: протокол rollback_ok, работает прежняя (9)
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10,
        'to_name': '1.6.0', 'release_id': releaseId,
        'started_at': DateTime.now().toIso8601String(),
      }));
      File('${tmp.path}/update/protocol.log').writeAsStringSync(
        '1 start\n2 health_timeout\n3 rollback_start\n4 rollback_ok\n',
      );
      await UpdateService.onStartup(n);
      settle();
      await RolloutService.onPoll(n, target(code: 10));
      expect(installer.started, isEmpty);
      expect(tickets, 0);
      // цель с БОЛЬШИМ кодом снова разрешена
      at(t0.add(m(30)));
      await RolloutService.onPoll(n, target(code: 11, release: release2));
      expect(installer.started, hasLength(1));
      settle();
    });

    test('бэкофф 6 часов после отказа до запуска, потом снова пробует', () async {
      shaOk = false;
      await RolloutService.onPoll(n, target(code: 10));
      expect(tickets, 1);
      expect(installer.started, isEmpty);
      settle();
      // пауза 10 минут прошла, но бэкофф на этот релиз ещё действует
      at(t0.add(m(30)));
      await RolloutService.onPoll(n, target(code: 10));
      at(t0.add(const Duration(hours: 5, minutes: 59)));
      await RolloutService.onPoll(n, target(code: 10));
      expect(tickets, 1);
      // по истечении 6 часов — новая попытка
      at(t0.add(const Duration(hours: 6, minutes: 1)));
      shaOk = true;
      await RolloutService.onPoll(n, target(code: 10));
      expect(tickets, 2);
      expect(installer.started, hasLength(1));
      settle();
    });

    test('бэкофф идёт на ЭТОТ релиз: другой релиз после паузы 10 минут пробуется', () async {
      shaOk = false;
      await RolloutService.onPoll(n, target(code: 10));
      settle();
      at(t0.add(m(11)));
      shaOk = true;
      await RolloutService.onPoll(n, target(code: 11, release: release2));
      expect(installer.started, hasLength(1));
      settle();
    });

    test('лимиты update_app: пауза 10 минут и потолок 12 неудач в сутки', () async {
      shaOk = false;
      // разные релизы, чтобы бэкофф не мешал; пауза 10 минут между попытками
      for (var i = 0; i < 12; i++) {
        at(t0.add(m(11 * i)));
        final rel = '123e4567-e89b-12d3-a456-4266141740${(10 + i).toString().padLeft(2, '0')}';
        await RolloutService.onPoll(n, target(code: 10, release: rel));
        settle();
      }
      expect(tickets, 12);
      // 13-я — потолок неудач
      at(t0.add(m(11 * 12)));
      await RolloutService.onPoll(n, target(code: 10, release: release2));
      expect(tickets, 12);
      // и пауза 10 минут: сразу после попытки — отказ
      at(t0.add(const Duration(hours: 30)));
      await RolloutService.onPoll(n, target(code: 10, release: release2));
      expect(tickets, 13);
      settle();
      at(t0.add(const Duration(hours: 30, minutes: 5)));
      await RolloutService.onPoll(n, target(code: 10, release: '123e4567-e89b-12d3-a456-426614174099'));
      expect(tickets, 13);
    });

    test('3 запуска скрипта в сутки: четвёртый не стартует', () async {
      for (var i = 0; i < 3; i++) {
        at(t0.add(m(11 * i)));
        await RolloutService.onPoll(n, target(code: 10, release: i == 0 ? releaseId : '123e4567-e89b-12d3-a456-42661417400$i'));
        settle();
      }
      expect(installer.started, hasLength(3));
      at(t0.add(m(11 * 3)));
      await RolloutService.onPoll(n, target(code: 10, release: '123e4567-e89b-12d3-a456-426614174005'));
      expect(installer.started, hasLength(3));
    });

    test('скрипт не запустился (install_start_failed) — это неудача и бэкофф', () async {
      installer.startOk = false;
      await RolloutService.onPoll(n, target(code: 10));
      expect(installer.started, hasLength(1)); // попытка запуска была
      settle();
      installer.startOk = true;
      at(t0.add(m(30)));
      await RolloutService.onPoll(n, target(code: 10)); // бэкофф 6 часов
      expect(installer.started, hasLength(1));
    });

    test('откат остаётся ручным: раскатка rollback_app не вызывает', () async {
      await RolloutService.onPoll(n, target(code: 10));
      expect(installer.started.every((r) => r.mode == 'install'), isTrue);
      settle();
    });
  });
}

class _Installer implements PrivilegedInstaller {
  bool startOk = true;
  final List<InstallRequest> started = [];

  @override
  String get kind => 'fake';
  @override
  Future<bool> isAvailable(Duration timeout) async => true;
  @override
  Future<bool> startScript(InstallRequest request, String scriptText) async {
    started.add(request);
    return startOk;
  }

  @override
  Future<bool> repairAfterUpdate({
    required String dir,
    required String packageName,
    required String aliasClass,
    required bool kiosk,
  }) async => true;
  @override
  Future<bool> setAdbNetwork(bool enabled) async => true;
  @override
  Future<bool?> readAdbNetwork() async => false;
}
