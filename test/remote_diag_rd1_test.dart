import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/hardware_profile.dart';
import 'package:dry_fog_app/models/remote_limits.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/diagnostics_service.dart';
import 'package:dry_fog_app/services/health_summary.dart';
import 'package:dry_fog_app/services/master_code_service.dart';
import 'package:dry_fog_app/services/remote_commands.dart';
import 'package:dry_fog_app/services/screenshot_service.dart';
import 'package:dry_fog_app/services/system_service.dart';

// RD1 (ТЗ удалённой диагностики, разделы 4, 5, 10): пакет версии 2, очистка
// (ловушки), потолок размера, время UTC, снимок экрана и его запреты,
// лимит частоты, kiosk_lock и health для облака.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const system = MethodChannel('com.carfog.dryfog/system');
  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp;
  final systemCalls = <String>[];

  AppNotifier notifier() => AppNotifier()
    ..config = AppConfig(
      thermoInstalled: true,
      energyMeterInstalled: true,
      servicePin: '7351',
      cloudToken: 'tok-SECRET-123',
      cloudAnonKey: 'anon-SECRET-456',
      deviceId: 'TEST-001',
    );

  CloudCommand cmd(String action, {Map<String, dynamic>? params}) => CloudCommand(
    id: '$action-${DateTime.now().microsecondsSinceEpoch}',
    action: action,
    params: params,
    createdAt: DateTime.now(),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('rd1test');
    AppLog.resetForTest();
    ScreenshotService.resetForTest();
    DiagnosticsService.setDirForTest(tmp);
    DiagnosticsService.resetRefusalForTest();
    CloudService.transport = _CaptureTransport();
    HardwareProfile.current = HardwareProfile.fallback;
    systemCalls.clear();
    messenger.setMockMethodCallHandler(system, (c) async {
      systemCalls.add(c.method);
      switch (c.method) {
        case 'getDeviceInfo':
          return {'android_release': '13', 'net_type': 'wifi', 'thermal_max_c': 41.5};
        case 'getFilesDir':
          return tmp.path;
        case 'kioskPolicyState':
          return {
            'device_owner': true,
            'lock_enabled': true,
            'lock_task_active': true,
            'exit_remaining_ms': 0,
          };
        case 'getSystemBarsState':
          return {'enabled': true, 'nav_controllable': true, 'bars_visible': false};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(modbus, (c) async {
      switch (c.method) {
        case 'readTemperature':
          return 25.0;
        case 'readEnergy':
          return {'voltage': 230.0, 'current': 0.1, 'power': 0.016, 'totalEnergy': 1.0};
        case 'readCoils':
          return List.generate(12, (_) => false);
      }
      return null;
    });
    await AppLog.init(dir: tmp, reason: 'normal', version: '1');
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(system, null);
    messenger.setMockMethodCallHandler(modbus, null);
    HardwareProfile.current = HardwareProfile.fallback;
    ScreenshotService.resetForTest();
    AppLog.resetForTest();
    await tmp.delete(recursive: true);
  });

  group('очистка: ловушки', () {
    test('токен, PIN, ключ, Bearer, JWT, номер карты, мастер-код — не в пакете', () async {
      final n = notifier();
      AppLog.setSecrets([n.config.servicePin, n.config.cloudToken, n.config.cloudAnonKey]);
      final master = await MasterCodeService.generateNew();
      AppLog.log('trap', 'token=tok-SECRET-123 pin=7351 anon-SECRET-456');
      AppLog.log('trap', 'Authorization: Bearer abc.def.ghi');
      AppLog.log('trap', 'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl');
      AppLog.log('trap', 'card 4111 1111 1111 1111 and 5500-0000-0000-0004 and 4012888888881881');
      AppLog.log('trap', 'master code $master shown, master_code=$master');
      AppLog.log('trap', 'claim_code: ABCD-1234');
      final text = DiagnosticsService.encodeWithinCap(await DiagnosticsService.collect(n));
      for (final trap in [
        'tok-SECRET-123',
        'anon-SECRET-456',
        'pin=7351',
        'abc.def.ghi',
        'eyJhbGciOiJIUzI1NiJ9',
        '4111 1111 1111 1111',
        '5500-0000-0000-0004',
        '4012888888881881',
        master,
        'ABCD-1234',
      ]) {
        expect(text, isNot(contains(trap)), reason: trap);
      }
      expect(() => jsonDecode(text), returnsNormally);
    });

    test('время и идентификаторы не принимаются за номер карты', () {
      // мс эпохи начинаются с 1; дата, порт, сумма — короткие.
      const line = 'shot-1730660000000 diag-1730660000123 2026-11-04T10:00:00 /dev/ttyS5 1999';
      expect(AppLog.redact(line), line);
      // Номер, у которого не сходится Luhn, остаётся (это не карта).
      expect(AppLog.redact('4111 1111 1111 1112'), '4111 1111 1111 1112');
    });

    test('сырые кадры терминала в пакет не входят', () async {
      final j = jsonDecode(
        DiagnosticsService.encodeWithinCap(await DiagnosticsService.collect(notifier())),
      ) as Map<String, dynamic>;
      expect(j['terminal'], isNot(contains('recent')));
      expect(jsonEncode(j), isNot(contains('"recent"')));
    });
  });

  group('пакет версии 2', () {
    test('время сбора — UTC с Z, плюс пояс и смещение', () async {
      final at = DateTime(2026, 11, 4, 12, 30);
      final j = await DiagnosticsService.collect(notifier(), now: at);
      final collected = j['collected_at'] as String;
      expect(collected, endsWith('Z'));
      expect(DateTime.parse(collected), at.toUtc());
      expect(j['bundle_version'], DiagnosticsLimits.bundleVersion);
      expect(j['time']['utc_offset_min'], at.timeZoneOffset.inMinutes);
      expect(j['time']['tz'], isA<String>());
    });

    test('киоск, здоровье, датчики, терминал, температура планшета', () async {
      final j = await DiagnosticsService.collect(notifier());
      expect(j['kiosk']['lock_task_active'], isTrue);
      expect(j['kiosk']['device_owner'], isTrue);
      expect(j['kiosk']['system_bars'], isNull); // Syoung: сторожа нет
      expect(j['health'], containsPair('terminal', 'off'));
      expect(j['sensors_last_good'], contains('temperature_c'));
      expect(j['terminal']['type'], 'off');
      expect(j['device']['thermal_max_c'], 41.5);
      expect(j['app']['hardware_profile'], 'sy156-a510');
    });

    test('IXP101M1: состояние сторожа панелей в пакете', () async {
      HardwareProfile.current = HardwareProfile.ixp101m1;
      final j = await DiagnosticsService.collect(notifier());
      expect(j['kiosk']['system_bars'], containsPair('enabled', true));
    });

    test('окно журнала: старше N минут не берётся, но не меньше 300 строк', () async {
      final f = File('${tmp.path}/${AppLog.fileName}');
      final now = DateTime(2026, 11, 4, 12, 0);
      final lines = <String>[
        for (var i = 400; i >= 1; i--)
          '${now.subtract(Duration(minutes: i)).toIso8601String()} [t] old-$i',
        for (var i = 0; i < 10; i++)
          '${now.subtract(Duration(seconds: 30 - i)).toIso8601String()} [t] new-$i',
      ];
      await f.writeAsString('${lines.join('\n')}\n');
      final w15 = await AppLog.tailSince(const Duration(minutes: 15), now: now);
      expect(w15.first, contains('old-15'));
      expect(w15.last, contains('new-9'));
      final atLeast = await AppLog.tailSince(
        const Duration(minutes: 15),
        minLines: 300,
        now: now,
      );
      expect(atLeast.length, 300);
    });

    test('окно журнала из команды: 1…60, иначе 15', () {
      expect(DiagnosticsService.logWindowMinutes(30), 30);
      expect(DiagnosticsService.logWindowMinutes(90), 60);
      expect(DiagnosticsService.logWindowMinutes(0), 15);
      expect(DiagnosticsService.logWindowMinutes('x'), 15);
      expect(DiagnosticsService.logWindowMinutes(null), 15);
    });

    test('потолок 200 КБ: журнал обрезается со старого конца, новое остаётся', () async {
      final bundle = await DiagnosticsService.collect(notifier());
      bundle['log_tail'] = [
        for (var i = 0; i < 5000; i++) 'line-$i ${'x' * 100}',
      ];
      final text = DiagnosticsService.encodeWithinCap(bundle);
      expect(utf8.encode(text).length, lessThanOrEqualTo(DiagnosticsLimits.maxBundleBytes));
      final j = jsonDecode(text) as Map<String, dynamic>;
      final log = (j['log_tail'] as List).cast<String>();
      expect(log.last, startsWith('line-4999 '));
      expect(log.first, isNot(startsWith('line-0 ')));
      expect(j['truncated']['log_lines_dropped'], greaterThan(0));
    });

    test('маленький пакет не трогается', () async {
      final bundle = await DiagnosticsService.collect(notifier());
      final text = DiagnosticsService.encodeWithinCap(bundle);
      expect(jsonDecode(text), isNot(contains('truncated')));
    });
  });

  group('снимок экрана', () {
    var captured = 0;
    final uploaded = <String>[];

    setUp(() {
      captured = 0;
      uploaded.clear();
      ScreenshotService.capture = () async {
        captured++;
        return Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 0xff, 0xd9]);
      };
      ScreenshotService.upload = (id, jpeg) async {
        uploaded.add(id);
        return null;
      };
    });

    for (final s in [AppState.servicePinEntry, AppState.serviceMenu]) {
      test('запрет: ${s.name} — отказ, снимок не делается', () async {
        final n = notifier()..transition(s);
        final o = await RemoteCommands.handle(cmd('capture_screen'), n);
        expect(o.ok, isFalse);
        final j = jsonDecode(o.result) as Map<String, dynamic>;
        expect(j['refused'], s == AppState.servicePinEntry ? 'pin_screen' : 'service_menu');
        expect(j['message'], startsWith('снимок запрещён'));
        expect(captured, 0);
        expect(uploaded, isEmpty);
      });
    }

    test('запрет: открыт диалог ввода PIN', () async {
      final n = notifier()..transition(AppState.standby);
      ScreenshotService.secretInputOpened();
      final o = await ScreenshotService.captureAndSend(n);
      expect(jsonDecode(o.result)['refused'], 'pin_dialog');
      ScreenshotService.secretInputClosed();
      final o2 = await ScreenshotService.captureAndSend(n);
      expect(o2.ok, isTrue);
    });

    test('заставка: снимок сделан и отправлен', () async {
      final n = notifier()..transition(AppState.standby);
      final o = await RemoteCommands.handle(cmd('capture_screen'), n);
      expect(o.ok, isTrue);
      final j = jsonDecode(o.result) as Map<String, dynamic>;
      expect(j['shot_id'], startsWith('shot-'));
      expect(j['sent'], isTrue);
      expect(uploaded, [j['shot_id']]);
    });

    test('лимит частоты: второй снимок за минуту — rate_limited', () async {
      final n = notifier()..transition(AppState.standby);
      expect((await RemoteCommands.handle(cmd('capture_screen'), n)).ok, isTrue);
      final o = await RemoteCommands.handle(cmd('capture_screen'), n);
      expect(o.ok, isFalse);
      expect(o.result, 'rate_limited');
      expect(captured, 1);
    });

    test('ошибка отправки — код в ответе', () async {
      ScreenshotService.upload = (id, jpeg) async => 'rate_limited';
      final o = await ScreenshotService.captureAndSend(notifier()..transition(AppState.standby));
      expect(o.ok, isFalse);
      expect(jsonDecode(o.result)['error'], 'rate_limited');
    });

    test('масштаб: длинная сторона 800 px (портрет и альбом)', () {
      expect(ScreenshotService.pixelRatioFor(const Size(720, 1280)) * 1280, closeTo(800, 0.01));
      expect(ScreenshotService.pixelRatioFor(const Size(853.3, 533.3)) * 853.3, closeTo(800, 0.01));
    });
  });

  group('облачный слепок', () {
    test('kiosk_lock — из KioskPolicy, отдельно от kiosk_mode_enabled', () async {
      final k = (await SystemService.kioskPolicyState()).toReported();
      expect(k, {'device_owner': true, 'lock_enabled': true, 'lock_task_active': true});
      expect(notifier().config.reportedSnapshot()['kiosk_mode_enabled'], isFalse);
    });

    test('health: коды для светофора', () {
      final h = HealthSummary.build(notifier());
      expect(h.keys, containsAll(['bus_ok', 'thermo', 'meter', 'terminal']));
      expect(['off', 'ok', 'stale'], contains(h['thermo']));
      final none = HealthSummary.build(
        AppNotifier()..config = AppConfig(thermoInstalled: false, energyMeterInstalled: false),
      );
      expect(none['thermo'], 'off');
      expect(none['meter'], 'off');
    });
  });
}

class _CaptureTransport implements CloudTransport {
  @override
  Future<DiagUploadResult> uploadDiagnostics(
    String deviceId,
    String bundleId,
    int part,
    int parts,
    String data,
  ) async => const DiagUploadResult.ok();

  @override
  Future<bool> send(String deviceId, List<CloudEvent> events) async => true;

  @override
  Future<CloudPollResult> fetchCommands(String deviceId, {Map<String, dynamic>? config}) async =>
      CloudPollResult(commands: const []);

  @override
  Future<bool> ackCommand(String deviceId, String commandId, bool ok, String? result) async => true;
}
