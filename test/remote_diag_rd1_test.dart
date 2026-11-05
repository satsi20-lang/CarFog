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

  // Правки после живой проверки 05.11 (ветка diag-fixes-1.12.1).
  group('окно журнала (правка 1.12.1)', () {
    // Метка журнала: местное время без пояса, как пишет AppLog.log.
    String stamp(DateTime utc, Duration off) {
      final s = utc.add(off).toIso8601String();
      return s.endsWith('Z') ? s.substring(0, s.length - 1) : s;
    }

    const plus2 = Duration(hours: 2);
    const minus5 = Duration(hours: -5);
    // Как пакет diag-1793898735439: собран 2026-11-05 17:12 UTC.
    final now = DateTime.utc(2026, 11, 5, 17, 12, 15);

    List<String> liveLike(Duration off) => [
          for (var i = 0; i < 251; i++)
            '${stamp(DateTime.utc(2026, 11, 3, 18, 34).add(Duration(seconds: i)), off)} [t] d3-$i',
          for (var i = 0; i < 45; i++)
            '${stamp(DateTime.utc(2026, 11, 4, 18, 58).add(Duration(seconds: i)), off)} [t] d4-$i',
          for (var i = 0; i < 4; i++)
            '${stamp(now.subtract(Duration(minutes: 10 - i)), off)} [t] d5-$i',
        ];

    test('15 минут отсекают строки за прошлые дни (случай живой проверки)', () {
      final w = AppLog.windowLines(liveLike(plus2), const Duration(minutes: 15),
          now: now, maxLines: 300, utcOffset: plus2);
      expect(w, hasLength(4));
      expect(w.every((l) => l.contains('d5-')), isTrue);
    });

    test('60 минут: берётся больше, но не вчерашнее', () {
      final lines = [
        '${stamp(now.subtract(const Duration(hours: 25)), plus2)} [t] yesterday',
        for (var m = 90; m >= 0; m -= 10)
          '${stamp(now.subtract(Duration(minutes: m)), plus2)} [t] m$m',
      ];
      final w60 = AppLog.windowLines(lines, const Duration(minutes: 60),
          now: now, utcOffset: plus2);
      expect(w60.first, contains('m60'));
      expect(w60, hasLength(7)); // 60, 50, …, 0
      final w15 = AppLog.windowLines(lines, const Duration(minutes: 15),
          now: now, utcOffset: plus2);
      expect(w15.map((l) => l.split(' ').last), ['m10', 'm0']);
    });

    test('граница: ровно N минут назад входит, на 1 мс старше — нет', () {
      final edge = now.subtract(const Duration(minutes: 15));
      final lines = [
        '${stamp(edge.subtract(const Duration(milliseconds: 1)), plus2)} [t] out',
        '${stamp(edge, plus2)} [t] in',
      ];
      final w = AppLog.windowLines(lines, const Duration(minutes: 15),
          now: now, utcOffset: plus2);
      expect(w, hasLength(1));
      expect(w.single, endsWith('in'));
    });

    test('местная метка при поясе +02:00 и -05:00', () {
      // Пример из журнала: 19:12:14 при +02:00 — это 17:12:14 UTC.
      final plus = ['2026-11-05T19:12:14.947136 [t] fresh'];
      expect(AppLog.lineTime(plus.single, utcOffset: plus2),
          DateTime.utc(2026, 11, 5, 17, 12, 14, 947, 136));
      expect(AppLog.windowLines(plus, const Duration(minutes: 15),
          now: now, utcOffset: plus2), hasLength(1));
      // Та же метка, но журнал писался при -05:00 — это 00:12 следующего
      // дня UTC (в будущем): входит. 11:50 при -05:00 = 16:50 UTC — нет.
      final minus = [
        '2026-11-05T11:50:00.000 [t] old',
        '2026-11-05T12:05:00.000 [t] fresh',
      ];
      final w = AppLog.windowLines(minus, const Duration(minutes: 15),
          now: now, utcOffset: minus5);
      expect(w, ['2026-11-05T12:05:00.000 [t] fresh']);
      // Метка с Z берётся как UTC независимо от пояса.
      expect(AppLog.lineTime('2026-11-05T17:00:00Z [t] x', utcOffset: minus5),
          DateTime.utc(2026, 11, 5, 17));
    });

    test('потолок 300 строк, а не минимум', () {
      final many = [
        for (var i = 600; i >= 1; i--)
          '${stamp(now.subtract(Duration(seconds: i)), plus2)} [t] s$i',
      ];
      final w = AppLog.windowLines(many, const Duration(minutes: 15),
          now: now, maxLines: 300, utcOffset: plus2);
      expect(w, hasLength(300));
      expect(w.last, endsWith('s1'));
    });

    test('файл журнала: tailSince берёт только окно', () async {
      final f = File('${tmp.path}/${AppLog.fileName}');
      await f.writeAsString('${liveLike(plus2).join('\n')}\n');
      final w = await AppLog.tailSince(const Duration(minutes: 15),
          maxLines: 300, now: now, utcOffset: plus2);
      expect(w, hasLength(4));
    });

    test('пакет: log_window_minutes, log_lines; пустое окно помечено', () async {
      final j = await DiagnosticsService.collect(notifier(), logMinutes: 30);
      expect(j['log_window_minutes'], 30);
      expect(j['log_window_min'], 30);
      expect(j['log_lines'], (j['log_tail'] as List).length);
      expect(j['log_lines'], greaterThan(0));
      expect(j['log_window_empty'], isFalse);

      // Через сутки все строки (включая отметку запуска) старше окна.
      final later = await DiagnosticsService.collect(notifier(),
          now: DateTime.now().add(const Duration(days: 1)));
      expect(later['log_tail'], isEmpty);
      expect(later['log_lines'], 0);
      expect(later['log_window_empty'], isTrue);
      expect(later['log_window_minutes'], 15);
    });

    test('потолок 200 КБ обновляет log_lines', () async {
      final bundle = await DiagnosticsService.collect(notifier());
      bundle['log_tail'] = [for (var i = 0; i < 5000; i++) 'line-$i ${'x' * 100}'];
      final j = jsonDecode(DiagnosticsService.encodeWithinCap(bundle))
          as Map<String, dynamic>;
      expect(j['log_lines'], (j['log_tail'] as List).length);
      expect(j['log_lines'], lessThan(5000));
    });
  });

  group('номер карты: без ложных срабатываний (правка 1.12.1)', () {
    // Дописать контрольную цифру Luhn, чтобы ложные примеры были
    // «настоящими по Luhn» — иначе тест ничего бы не доказывал.
    String withLuhn(String body) {
      for (var d = 0; d <= 9; d++) {
        if (AppLog.luhnOk('$body$d')) return '$body$d';
      }
      throw StateError('no digit');
    }

    final l13 = withLuhn('412345678901'); // 13 цифр
    final l16 = withLuhn('454545454545454'); // 16 цифр
    final l16b = withLuhn('523456789012345');

    test('контроль: примеры действительно проходят Luhn', () {
      for (final d in [l13, l16, l16b]) {
        expect(AppLog.luhnOk(d), isTrue, reason: d);
      }
    });

    test('дробные числа, метки времени, UUID, session=/id= — не маскируются', () {
      final keep = [
        'baseline_power_w: 16.$l13',
        'energy=16.$l16 kWh',
        'x=$l16.5',
        'v 0,$l16b',
        '$l16,25 €',
        'session=1793732334613',
        'diag-1793898735439',
        'at_us=1793732334613123',
        'session=$l16',
        'id=$l16b',
        'device_id: $l16',
        '{"session_id":"$l16"}',
        'trace $l16b-a716',
        '550e8400-e29b-41d4-a716-446655440000',
        '42424242-4242-4242-4242-424242424242',
        'f47ac10b-58cc-4372-a567-$l13',
        'run_$l16',
        'm$l16b',
      ];
      for (final line in keep) {
        expect(AppLog.redact(line), line, reason: line);
      }
    });

    test('настоящие тестовые номера Visa/MC/Amex — маскируются', () {
      final cards = [
        '4111111111111111',
        '4242 4242 4242 4242',
        '4012888888881881',
        '5555555555554444',
        '5105-1051-0510-5100',
        '2223003122003222',
        '378282246310005',
        '3782 822463 10005',
        '371449635398431',
        '6011111111111117',
      ];
      for (final c in cards) {
        for (final line in [
          c,
          'card $c.',
          'card=$c',
          'pan: $c',
          '{"pan":"$c"}',
          '"$c"',
        ]) {
          final out = AppLog.redact(line);
          expect(out, isNot(contains(c)), reason: line);
          expect(out, contains('***'), reason: line);
        }
      }
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
