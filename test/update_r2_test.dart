import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/update_limits.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/privileged_installer.dart';
import 'package:dry_fog_app/services/remote_commands.dart';
import 'package:dry_fog_app/services/sync_service.dart';
import 'package:dry_fog_app/services/update_script.dart';
import 'package:dry_fog_app/services/update_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';

// R2: удалённое обновление. Протокол и скрипт (прогон на хосте с поддельными
// pm/am/cmd), условия здоровья, оркестратор, скачивание, команды.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // ================================================================ протокол
  group('протокол скрипта', () {
    test('успех: health_ok', () {
      final s = UpdateProtocol.parse(
        '100 start mode=install target=10\n101 backup_ok\n103 install_ok\n104 started\n130 health_ok\n',
      );
      expect(s.outcome, UpdateOutcome.installed);
      expect(s.durationS, 30);
      expect(s.events, ['start', 'backup_ok', 'install_ok', 'started', 'health_ok']);
    });

    test('отказ установки: install_failed с причиной', () {
      final s = UpdateProtocol.parse(
        '100 start\n101 backup_ok\n102 install_failed Failure [INSTALL_FAILED_INVALID_APK]\n',
      );
      expect(s.outcome, UpdateOutcome.failed);
      expect(s.detail, contains('INSTALL_FAILED_INVALID_APK'));
    });

    test('нет здоровья → откат выполнен', () {
      final s = UpdateProtocol.parse(
        '100 start\n103 install_ok\n104 started\n404 health_timeout\n405 rollback_start\n407 rollback_ok\n408 started\n',
      );
      expect(s.outcome, UpdateOutcome.rolledBack);
      expect(s.detail, 'health_timeout');
    });

    test('откат тоже не удался', () {
      final s = UpdateProtocol.parse(
        '100 start\n404 health_timeout\n405 rollback_start\n406 rollback_failed Failure [X]\n',
      );
      expect(s.outcome, UpdateOutcome.rollbackFailed);
    });

    test('пусто / идёт', () {
      expect(UpdateProtocol.parse('').outcome, UpdateOutcome.inProgress);
      expect(UpdateProtocol.parse('100 start\n101 backup_ok\n').outcome, UpdateOutcome.inProgress);
    });

    test('мусорные строки не ломают разбор', () {
      final s = UpdateProtocol.parse('\n???\nabc def\n100 start\n');
      expect(s.outcome, UpdateOutcome.inProgress);
      expect(s.events, ['start']);
    });
  });

  group('сигнал здоровья', () {
    test('нужны шина, покой и (при включённом облаке) один опрос', () {
      bool r({bool bus = true, bool idle = true, bool cloud = true, bool polled = true}) =>
          HealthGate.ready(busHealthy: bus, idle: idle, cloudEnabled: cloud, cloudPolled: polled);
      expect(r(), isTrue);
      expect(r(bus: false), isFalse);
      expect(r(idle: false), isFalse);
      expect(r(polled: false), isFalse);
      expect(r(cloud: false, polled: false), isTrue); // облако выключено
    });
  });

  // ============================================== скрипт: прогон на хосте
  group('установочный скрипт (поддельные pm/am/cmd)', () {
    late Directory dir;
    late Directory fake;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('r2script');
      fake = Directory('${dir.path}/bin')..createSync();
      void bin(String name, String body) {
        final f = File('${fake.path}/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
        Process.runSync('chmod', ['+x', f.path]);
      }
      bin('pm', r'''
echo "pm $*" >> "$FAKE_DIR/calls.log"
case "$1" in
  path) echo "package:$FAKE_OLD_APK" ;;
  install)
    case "$*" in
      *" -d "*) if [ "$FAKE_ROLLBACK" = "fail" ]; then echo "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]"; else echo "Success"; fi ;;
      *) if [ "$FAKE_INSTALL" = "fail" ]; then echo "Failure [INSTALL_FAILED_INVALID_APK]"; else echo "Success"; fi ;;
    esac ;;
esac''');
      bin('am', r'''
echo "am $*" >> "$FAKE_DIR/calls.log"
if [ "$FAKE_HEALTH" = "1" ]; then echo "ok $FAKE_CODE" > "$FAKE_HEALTH_FILE"; fi''');
      bin('cmd', r'echo "cmd $*" >> "$FAKE_DIR/calls.log"');
      bin('sleep', 'exec /bin/sleep 0.01');
      File('${dir.path}/old.apk').writeAsStringSync('OLD-APK-BYTES');
      File('${dir.path}/new.apk').writeAsStringSync('NEW-APK-BYTES');
      File('${dir.path}/update.sh').writeAsStringSync(updateScriptText);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<(ProcessResult, ProtocolSummary, String)> run({
      String mode = 'install',
      String health = '1',
      String install = 'ok',
      String rollback = 'ok',
      String apk = 'new.apk',
      String kiosk = '0',
      String pkg = 'ee.test.pkg',
    }) async {
      final healthFile = '${dir.path}/health';
      final r = await Process.run(
        'sh',
        [
          '${dir.path}/update.sh',
          mode,
          pkg,
          apk == 'new.apk' ? '${dir.path}/new.apk' : apk,
          '${dir.path}/backup.apk',
          '10',
          healthFile,
          '${dir.path}/protocol.log',
          'ee.test.KioskHomeAlias',
          'ee.test.MainActivity',
          kiosk,
          '4',
        ],
        includeParentEnvironment: false,
        environment: {
          'PATH': '${fake.path}:/usr/bin:/bin',
          'FAKE_DIR': dir.path,
          'FAKE_OLD_APK': '${dir.path}/old.apk',
          'FAKE_HEALTH': health,
          'FAKE_CODE': '10',
          'FAKE_HEALTH_FILE': healthFile,
          'FAKE_INSTALL': install,
          'FAKE_ROLLBACK': rollback,
        },
      );
      final proto = File('${dir.path}/protocol.log').existsSync()
          ? File('${dir.path}/protocol.log').readAsStringSync()
          : '';
      final calls = File('${dir.path}/calls.log').existsSync()
          ? File('${dir.path}/calls.log').readAsStringSync()
          : '';
      return (r, UpdateProtocol.parse(proto), calls);
    }

    test('синтаксис скрипта корректен (sh -n)', () {
      final r = Process.runSync('sh', ['-n', '${dir.path}/update.sh']);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    });

    test('успех: резерв снят ДО установки, новая версия подтвердила здоровье', () async {
      final (r, proto, calls) = await run();
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(proto.outcome, UpdateOutcome.installed);
      expect(File('${dir.path}/backup.apk').readAsStringSync(), 'OLD-APK-BYTES');
      final lines = calls.trim().split('\n');
      final iPath = lines.indexWhere((l) => l.startsWith('pm path'));
      final iInstall = lines.indexWhere((l) => l.startsWith('pm install'));
      expect(iPath, lessThan(iInstall));
      expect(lines[iInstall], 'pm install -r ${dir.path}/new.apk'); // без -d
      expect(calls, contains('am start -n ee.test.pkg/ee.test.MainActivity'));
      expect(calls, isNot(contains(' -d ')));
    });

    test('установка не удалась: откат не нужен, приложение не запускалось', () async {
      final (r, proto, calls) = await run(install: 'fail');
      expect(r.exitCode, 12);
      expect(proto.outcome, UpdateOutcome.failed);
      expect(proto.detail, contains('INSTALL_FAILED_INVALID_APK'));
      expect(calls, isNot(contains('am start')));
      expect(calls, isNot(contains(' -d ')));
    });

    test('нет сигнала здоровья: откат резервной с флагом понижения', () async {
      final (r, proto, calls) = await run(health: '0');
      expect(r.exitCode, 0);
      expect(proto.outcome, UpdateOutcome.rolledBack);
      expect(proto.events, containsAllInOrder(['install_ok', 'started', 'health_timeout', 'rollback_start', 'rollback_ok']));
      expect(calls, contains('pm install -r -d ${dir.path}/backup.apk'));
      expect('am start'.allMatches(calls).length, 2); // после установки и после отката
    });

    test('откат тоже не удался: rollback_failed, код возврата 14', () async {
      final (r, proto, _) = await run(health: '0', rollback: 'fail');
      expect(r.exitCode, 14);
      expect(proto.outcome, UpdateOutcome.rollbackFailed);
    });

    test('ручной откат: резерв не пересоздаётся, ставится с -d, без health_timeout-отката', () async {
      File('${dir.path}/backup.apk').writeAsStringSync('BACKUP');
      final (r, proto, calls) = await run(mode: 'rollback');
      expect(r.exitCode, 0);
      expect(calls, contains('pm install -r -d ${dir.path}/backup.apk'));
      expect(calls, isNot(contains('pm path')));
      expect(File('${dir.path}/backup.apk').readAsStringSync(), 'BACKUP');
      expect(proto.events, contains('rollback_ok'));
    });

    test('киоск был включён: роль и алиас возвращаются', () async {
      final (_, _, calls) = await run(kiosk: '1');
      expect(calls, contains('pm enable ee.test.pkg/ee.test.KioskHomeAlias'));
      expect(calls, contains('cmd role add-role-holder --user 0 android.app.role.HOME ee.test.pkg'));
    });

    test('киоск выключен: роль не трогается', () async {
      final (_, _, calls) = await run(kiosk: '0');
      expect(calls, isNot(contains('cmd role')));
      expect(calls, isNot(contains('pm enable')));
    });

    test('аргументы с метасимволами не исполняются (всё в кавычках)', () async {
      final hack = '${dir.path}/HACKED';
      final (_, _, calls) = await run(apk: '${dir.path}/a b; touch $hack');
      expect(File(hack).existsSync(), isFalse);
      expect(calls, contains('a b; touch'));
    });

    test('неверный режим: отказ без действий', () async {
      final (r, _, calls) = await run(mode: 'format');
      expect(r.exitCode, 10);
      expect(calls, isNot(contains('pm install')));
    });
  });

  // ============================================================ оркестратор
  group('UpdateService', () {
    late Directory tmp;
    late _FakeInstaller installer;
    late List<int> bytes;
    late AppNotifier n;

    AppNotifier notifier() => AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: false,
        deviceId: 'TEST-001',
        cloudUrl: 'https://proj.supabase.co',
        cloudAnonKey: 'anon-KEY-XYZ',
        cloudToken: 'tok-SECRET-123',
      )
      ..transition(AppState.standby);

    ReleaseTicket ticket({int? size, String? sha, int code = 10}) => ReleaseTicket(
      url: Uri.parse('https://proj.supabase.co/signed'),
      sha256: sha ?? sha256.convert(bytes).toString(),
      sizeBytes: size ?? bytes.length,
      versionCode: code,
      versionName: '1.6.0',
    );

    void setup({
      ReleaseTicket? t,
      ApkInfo? apk,
      int free = 1 << 40,
      Future<void> Function(Uri, File, int)? dl,
    }) {
      UpdateService.dirProvider = () async => Directory('${tmp.path}/update');
      UpdateService.installer = installer;
      UpdateService.ticketFetcher = (cfg, id) async => t ?? ticket();
      UpdateService.downloader = dl ?? (url, f, max) async => f.writeAsBytes(bytes);
      UpdateService.apkVerifier = (path) async =>
          apk ?? const ApkInfo(packageName: 'ee.test.pkg', versionCode: 10, versionName: '1.6.0', signatureMatches: true);
      UpdateService.appInfoProvider = () async => const AppInfo('ee.test.pkg', 9, '1.5.1');
      UpdateService.diskFreeProvider = () async => free;
    }

    Future<List<String>> eventTypes() async =>
        (await CloudService.history()).map((e) => e.type).toList();

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      CloudService.resetQueueForTest();
      CloudService.transport = LocalLogTransport();
      UpdateService.resetForTest();
      tmp = await Directory.systemTemp.createTemp('r2upd');
      installer = _FakeInstaller();
      bytes = List<int>.generate(2048, (i) => i % 251);
      n = notifier();
      messenger.setMockMethodCallHandler(modbus, (c) async {
        if (c.method == 'readCoils') return List.generate(12, (_) => false);
        return true;
      });
    });

    tearDown(() async {
      UpdateService.resetForTest();
      messenger.setMockMethodCallHandler(modbus, null);
      ModbusService.paymentBlocked = false;
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('успех: файл на месте, оплата заблокирована, скрипт запускается ПОСЛЕ ack', () async {
      setup();
      final res = await UpdateService.startUpdate(n, 'rel-1');
      expect(res.ok, isTrue);
      expect(res.result, 'update_started');
      expect(File('${tmp.path}/update/new.apk').existsSync(), isTrue);
      expect(File('${tmp.path}/update/new.apk.part').existsSync(), isFalse);
      expect(installer.started, isEmpty); // до ack скрипт не запущен
      expect(n.isMaintenance, isTrue);
      expect(n.isPaymentBlocked, isTrue);
      expect(ModbusService.paymentBlocked, isTrue);
      expect(await eventTypes(), contains(CloudEventType.updateStarted));
      await res.afterAck!();
      expect(installer.started.single.mode, 'install');
      expect(installer.started.single.targetVersionCode, 10);
      expect(installer.scriptTexts.single, updateScriptText);
      expect(File('${tmp.path}/update/pending.json').existsSync(), isTrue);
      expect(File('${tmp.path}/update/backup.json').existsSync(), isTrue);
      // клиент до оплаты не доходит
      n.selectFlavor(0);
      expect(n.state, AppState.outOfService);
      expect(n.isOutOfService, isFalse); // постоянного признака нет
      UpdateService.resetForTest();
    });

    test('битая SHA-256: отказ sha_mismatch, файл удалён, блок снят', () async {
      setup(t: ticket(sha: 'a' * 64));
      final res = await UpdateService.startUpdate(n, 'rel-1');
      expect(res.ok, isFalse);
      expect(res.result, 'sha_mismatch');
      expect(Directory('${tmp.path}/update').listSync().whereType<File>().where((f) => f.path.endsWith('.apk') || f.path.endsWith('.part')), isEmpty);
      expect(n.isMaintenance, isFalse);
      expect(UpdateService.inProgress, isFalse);
      expect(installer.started, isEmpty);
      expect(await eventTypes(), contains(CloudEventType.updateFailed));
    });

    test('размер не совпал: size_mismatch', () async {
      setup(t: ticket(size: bytes.length + 5));
      expect((await UpdateService.startUpdate(n, 'r')).result, 'size_mismatch');
    });

    test('чужой пакет / versionCode не тот: bad_package', () async {
      setup(apk: const ApkInfo(packageName: 'evil.pkg', versionCode: 10, signatureMatches: true));
      expect((await UpdateService.startUpdate(n, 'r')).result, 'bad_package');
      n = notifier();
      setup(apk: const ApkInfo(packageName: 'ee.test.pkg', versionCode: 11, signatureMatches: true));
      expect((await UpdateService.startUpdate(n, 'r')).result, 'bad_package');
    });

    test('подпись не совпала: bad_signature, файл удалён', () async {
      setup(apk: const ApkInfo(packageName: 'ee.test.pkg', versionCode: 10, signatureMatches: false));
      final res = await UpdateService.startUpdate(n, 'r');
      expect(res.result, 'bad_signature');
      expect(File('${tmp.path}/update/new.apk').existsSync(), isFalse);
      expect(n.isMaintenance, isFalse);
    });

    test('версия не новее: not_newer — до скачивания', () async {
      var downloaded = false;
      setup(t: ticket(code: 9), dl: (u, f, m) async => downloaded = true);
      expect((await UpdateService.startUpdate(n, 'r')).result, 'not_newer');
      expect(downloaded, isFalse);
      n = notifier();
      setup(t: ticket(code: 8));
      expect((await UpdateService.startUpdate(n, 'r')).result, 'not_newer');
    });

    test('обрыв загрузки: download_failed, недокачанный файл удалён', () async {
      setup(dl: (url, f, max) async {
        await f.writeAsBytes([1, 2, 3]);
        throw const DownloadException('network');
      });
      final res = await UpdateService.startUpdate(n, 'r');
      expect(res.result, 'download_failed');
      expect(File('${tmp.path}/update/new.apk.part').existsSync(), isFalse);
      expect(File('${tmp.path}/update/new.apk').existsSync(), isFalse);
      expect(n.isMaintenance, isFalse);
    });

    test('нет места: no_space (меньше трёх размеров APK)', () async {
      setup(free: bytes.length * 3 - 1);
      expect((await UpdateService.startUpdate(n, 'r')).result, 'no_space');
      n = notifier();
      setup(free: bytes.length * 3);
      expect((await UpdateService.startUpdate(n, 'r')).ok, isTrue);
      UpdateService.resetForTest();
    });

    test('нет root: no_root, ничего не скачивалось и не менялось', () async {
      var downloaded = false;
      installer.available = false;
      setup(dl: (u, f, m) async => downloaded = true);
      final res = await UpdateService.startUpdate(n, 'r');
      expect(res.result, 'no_root');
      expect(downloaded, isFalse);
      expect(n.isMaintenance, isFalse);
    });

    test('ТЭН не выключился: отказ, обновление не начато', () async {
      messenger.setMockMethodCallHandler(modbus, (c) async {
        if (c.method == 'readCoils') return List.generate(12, (i) => i == 9); // ТЭН включён
        return true;
      });
      setup();
      final res = await UpdateService.startUpdate(n, 'r');
      expect(res.result, 'heater_off_unconfirmed');
      expect(installer.started, isEmpty);
    });

    test('ошибки запроса ссылки сводятся к коду без деталей', () async {
      setup();
      UpdateService.ticketFetcher = (c, id) async => throw const DownloadException('rate_limited');
      expect((await UpdateService.startUpdate(n, 'r')).result, 'url_failed:rate_limited');
    });

    test('абсурдный размер в записи: bad_release', () async {
      setup(t: ticket(size: UpdateLimits.maxApkBytes + 1));
      expect((await UpdateService.startUpdate(n, 'r')).result, 'bad_release');
      n = notifier();
      setup(t: ticket(size: 0));
      expect((await UpdateService.startUpdate(n, 'r')).result, 'bad_release');
    });

    test('скрипт не запустился: update_failed, блок снят, файлы убраны', () async {
      installer.startOk = false;
      setup();
      final res = await UpdateService.startUpdate(n, 'r');
      await res.afterAck!();
      expect(n.isMaintenance, isFalse);
      expect(File('${tmp.path}/update/pending.json').existsSync(), isFalse);
      expect(File('${tmp.path}/update/new.apk').existsSync(), isFalse);
      expect(await eventTypes(), contains(CloudEventType.updateFailed));
    });

    test('откат: нет резерва → no_backup; есть резерв → скрипт rollback', () async {
      setup();
      expect((await UpdateService.startRollback(n)).result, 'no_backup');
      n = notifier();
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/backup.apk').writeAsStringSync('B');
      File('${tmp.path}/update/backup.json').writeAsStringSync(jsonEncode({'version_code': 8, 'version_name': '1.4.0'}));
      final res = await UpdateService.startRollback(n);
      expect(res.ok, isTrue);
      await res.afterAck!();
      expect(installer.started.single.mode, 'rollback');
      expect(installer.started.single.targetVersionCode, 8);
      UpdateService.resetForTest();
    });

    test('при старте новой версии: сигнал здоровья пишется, когда условия выполнены', () async {
      setup();
      UpdateService.appInfoProvider = () async => const AppInfo('ee.test.pkg', 10, '1.6.0');
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'started_at': DateTime.now().subtract(const Duration(seconds: 40)).toIso8601String(),
      }));
      n.setBusHealthy(false);
      await UpdateService.onStartup(n);
      expect(n.isMaintenance, isTrue);
      // шина нездорова — сигнала нет
      await Future.delayed(const Duration(milliseconds: 3500));
      expect(File('${tmp.path}/update/health').existsSync(), isFalse);
      n.setBusHealthy(true);
      await Future.delayed(const Duration(milliseconds: 3500));
      expect(File('${tmp.path}/update/health').readAsStringSync().trim(), 'ok 10');
      expect(File('${tmp.path}/update/pending.json').existsSync(), isFalse);
      expect(n.isMaintenance, isFalse);
      expect(await eventTypes(), contains(CloudEventType.updateInstalled));
      final st = await UpdateService.status();
      expect((st['last'] as Map)['result'], 'installed');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('при старте прежней версии: откат по протоколу → update_rolled_back, блок снят', () async {
      setup();
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'started_at': DateTime.now().subtract(const Duration(minutes: 7)).toIso8601String(),
      }));
      File('${tmp.path}/update/protocol.log').writeAsStringSync(
        '1 start\n2 install_ok\n3 started\n300 health_timeout\n301 rollback_start\n303 rollback_ok\n',
      );
      await UpdateService.onStartup(n);
      expect(await eventTypes(), contains(CloudEventType.updateRolledBack));
      expect(n.isMaintenance, isFalse);
      expect(File('${tmp.path}/update/pending.json').existsSync(), isFalse);
    });

    test('при старте прежней версии: установка не удалась → update_failed с причиной', () async {
      setup();
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'started_at': DateTime.now().subtract(const Duration(minutes: 1)).toIso8601String(),
      }));
      File('${tmp.path}/update/protocol.log').writeAsStringSync(
        '1 start\n2 backup_ok\n3 install_failed Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]\n',
      );
      await UpdateService.onStartup(n);
      final ev = (await CloudService.history()).lastWhere((e) => e.type == CloudEventType.updateFailed);
      expect(ev.data['reason'], contains('INSTALL_FAILED_UPDATE_INCOMPATIBLE'));
      expect(n.isMaintenance, isFalse);
    });

    test('ADB по сети: переключение через интерфейс, событие, кэш состояния', () async {
      setup();
      expect(await UpdateService.setAdbNetwork(true), isTrue);
      expect(UpdateService.adbNetwork, isTrue);
      expect(installer.adb, isTrue);
      final ev = (await CloudService.history()).lastWhere((e) => e.type == CloudEventType.debugModeChanged);
      expect(ev.data['code'], 'adb_network');
      expect(ev.data['enabled'], isTrue);
      installer.adbOk = false;
      expect(await UpdateService.setAdbNetwork(false), isFalse);
      expect(UpdateService.adbNetwork, isTrue); // не изменилось, раз не удалось
    });

    test('заглушка Device Owner: всё not_supported', () async {
      final d = DeviceOwnerInstaller();
      expect(await d.isAvailable(const Duration(seconds: 1)), isFalse);
      expect(await d.setAdbNetwork(true), isFalse);
      expect(await d.readAdbNetwork(), isNull);
    });
  });

  // ================================================== запрос ссылки (HTTP)
  group('запрос подписанной ссылки', () {
    final cfg = AppConfig(
      deviceId: 'D1',
      cloudUrl: 'https://proj.supabase.co/',
      cloudAnonKey: 'anon-KEY-XYZ',
      cloudToken: 'tok-SECRET-123',
    );
    Future<Object> fetch(http.Response r) => http.runWithClient(
      () async {
        try {
          return await UpdateService.ticketFetcherDefault(cfg, 'rel');
        } on DownloadException catch (e) {
          return e.code;
        }
      },
      () => MockClient((req) async => r),
    );

    const goodBody = '{"ok":true,"url":"https://proj.supabase.co/storage/v1/object/sign/x?token=t","sha256":"%SHA%","size_bytes":100,"version_code":10,"version_name":"1.6.0","expires_in_s":600}';

    test('успех: запись разобрана', () async {
      final t = await fetch(http.Response(goodBody.replaceAll('%SHA%', 'a' * 64), 200));
      expect(t, isA<ReleaseTicket>());
      expect((t as ReleaseTicket).versionCode, 10);
    });

    test('ссылка на ЧУЖОЙ хост отклоняется (bad_url)', () async {
      final evil = goodBody.replaceAll('proj.supabase.co', 'evil.example.com').replaceAll('%SHA%', 'a' * 64);
      expect(await fetch(http.Response(evil, 200)), 'bad_url');
    });

    test('не https — bad_url', () async {
      final plain = goodBody.replaceAll('https://', 'http://').replaceAll('%SHA%', 'a' * 64);
      expect(await fetch(http.Response(plain, 200)), 'bad_url');
    });

    test('коды HTTP сводятся к коротким причинам', () async {
      expect(await fetch(http.Response('{"ok":false,"error":"auth"}', 401)), 'auth');
      expect(await fetch(http.Response('x', 404)), 'not_found');
      expect(await fetch(http.Response('x', 429)), 'rate_limited');
      expect(await fetch(http.Response('x', 500)), 'http_500');
      expect(await fetch(http.Response('not json', 200)), 'bad_response');
      expect(await fetch(http.Response('{"ok":false}', 200)), 'bad_response');
    });
  });

  // ====================================================== скачивание файла
  group('скачивание (реальный локальный HTTP-сервер)', () {
    late HttpServer server;
    late Directory tmp;
    setUp(() async {
      HttpOverrides.global = null; // flutter_test подменяет HttpClient на 400
      tmp = await Directory.systemTemp.createTemp('r2dl');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    tearDown(() async {
      await server.close(force: true);
      await tmp.delete(recursive: true);
    });

    void serve(void Function(HttpRequest) h) => server.listen(h);
    Uri url() => Uri.parse('http://127.0.0.1:${server.port}/f.apk');

    test('файл скачивается целиком', () async {
      final data = List<int>.generate(5000, (i) => i % 200);
      serve((r) {
        r.response.add(data);
        r.response.close();
      });
      final f = File('${tmp.path}/a.part');
      await UpdateService.downloaderDefault(url(), f, 10000);
      expect(f.readAsBytesSync(), data);
    });

    test('больше заявленного размера не принимается (too_big)', () async {
      serve((r) {
        r.response.add(List<int>.filled(5000, 1));
        r.response.close();
      });
      expect(
        UpdateService.downloaderDefault(url(), File('${tmp.path}/b.part'), 1000),
        throwsA(isA<DownloadException>().having((e) => e.code, 'code', 'too_big')),
      );
    });

    test('HTTP-ошибка → DownloadException(http_404)', () async {
      serve((r) {
        r.response.statusCode = 404;
        r.response.close();
      });
      expect(
        UpdateService.downloaderDefault(url(), File('${tmp.path}/c.part'), 1000),
        throwsA(isA<DownloadException>().having((e) => e.code, 'code', 'http_404')),
      );
    });

    test('редирект не выполняется (ссылка не должна уводить на другой хост)', () async {
      serve((r) {
        r.response.statusCode = 302;
        r.response.headers.set('location', 'http://evil.example.com/x');
        r.response.close();
      });
      expect(
        UpdateService.downloaderDefault(url(), File('${tmp.path}/d.part'), 1000),
        throwsA(isA<DownloadException>()),
      );
    });
  });

  // ========================================================= команды облака
  group('команды update_app / rollback_app', () {
    late AppNotifier n;
    CloudCommand cmd(String action, {String? id, DateTime? at, Map<String, dynamic>? params}) =>
        CloudCommand(
          id: id ?? '$action-${DateTime.now().microsecondsSinceEpoch}',
          action: action,
          params: params ?? {'release_id': '123e4567-e89b-12d3-a456-426614174000'},
          createdAt: at ?? DateTime.now(),
        );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      CloudService.resetQueueForTest();
      UpdateService.resetForTest();
      n = AppNotifier()
        ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: false)
        ..transition(AppState.standby);
    });
    tearDown(UpdateService.resetForTest);

    test('без created_at не выполняется', () async {
      final o = await RemoteCommands.handle(
        CloudCommand(id: 'u1', action: 'update_app', params: {'release_id': '123e4567-e89b-12d3-a456-426614174000'}),
        n,
      );
      expect(o.result, 'no_created_at');
      final o2 = await RemoteCommands.handle(CloudCommand(id: 'u2', action: 'rollback_app'), n);
      expect(o2.result, 'no_created_at');
    });

    test('просроченная и дубль — отказ', () async {
      final old = await RemoteCommands.handle(
        cmd('update_app', at: DateTime.now().subtract(const Duration(minutes: 11))), n);
      expect(old.result, 'expired');
      final c = cmd('update_app', id: 'same');
      UpdateService.installer = _FakeInstaller()..available = false;
      UpdateService.dirProvider = () async => Directory.systemTemp.createTempSync('dup');
      await RemoteCommands.handle(c, n); // исполнена (no_root), id запомнен
      final dup = await RemoteCommands.handle(c, n);
      expect(dup.result, 'duplicate');
    });

    test('только standby/outOfService: иначе busy', () async {
      for (final s in [AppState.selectLanguage, AppState.selectFlavor, AppState.payment, AppState.preparing, AppState.treating, AppState.finished, AppState.serviceMenu]) {
        final m = AppNotifier()
          ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: false)
          ..transition(s);
        final o = await RemoteCommands.handle(cmd('update_app', id: 'b-${s.name}'), m);
        expect(o.result, startsWith('busy'), reason: s.name);
        final o2 = await RemoteCommands.handle(cmd('rollback_app', id: 'br-${s.name}'), m);
        expect(o2.result, startsWith('busy'), reason: s.name);
        expect(m.isMaintenance, isFalse);
      }
    });

    test('release_id должен быть uuid', () async {
      for (final bad in [null, '', 'abc', 5, '../../etc/passwd', "1; rm -rf /"]) {
        final o = await RemoteCommands.handle(
          cmd('update_app', id: 'r-$bad', params: {'release_id': bad}), n);
        expect(o.result, 'invalid:release_id', reason: '$bad');
      }
    });

    test('лимит: не чаще раза в 10 минут и 3 в сутки', () async {
      UpdateService.installer = _FakeInstaller()..available = false;
      UpdateService.dirProvider = () async => Directory.systemTemp.createTempSync('rate');
      final t0 = DateTime(2026, 10, 4, 9);
      Future<String> go(String id, DateTime at) async => (await RemoteCommands.handle(
            cmd('update_app', id: id, at: at), n, now: at)).result;
      expect(await go('a1', t0), 'no_root'); // дошла до исполнения
      expect(await go('a2', t0.add(const Duration(minutes: 5))), 'rate_limited');
      expect(await go('a3', t0.add(const Duration(minutes: 11))), 'no_root');
      expect(await go('a4', t0.add(const Duration(minutes: 22))), 'no_root');
      expect(await go('a5', t0.add(const Duration(minutes: 33))), 'rate_limited'); // 4-я за сутки
      expect(await go('a6', t0.add(const Duration(hours: 25))), 'no_root');
    });

    test('rollback_app без резерва: no_backup (без root-вызовов)', () async {
      final f = _FakeInstaller();
      UpdateService.installer = f;
      UpdateService.dirProvider = () async => Directory.systemTemp.createTempSync('nobackup');
      final o = await RemoteCommands.handle(cmd('rollback_app', params: const {}), n);
      expect(o.result, 'no_backup');
      expect(f.started, isEmpty);
    });
  });

  test('свежие параметры: обновление не чаще, чем задано владельцем', () {
    expect(UpdateLimits.commandMinInterval, const Duration(minutes: 10));
    expect(UpdateLimits.commandsPerDay, 3);
    expect(UpdateLimits.diskSpaceFactor, 3);
    expect(UpdateLimits.healthTimeout, const Duration(minutes: 5));
  });

  test('опрос облака: ok только при штатном ответе', () {
    expect(CloudPollResult(commands: const []).ok, isFalse);
    expect(CloudPollResult(commands: const [], ok: true).ok, isTrue);
    expect(SyncService.lastPollOkAt, anyOf(isNull, isA<DateTime>()));
  });
}

class _FakeInstaller implements PrivilegedInstaller {
  bool available = true;
  bool startOk = true;
  bool adbOk = true;
  bool adb = false;
  final List<InstallRequest> started = [];
  final List<String> scriptTexts = [];

  @override
  String get kind => 'fake';

  @override
  Future<bool> isAvailable(Duration timeout) async => available;

  @override
  Future<bool> startScript(InstallRequest request, String scriptText) async {
    started.add(request);
    scriptTexts.add(scriptText);
    return startOk;
  }

  @override
  Future<bool> setAdbNetwork(bool enabled) async {
    if (!adbOk) return false;
    adb = enabled;
    return true;
  }

  @override
  Future<bool?> readAdbNetwork() async => adb;
}
