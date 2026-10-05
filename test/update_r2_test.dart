import 'dart:async';
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
      bin('stat', 'echo 10123:10123');
      bin('chown', r'echo "chown $*" >> "$FAKE_DIR/calls.log"');
      bin('restorecon', r'echo "restorecon $*" >> "$FAKE_DIR/calls.log"');
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
      String activity = 'ee.test.MainActivity',
      String alias = 'ee.test.KioskHomeAlias',
      // root — уже вне cgroup приложения; movable — в cgroup приложения, но
      // перенос в корень удаётся; stuck — в cgroup приложения, перенос не
      // удаётся (нет прав / нет cgroup2 / другое ядро).
      String cg = 'root',
      String umask = '022',
    }) async {
      final healthFile = '${dir.path}/health';
      final cgRoot = Directory('${dir.path}/cgroot')..createSync(recursive: true);
      final cgSelf = '${cgRoot.path}/cgroup.procs';
      File('${dir.path}/mounts').writeAsStringSync(
        cg == 'nocgroup2'
            ? 'none /dev/cpuctl cgroup rw 0 0\n'
            : 'none ${cgRoot.path} cgroup2 rw 0 0\n',
      );
      // «/proc/self/cgroup» подменён файлом; для movable это ТОТ ЖЕ файл, что
      // cgroup.procs: запись PID в него = «перенос», строки cgroup пропадают.
      final selfFile = cg == 'stuck' || cg == 'nocgroup2'
          ? '${dir.path}/self_cgroup'
          : cgSelf;
      File(selfFile).writeAsStringSync(
        cg == 'root' ? '0::/\n' : '0::/uid_10123/pid_4242\n',
      );
      if (cg == 'stuck') {
        // cgroup.procs есть, но «запись» ничего не меняет (self_cgroup — другой файл)
        File(cgSelf).writeAsStringSync('');
      }
      final r = await Process.run(
        'sh',
        [
          '-c',
          'umask $umask; exec sh "\$@"',
          'sh',
          '${dir.path}/update.sh',
          mode,
          pkg,
          apk == 'new.apk' ? '${dir.path}/new.apk' : apk,
          '${dir.path}/backup.apk',
          '10',
          healthFile,
          '${dir.path}/protocol.log',
          alias,
          activity,
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
          'CG_SELF': selfFile,
          'CG_MOUNTS': '${dir.path}/mounts',
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

    test('выживание: в cgroup приложения, перенос удаётся — установка идёт', () async {
      final (r, proto, calls) = await run(cg: 'movable');
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(proto.events, containsAllInOrder(['diag', 'survive_ok', 'backup_ok', 'install_ok', 'health_ok']));
      expect(calls, contains('pm install -r'));
    });

    for (final cg in ['stuck', 'nocgroup2']) {
      test('no_survive ($cg): перенос не удался — pm install НЕ вызывается, exit 15', () async {
        final (r, proto, calls) = await run(cg: cg);
        expect(r.exitCode, 15, reason: cg);
        expect(proto.outcome, UpdateOutcome.failed, reason: cg);
        expect(proto.detail, startsWith('root='), reason: cg);
        expect(proto.events, contains('no_survive'), reason: cg);
        expect(proto.events, isNot(contains('backup_ok')), reason: cg);
        expect(calls, isNot(contains('pm install')), reason: cg);
        expect(calls, isNot(contains('pm path')), reason: cg);
        expect(calls, contains('chown -R'), reason: '$cg: файлы всё равно отдаются приложению');
      });
    }

    test('no_survive и в режиме отката', () async {
      final (r, _, calls) = await run(mode: 'rollback', cg: 'stuck');
      expect(r.exitCode, 15);
      expect(calls, isNot(contains('pm install')));
    });

    test('успех: new.apk удаляется скриптом после health_ok', () async {
      File('${dir.path}/new.apk').writeAsStringSync('X');
      await run();
      expect(File('${dir.path}/new.apk').existsSync(), isFalse);
      expect(File('${dir.path}/backup.apk').existsSync(), isTrue); // резерв остаётся
    });

    test('протокол читаем приложению: chmod 644 даже при umask 077', () async {
      await run(umask: '077');
      final mode = File('${dir.path}/protocol.log').statSync().mode & 0x1ff;
      expect(mode.toRadixString(8), '644');
    });

    test('пакет и namespace разные: компонент = пакет/класс из namespace', () async {
      final (_, _, calls) = await run(
        kiosk: '1',
        pkg: 'ee.carfog.dryfog',
        activity: 'com.example.dry_fog_app.MainActivity',
        alias: 'com.example.dry_fog_app.KioskHomeAlias',
      );
      expect(calls, contains('am start -n ee.carfog.dryfog/com.example.dry_fog_app.MainActivity'));
      expect(calls, contains('pm enable ee.carfog.dryfog/com.example.dry_fog_app.KioskHomeAlias'));
      expect(calls, contains('android.app.role.HOME ee.carfog.dryfog'));
      expect(calls, isNot(contains('ee.carfog.dryfog.MainActivity')));
    });

    test('протокол: диагностика, шаги с временем, владелец возвращён при выходе', () async {
      final (_, proto, calls) = await run(kiosk: '1');
      expect(proto.events, containsAllInOrder([
        'diag', 'start', 'backup_ok', 'install_ok', 'alias_enabled',
        'kiosk_role_restored', 'started', 'health_ok', 'owner_fixed',
      ]));
      final raw = File('${dir.path}/protocol.log').readAsStringSync();
      expect(raw, contains('cgroup='));
      expect(raw, contains('ctx='));
      expect(raw, contains('pid='));
      expect(calls, contains('chown -R 10123:10123 ${dir.path}'));
      expect(calls, contains('restorecon -R ${dir.path}'));
    });

    test('владелец возвращается и при неудачной установке', () async {
      final (_, _, calls) = await run(install: 'fail');
      expect(calls, contains('chown -R 10123:10123'));
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

    test('новое приложение: скрипт не дошёл до конца → само чинит каталог и роль', () async {
      setup();
      UpdateService.repairGrace = const Duration(milliseconds: 200);
      UpdateService.repairPoll = const Duration(milliseconds: 50);
      UpdateService.appInfoProvider = () async => const AppInfo('ee.test.pkg', 10, '1.6.0');
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/new.apk').writeAsStringSync('X');
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'kiosk': true, 'started_at': DateTime.now().toIso8601String(),
      }));
      // протокол оборван на backup_ok (как было на планшете), нечитаем или пуст
      File('${tmp.path}/update/protocol.log').writeAsStringSync('1 diag x\n2 start\n3 backup_ok\n');
      n.setBusHealthy(true);
      await UpdateService.onStartup(n);
      expect(installer.repairs, isEmpty); // ещё рано: нет сигнала здоровья
      await Future.delayed(const Duration(milliseconds: 4500));
      expect(installer.repairs, hasLength(1));
      expect(installer.repairs.single['kiosk'], isTrue);
      expect(installer.repairs.single['pkg'], 'ee.test.pkg');
      expect(File('${tmp.path}/update/new.apk').existsSync(), isFalse); // мусор убран
      UpdateService.resetForTest();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('новое приложение: скрипт дошёл до конца (owner_fixed) — починка не нужна', () async {
      setup();
      UpdateService.appInfoProvider = () async => const AppInfo('ee.test.pkg', 10, '1.6.0');
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'started_at': DateTime.now().toIso8601String(),
      }));
      File('${tmp.path}/update/protocol.log').writeAsStringSync('1 start\n2 health_ok\n3 owner_fixed owner=1:1\n');
      n.setBusHealthy(true);
      UpdateService.repairGrace = const Duration(milliseconds: 100);
      UpdateService.repairPoll = const Duration(milliseconds: 50);
      await UpdateService.onStartup(n);
      await Future.delayed(const Duration(milliseconds: 4500));
      expect(installer.repairs, isEmpty);
      UpdateService.resetForTest();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('протокол нечитаем (нет прав) = скрипт ещё работает: не чиним', () async {
      setup();
      UpdateService.repairGrace = const Duration(milliseconds: 100);
      UpdateService.repairPoll = const Duration(milliseconds: 50);
      UpdateService.appInfoProvider = () async => const AppInfo('ee.test.pkg', 10, '1.6.0');
      Directory('${tmp.path}/update').createSync(recursive: true);
      // файл без прав на чтение (как root:root 0600 для приложения)
      File('${tmp.path}/update/protocol.log').writeAsStringSync('1 start\n');
      Process.runSync('chmod', ['000', '${tmp.path}/update/protocol.log']);
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'started_at': DateTime.now().toIso8601String(),
      }));
      n.setBusHealthy(true);
      await UpdateService.onStartup(n);
      await Future.delayed(const Duration(milliseconds: 5000));
      expect(installer.repairs, isEmpty); // грации вышли давно, но нечитаемый ≠ мёртвый
      // протокол стал читаемым и без owner_fixed → теперь чинит
      Process.runSync('chmod', ['644', '${tmp.path}/update/protocol.log']);
      await Future.delayed(const Duration(milliseconds: 600));
      expect(installer.repairs, hasLength(1));
      UpdateService.resetForTest();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('починка не удалась → событие update_failed (repair_failed)', () async {
      setup();
      installer.repairOk = false;
      UpdateService.appInfoProvider = () async => const AppInfo('ee.test.pkg', 10, '1.6.0');
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'started_at': DateTime.now().toIso8601String(),
      }));
      UpdateService.repairGrace = const Duration(milliseconds: 100);
      UpdateService.repairPoll = const Duration(milliseconds: 50);
      n.setBusHealthy(true);
      await UpdateService.onStartup(n);
      await Future.delayed(const Duration(milliseconds: 4500));
      final ev = (await CloudService.history()).lastWhere((e) => e.type == CloudEventType.updateFailed);
      expect(ev.data['reason'], 'repair_failed');
      UpdateService.resetForTest();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('no_survive в протоколе: приложение остаётся прежним, update_failed:no_survive, блок снят', () async {
      setup();
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/new.apk').writeAsStringSync('X');
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'started_at': DateTime.now().toIso8601String(),
      }));
      File('${tmp.path}/update/protocol.log').writeAsStringSync(
        '1 diag x\n2 no_survive root=/sys/fs/cgroup uid=10123 cgroup=0::/uid_10123/pid_1;\n',
      );
      await UpdateService.onStartup(n); // текущая версия (9) == прежняя
      final ev = (await CloudService.history()).lastWhere((e) => e.type == CloudEventType.updateFailed);
      expect((ev.data['reason'] as String), startsWith('root='));
      expect(n.isMaintenance, isFalse);
      expect(File('${tmp.path}/update/new.apk').existsSync(), isFalse);
      expect(File('${tmp.path}/update/pending.json').existsSync(), isFalse);
    });

    // ---- учёт лимитов: суточный счёт — только запуски скрипта ----
    const relId = '123e4567-e89b-12d3-a456-426614174000';
    Future<CommandOutcome> go(String id, DateTime at, {String action = 'update_app'}) {
      UpdateService.clock = () => at;
      return RemoteCommands.handle(
        CloudCommand(id: id, action: action, params: action == 'update_app' ? {'release_id': relId} : {}, createdAt: at),
        n,
        now: at,
      );
    }

    // Принятая команда доводится до запуска скрипта (как после ack).
    Future<String> goRun(String id, DateTime at) async {
      final o = await go(id, at);
      if (o.afterAck != null) await o.afterAck!();
      UpdateService.inProgress = false;
      n.setMaintenance(false);
      return o.result;
    }

    final t0 = DateTime(2026, 10, 4, 9);
    Duration m(int x) => Duration(minutes: x);

    test('неудачи до запуска не расходуют квоту запусков, но пауза 10 минут действует', () async {
      setup(t: ticket(sha: 'a' * 64)); // sha_mismatch
      expect((await go('f1', t0)).result, 'sha_mismatch');
      expect((await go('f2', t0.add(m(5)))).result, 'rate_limited'); // пауза
      for (var i = 0; i < 5; i++) {
        expect((await go('g$i', t0.add(m(11 * (i + 1))))).result, 'sha_mismatch');
      }
      // квота запусков нетронута: три запуска подряд проходят
      setup();
      final base = t0.add(m(200));
      expect(await goRun('r1', base), 'update_started');
      expect(await goRun('r2', base.add(m(11))), 'update_started');
      expect(await goRun('r3', base.add(m(22))), 'update_started');
      expect((await go('r4', base.add(m(33)))).result, 'rate_limited'); // 4-й запуск за сутки
      expect((await go('r5', base.add(const Duration(hours: 25)))).ok, isTrue); // окно ушло
      UpdateService.inProgress = false;
    });

    test('потолок неудач до запуска: 12 в сутки, 13-я — rate_limited', () async {
      setup(t: ticket(code: 9)); // not_newer
      for (var i = 0; i < 12; i++) {
        expect((await go('n$i', t0.add(m(11 * i)))).result, 'not_newer', reason: '$i');
      }
      expect((await go('n12', t0.add(m(11 * 12)))).result, 'rate_limited');
      // через сутки после первой метки окно сдвинулось
      expect((await go('n13', t0.add(const Duration(hours: 24, minutes: 30)))).result, 'not_newer');
    });

    test('busy, invalid и дубль: паузу и счётчики не занимают', () async {
      setup();
      final busy = AppNotifier()
        ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: false)
        ..transition(AppState.payment);
      UpdateService.clock = () => t0;
      final o = await RemoteCommands.handle(
        CloudCommand(id: 'b1', action: 'update_app', params: {'release_id': relId}, createdAt: t0), busy, now: t0);
      expect(o.result, startsWith('busy'));
      final bad = await RemoteCommands.handle(
        CloudCommand(id: 'b2', action: 'update_app', params: {'release_id': 'x'}, createdAt: t0), n, now: t0);
      expect(bad.result, 'invalid:release_id');
      expect(await goRun('ok1', t0), 'update_started'); // сразу, паузы не было
    });

    test('install_start_failed: скрипт не запущен → это неудача, не запуск', () async {
      installer.startOk = false;
      setup();
      final o = await go('s1', t0);
      expect(o.result, 'update_started');
      await o.afterAck!(); // startScript вернул false
      UpdateService.inProgress = false;
      n.setMaintenance(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('remote_upd_fails_update_app'), hasLength(1));
      expect(prefs.getStringList('remote_upd_runs_update_app'), isNull);
    });

    test('no_survive считается запуском скрипта (скрипт был запущен)', () async {
      setup();
      expect(await goRun('v1', t0), 'update_started');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('remote_upd_runs_update_app'), hasLength(1));
    });

    test('rollback_app считается отдельно; локальная кнопка в лимит не входит', () async {
      setup();
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/backup.apk').writeAsStringSync('B');
      File('${tmp.path}/update/backup.json').writeAsStringSync(jsonEncode({'version_code': 8, 'version_name': '1.4.0'}));
      expect(await goRun('u1', t0), 'update_started');
      final o = await go('rb1', t0.add(m(11)), action: 'rollback_app');
      expect(o.result, 'rollback_started'); // свой счётчик, пауза от update_app не мешает
      await o.afterAck!();
      UpdateService.inProgress = false;
      n.setMaintenance(false);
      // локальный откат из меню: не считается
      final local = await UpdateService.startRollback(n, countQuota: false);
      expect(local.ok, isTrue);
      await local.afterAck!();
      UpdateService.inProgress = false;
      n.setMaintenance(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('remote_upd_runs_rollback_app'), hasLength(1));
    });

    test('причины сетевого сбоя различаются (dns / timeout / tls / connect)', () {
      expect(classifyNetworkError(TimeoutException('x')), 'timeout');
      expect(classifyNetworkError(const HandshakeException('x')), 'tls');
      expect(
        classifyNetworkError(http.ClientException(
          "SocketException: Failed host lookup: 'h' (OS Error: No address associated with hostname, errno = 7)")),
        'dns',
      );
      expect(classifyNetworkError(const SocketException('Connection reset by peer', osError: OSError('Connection reset by peer', 104))), 'connect');
      expect(classifyNetworkError(const SocketException('Network is unreachable')), 'connect');
      expect(classifyNetworkError(StateError('x')), 'other');
    });

    test('url_failed несёт причину: network:<dns|timeout|…>', () async {
      setup();
      UpdateService.ticketFetcher = UpdateService.ticketFetcherDefault;
      final res = await http.runWithClient(
        () => UpdateService.startUpdate(n, relId),
        () => MockClient((req) async => throw http.ClientException('Failed host lookup: x')),
      );
      expect(res.result, 'url_failed:network:dns');
    });

    test('флаг SKIP_HEALTH_SIGNAL: по умолчанию выключен; включённый — сигнала нет', () async {
      expect(UpdateLimits.skipHealthSignalBuild, isFalse);
      expect(UpdateService.skipHealthSignal, isFalse);
      setup();
      UpdateService.appInfoProvider = () async => const AppInfo('ee.test.pkg', 10, '1.6.0');
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/pending.json').writeAsStringSync(jsonEncode({
        'mode': 'install', 'from_code': 9, 'from_name': '1.5.1', 'to_code': 10, 'to_name': '1.6.0',
        'started_at': DateTime.now().toIso8601String(),
      }));
      UpdateService.skipHealthSignal = true;
      await UpdateService.onStartup(n);
      await Future.delayed(const Duration(milliseconds: 3500));
      expect(File('${tmp.path}/update/health').existsSync(), isFalse);
      expect(n.isMaintenance, isFalse);
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

    test('rollback_app без резерва: no_backup (без root-вызовов)', () async {
      final f = _FakeInstaller();
      UpdateService.installer = f;
      UpdateService.dirProvider = () async => Directory.systemTemp.createTempSync('nobackup');
      final o = await RemoteCommands.handle(cmd('rollback_app', params: const {}), n);
      expect(o.result, 'no_backup');
      expect(f.started, isEmpty);
    });
  });

  group('команда починки', () {
    test('кавычки и киоск', () {
      final c = buildRepairCommand(
        dir: "/data/x/it's/update", packageName: 'ee.carfog.dryfog',
        aliasClass: 'com.example.dry_fog_app.KioskHomeAlias', kiosk: true);
      expect(c, contains("'/data/x/it'\\''s/update'"));
      expect(c, contains('chown -R'));
      expect(c, contains('restorecon -R'));
      expect(c, contains("pm enable 'ee.carfog.dryfog/com.example.dry_fog_app.KioskHomeAlias'"));
      expect(c, contains('android.app.role.HOME'));
    });
    test('без киоска роль не трогается', () {
      final c = buildRepairCommand(dir: '/d', packageName: 'p', aliasClass: 'a', kiosk: false);
      expect(c, isNot(contains('cmd role')));
      expect(c, isNot(contains('pm enable')));
    });
    test('командная оболочка принимает собранную команду (sh -n)', () {
      final c = buildRepairCommand(dir: '/d', packageName: 'p', aliasClass: 'a', kiosk: true);
      expect(Process.runSync('sh', ['-n', '-c', c]).exitCode, 0);
    });
  });

  group('версия приложения', () {
    test('формат versionName+versionCode, без имени — запасное значение', () {
      expect(CloudService.formatVersion('1.5.8', 16), '1.5.8+16');
      expect(CloudService.formatVersion('1.5.8', null), '1.5.8');
      expect(CloudService.formatVersion(null, 16), CloudService.fallbackVersion);
      expect(CloudService.formatVersion('', 16), CloudService.fallbackVersion);
    });
    test('initVersion берёт значения из нативного getAppInfo; сбой → запасное', () async {
      const ch = MethodChannel('com.carfog.dryfog/system');
      messenger.setMockMethodCallHandler(ch, (c) async =>
          c.method == 'getAppInfo' ? {'version_name': '1.5.8', 'version_code': 16, 'package': 'p'} : null);
      await CloudService.initVersion();
      expect(CloudService.appVersion, '1.5.8+16');
      messenger.setMockMethodCallHandler(ch, (c) async => throw PlatformException(code: 'x'));
      await CloudService.initVersion();
      expect(CloudService.appVersion, CloudService.fallbackVersion);
      messenger.setMockMethodCallHandler(ch, null);
    });
  });

  test('свежие параметры: обновление не чаще, чем задано владельцем', () {
    expect(UpdateLimits.commandMinInterval, const Duration(minutes: 10));
    expect(UpdateLimits.commandsPerDay, 3);
    expect(UpdateLimits.diskSpaceFactor, 3);
    expect(UpdateLimits.failuresPerDay, 12);
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

  final List<Map<String, Object?>> repairs = [];
  bool repairOk = true;

  @override
  Future<bool> repairAfterUpdate({
    required String dir,
    required String packageName,
    required String aliasClass,
    required bool kiosk,
  }) async {
    repairs.add({'dir': dir, 'pkg': packageName, 'alias': aliasClass, 'kiosk': kiosk});
    return repairOk;
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
