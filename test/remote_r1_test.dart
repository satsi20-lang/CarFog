import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/out_of_service.dart';
import 'package:dry_fog_app/models/remote_limits.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/diagnostics_service.dart';
import 'package:dry_fog_app/services/remote_command_guard.dart';
import 'package:dry_fog_app/services/remote_commands.dart';
import 'package:dry_fog_app/services/system_service.dart';

// Удалённая диагностика, этап R1: постоянный журнал, защита команд,
// белый список, пакет диагностики без секретов.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const system = MethodChannel('com.carfog.dryfog/system');
  const modbus = MethodChannel('com.carfog.dryfog/modbus');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late Directory tmp;
  late DebugPrintCallback originalDebugPrint;
  late FlutterExceptionHandler? originalFlutterError;

  AppNotifier notifier() => AppNotifier()
    ..config = AppConfig(
      thermoInstalled: true,
      energyMeterInstalled: true,
      servicePin: '7351',
      cloudToken: 'tok-SECRET-123',
      cloudAnonKey: 'anon-SECRET-456',
      deviceId: 'TEST-001',
    );

  CloudCommand cmd(
    String action, {
    String? id,
    DateTime? createdAt,
    Map<String, dynamic>? params,
  }) => CloudCommand(
    id: id ?? '$action-${DateTime.now().microsecondsSinceEpoch}',
    action: action,
    params: params,
    createdAt: createdAt ?? DateTime.now(),
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('r1test');
    originalDebugPrint = debugPrint;
    originalFlutterError = FlutterError.onError;
    AppLog.resetForTest();
    DiagnosticsService.setDirForTest(tmp);
    DiagnosticsService.last = null;
    DiagnosticsService.resetRefusalForTest();
    CloudService.transport = LocalLogTransport();
    messenger.setMockMethodCallHandler(system, (c) async {
      if (c.method == 'getDeviceInfo') {
        return {
          'android_release': '13',
          'model': 'rk3568_t',
          'uptime_s': 1234,
          'disk_free_bytes': 1000,
          'mem_free_bytes': 2000,
          'net_type': 'wifi',
          'wifi_rssi_dbm': -60,
        };
      }
      if (c.method == 'getFilesDir') return tmp.path;
      if (c.method == 'writeOutOfService') return true;
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
    RemoteCommands.restartHook = () async {};
  });

  tearDown(() async {
    debugPrint = originalDebugPrint;
    FlutterError.onError = originalFlutterError;
    AppLog.resetForTest();
    DiagnosticsService.setDirForTest(null);
    CloudService.transport = LocalLogTransport();
    messenger.setMockMethodCallHandler(system, null);
    messenger.setMockMethodCallHandler(modbus, null);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // ------------------------------------------------------- журнал
  group('постоянный журнал', () {
    test('файл запуска начинается с отметки причины и версии', () async {
      await AppLog.init(dir: tmp, reason: 'crash', version: '9.9.9');
      final lines = await AppLog.tail(10);
      expect(lines.first, contains('=== START reason=crash version=9.9.9'));
      // и после "перезапуска" (новый init) журнал сохранил прошлое
      AppLog.log('t', 'до перезапуска');
      await AppLog.flush();
      AppLog.resetForTest();
      await AppLog.init(dir: tmp, reason: 'boot', version: '9.9.9');
      final all = await AppLog.tail(50);
      expect(all.any((l) => l.contains('до перезапуска')), isTrue);
      expect(all.where((l) => l.contains('=== START')).length, 2);
      expect(all.last, contains('reason=boot'));
    });

    test('debugPrint и ошибки Flutter попадают в журнал', () async {
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      AppLog.install();
      debugPrint('SyncService: проверка перехвата');
      FlutterError.onError!(FlutterErrorDetails(exception: StateError('бум')));
      final lines = await AppLog.tail(20);
      expect(lines.any((l) => l.contains('[SyncService] SyncService: проверка перехвата')), isTrue);
      expect(lines.any((l) => l.contains('[FlutterError]') && l.contains('бум')), isTrue);
    });

    test('секреты вырезаются: по шаблонам и по точным значениям', () async {
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      AppLog.setSecrets(['7351', 'tok-SECRET-123']);
      AppLog.log('t', 'params {pin: 7351, servicePin: "7351"} token=abc123def');
      AppLog.log('t', 'прямое значение tok-SECRET-123 в тексте');
      AppLog.log('t', 'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig_part_here');
      AppLog.log('t', 'Authorization: Bearer abcDEF.123-xyz');
      final text = (await AppLog.tail(20)).join('\n');
      expect(text, isNot(contains('7351')));
      expect(text, isNot(contains('tok-SECRET-123')));
      expect(text, isNot(contains('abc123def')));
      expect(text, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(text, isNot(contains('abcDEF.123-xyz')));
    });

    test('ротация: 2 файла, размер ограничен, свежее сохраняется', () async {
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      final big = 'x' * 1000;
      for (var i = 0; i < 30; i++) {
        for (var j = 0; j < 50; j++) {
          AppLog.log('t', '$i-$j $big');
        }
        await AppLog.flush();
      }
      final cur = File('${tmp.path}/${AppLog.fileName}');
      final prev = File('${tmp.path}/${AppLog.prevFileName}');
      expect(await prev.exists(), isTrue);
      expect(await cur.length(), lessThan(AppLogLimits.maxFileBytes + 80 * 1024));
      expect(await prev.length(), lessThan(AppLogLimits.maxFileBytes + 80 * 1024));
      final last = (await AppLog.tail(1)).single;
      expect(last, contains('29-49'));
      // третьего файла нет
      expect(tmp.listSync().whereType<File>().where((f) => f.path.contains('app_log')).length, 2);
    });

    test('log() не блокирует: 20 000 строк мгновенно, память ограничена', () async {
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      final sw = Stopwatch()..start();
      for (var i = 0; i < 20000; i++) {
        AppLog.log('t', 'строка $i');
      }
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1500));
      await AppLog.flush();
      final lines = await AppLog.tail(100000);
      expect(lines.length, lessThanOrEqualTo(AppLogLimits.maxPendingLines + 5));
    });
  });

  // ----------------------------------------------- защита команд
  group('срок, дубли, лимит частоты', () {
    test('просроченная команда не выполняется (expired)', () async {
      final c = cmd('ping', createdAt: DateTime.now().subtract(const Duration(minutes: 11)));
      expect(await CommandGuard.preCheck(c), 'expired');
      final fresh = cmd('ping', createdAt: DateTime.now().subtract(const Duration(minutes: 9)));
      expect(await CommandGuard.preCheck(fresh), isNull);
    });

    test('срок считается по часам СЕРВЕРА, а не планшета', () async {
      final server = DateTime(2026, 10, 3, 12, 0);
      // Планшет «отстал»: по его часам команда свежая, по серверным — 11 мин.
      final created = server.subtract(const Duration(minutes: 11));
      final c = CloudCommand(id: 'srv-1', action: 'ping', createdAt: created);
      expect(
        await CommandGuard.preCheck(c, now: created, serverTime: server),
        'expired',
      );
      // Планшет «убежал» вперёд на час: по его часам команда древняя, по
      // серверным — 1 минута, выполняется.
      final c2 = CloudCommand(
        id: 'srv-2',
        action: 'ping',
        createdAt: server.subtract(const Duration(minutes: 1)),
      );
      expect(
        await CommandGuard.preCheck(
          c2,
          now: server.add(const Duration(hours: 1)),
          serverTime: server,
        ),
        isNull,
      );
    });

    test('server_time разбирается из ответа device_poll', () {
      final r = CloudPollResult(
        commands: const [],
        serverTime: DateTime.tryParse('2026-10-03T12:00:00.123456+00:00'),
      );
      expect(r.serverTime, isNotNull);
      expect(r.serverTime!.toUtc().hour, 12);
    });

    test('без created_at безобидные команды идут, чувствительные — отказ', () async {
      expect(await CommandGuard.preCheck(CloudCommand(id: 'x1', action: 'ping')), isNull);
      expect(
        await CommandGuard.preCheck(CloudCommand(id: 'x2', action: 'collect_diagnostics')),
        isNull,
      );
      for (final a in ['set_pin', 'update_config', 'restart_app', 'factory_reset']) {
        expect(
          await CommandGuard.preCheck(CloudCommand(id: 'n-$a', action: a)),
          'no_created_at',
          reason: a,
        );
      }
    });

    test('set_pin / update_config / restart_app без created_at НЕ исполняются', () async {
      var restarts = 0;
      RemoteCommands.restartHook = () async => restarts++;
      final n = notifier()..transition(AppState.standby);
      final before = n.config.servicePin;
      final pin = await RemoteCommands.handle(
        CloudCommand(id: 'p1', action: 'set_pin', params: {'pin': '9999'}),
        n,
      );
      expect(pin.ok, isFalse);
      expect(pin.result, 'no_created_at');
      expect(n.config.servicePin, before); // PIN не изменился
      final cfg = await RemoteCommands.handle(
        CloudCommand(id: 'c1', action: 'update_config', params: {'treatmentPriceCents': 1}),
        n,
      );
      expect(cfg.result, 'no_created_at');
      expect(n.config.treatmentPriceCents, isNot(1));
      final r = await RemoteCommands.handle(CloudCommand(id: 'r9', action: 'restart_app'), n);
      expect(r.result, 'no_created_at');
      expect(r.afterAck, isNull);
      expect(restarts, 0);
    });

    test('повторная доставка той же команды — duplicate, даже после "перезапуска"', () async {
      final c = cmd('ping', id: 'same-id');
      expect(await CommandGuard.preCheck(c), isNull);
      expect(await CommandGuard.preCheck(c), 'duplicate');
      // память в SharedPreferences, а не в объекте: новый вызов видит id
      expect(await CommandGuard.preCheck(cmd('ping', id: 'same-id')), 'duplicate');
    });

    test('лимит частоты: не чаще раза в минуту и 3 в час', () async {
      final t0 = DateTime(2026, 10, 3, 12);
      expect(await CommandGuard.allowRate('restart_app', now: t0), isTrue);
      expect(await CommandGuard.allowRate('restart_app', now: t0.add(const Duration(seconds: 30))), isFalse);
      expect(await CommandGuard.allowRate('restart_app', now: t0.add(const Duration(minutes: 2))), isTrue);
      expect(await CommandGuard.allowRate('restart_app', now: t0.add(const Duration(minutes: 4))), isTrue);
      expect(await CommandGuard.allowRate('restart_app', now: t0.add(const Duration(minutes: 6))), isFalse); // 4-й за час
      expect(await CommandGuard.allowRate('restart_app', now: t0.add(const Duration(minutes: 62))), isTrue);
      // у collect_diagnostics свой счётчик
      expect(await CommandGuard.allowRate('collect_diagnostics', now: t0), isTrue);
    });

    test('история: последние 10, новые первыми', () async {
      for (var i = 0; i < 12; i++) {
        await CommandGuard.record(action: 'a$i', ok: i.isEven, result: 'r$i');
      }
      final h = await CommandGuard.history();
      expect(h.length, RemoteCommandLimits.historyShown);
      expect(h.first['action'], 'a11');
      expect(h.last['action'], 'a2');
    });
  });

  // ------------------------------------------ белый список команд
  group('команды', () {
    test('неизвестная команда — отказ без исключения', () async {
      final o = await RemoteCommands.handle(cmd('format_disk'), notifier());
      expect(o.ok, isFalse);
      expect(o.result, contains('неизвестная команда'));
    });

    test('снятие вывода из обслуживания — отказ, состояние не изменилось', () async {
      final n = notifier();
      n.enterOutOfService(
        OutOfServiceState(code: OutOfServiceCode.heaterNoPower, since: DateTime.now()),
      );
      for (final a in ['clear_out_of_service', 'reset_out_of_service', 'resume_service']) {
        final o = await RemoteCommands.handle(cmd(a), n);
        expect(o.ok, isFalse, reason: a);
      }
      expect(n.isOutOfService, isTrue);
      expect(n.state, AppState.outOfService);
    });

    test('ping: версия, состояние автомата, вывод из обслуживания, шина', () async {
      final n = notifier()..setBusHealthy(true);
      final o = await RemoteCommands.handle(cmd('ping'), n);
      expect(o.ok, isTrue);
      final j = jsonDecode(o.result) as Map<String, dynamic>;
      expect(j['version'], CloudService.appVersion);
      expect(j['state'], 'selectLanguage');
      expect(j['out_of_service'], isNull);
      expect(j['bus_healthy'], isTrue);
    });

    test('restart_app в покое — выполняется только ПОСЛЕ ack', () async {
      var restarts = 0;
      RemoteCommands.restartHook = () async => restarts++;
      final n = notifier()..transition(AppState.standby);
      final o = await RemoteCommands.handle(cmd('restart_app'), n);
      expect(o.ok, isTrue);
      expect(restarts, 0); // пока ack не отправлен — не перезапускаем
      await o.afterAck!();
      expect(restarts, 1);
    });

    test('restart_app в оплате/прогреве/обработке/завершении — busy, цикл не тронут', () async {
      var restarts = 0;
      RemoteCommands.restartHook = () async => restarts++;
      for (final s in [
        AppState.payment,
        AppState.preparing,
        AppState.compressorStartup,
        AppState.treating,
        AppState.shutdown,
        AppState.finished,
        AppState.serviceMenu,
      ]) {
        final n = notifier()..transition(s);
        final o = await RemoteCommands.handle(cmd('restart_app'), n);
        expect(o.ok, isFalse, reason: s.name);
        expect(o.result, startsWith('busy'), reason: s.name);
        expect(o.afterAck, isNull);
        expect(n.state, s, reason: 'состояние не изменилось');
      }
      expect(restarts, 0);
    });

    test('restart_app: второй раз сразу — rate_limited; дубль не исполняется', () async {
      var restarts = 0;
      RemoteCommands.restartHook = () async => restarts++;
      final n = notifier()..transition(AppState.standby);
      final first = await RemoteCommands.handle(cmd('restart_app', id: 'r1'), n);
      await first.afterAck!();
      final again = await RemoteCommands.handle(cmd('restart_app', id: 'r2'), n);
      expect(again.result, 'rate_limited');
      final dup = await RemoteCommands.handle(cmd('restart_app', id: 'r1'), n);
      expect(dup.result, 'duplicate');
      expect(restarts, 1);
    });

    test('просроченный restart_app не исполняется', () async {
      final n = notifier()..transition(AppState.standby);
      final o = await RemoteCommands.handle(
        cmd('restart_app', createdAt: DateTime.now().subtract(const Duration(hours: 1))),
        n,
      );
      expect(o.result, 'expired');
      expect(o.afterAck, isNull);
    });
  });

  // ------------------------------------------------ пакет диагностики
  group('пакет диагностики', () {
    test('секретов нет: ни PIN, ни токена, ни ключа', () async {
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      final n = notifier();
      AppLog.setSecrets([n.config.servicePin, n.config.cloudToken, n.config.cloudAnonKey]);
      AppLog.log('t', 'params {pin: 7351} token=tok-SECRET-123 key anon-SECRET-456');
      final bundle = await DiagnosticsService.collect(n);
      final text = DiagnosticsService.encode(bundle);
      expect(text, isNot(contains('tok-SECRET-123')));
      expect(text, isNot(contains('anon-SECRET-456')));
      expect(text, isNot(contains('pin: 7351')));
      expect(text, isNot(contains('"servicePin"')));
      expect(text, isNot(contains('"cloudToken"')));
      final j = jsonDecode(text) as Map<String, dynamic>;
      expect(j['app']['version'], CloudService.appVersion);
      expect(j['device']['android_release'], '13');
      expect(j['state']['app_state'], isNotNull);
      expect(j['reads']['temperature_c'], 25.0);
      expect(j['network']['type'], 'wifi');
      expect(j['config']['thermo_installed'], isTrue);
    });

    test('в занятом состоянии шина не читается', () async {
      // Считаем только обращения к ШИНЕ (флаги отладочных режимов — это
      // нативные переменные, шину не трогают).
      var busCalls = 0;
      const busMethods = {'readTemperature', 'readEnergy', 'readCoils', 'readAllInputs', 'readCoin'};
      messenger.setMockMethodCallHandler(modbus, (c) async {
        if (busMethods.contains(c.method)) busCalls++;
        return null;
      });
      final n = notifier()..transition(AppState.treating);
      final bundle = await DiagnosticsService.collect(n);
      expect(bundle['reads']['skipped'], startsWith('busy_state'));
      expect(busCalls, 0);
    });

    test('collect_diagnostics: пакет уходит частями, в ack — идентификатор', () async {
      final parts = <String>[];
      final capture = _CaptureTransport(parts);
      CloudService.transport = capture;
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      final n = notifier()..transition(AppState.standby);
      final o = await RemoteCommands.handle(cmd('collect_diagnostics'), n);
      expect(o.ok, isTrue);
      final j = jsonDecode(o.result) as Map<String, dynamic>;
      expect(j['bundle_id'], startsWith('diag-'));
      expect(capture.bundleIds.toSet(), {j['bundle_id']});
      expect(jsonDecode(parts.join()), isA<Map>());
      expect(DiagnosticsService.last?.sent, isTrue);
    });

    test('нет связи: пакет НЕ теряется, помечен неотправленным, уходит позже', () async {
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      final n = notifier()..transition(AppState.standby);
      // LocalLogTransport (облако выключено) отдаёт false
      final st = await DiagnosticsService.collectAndSend(n, trigger: 'test');
      expect(st.sent, isFalse);
      expect(await DiagnosticsService.hasPending(), isTrue);
      final parts = <String>[];
      CloudService.transport = _CaptureTransport(parts);
      await DiagnosticsService.retryPending();
      expect(DiagnosticsService.last?.sent, isTrue);
      expect(await DiagnosticsService.hasPending(), isFalse);
      expect(parts, isNotEmpty);
    });

    test('разбиение на части и склейка без потерь', () {
      final text = 'я' * (DiagnosticsLimits.chunkChars * 2 + 17);
      final parts = DiagnosticsService.split(text);
      expect(parts.length, 3);
      expect(parts.join(), text);
    });
  });

  // -------------------------------------------- квота и отказы сервера
  group('квота и отказы сервера', () {
    test('quota: пакет не отправлен, причина quota, без повторов и без файла', () async {
      final t = _FailTransport('quota');
      CloudService.transport = t;
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      final n = notifier()..transition(AppState.standby);
      final o = await RemoteCommands.handle(cmd('collect_diagnostics'), n);
      expect(o.ok, isFalse);
      expect((jsonDecode(o.result) as Map)['error'], 'quota');
      expect(DiagnosticsService.last?.sent, isFalse);
      expect(DiagnosticsService.last?.error, 'quota');
      expect(await DiagnosticsService.hasPending(), isFalse); // повторов не будет
      final calls = t.calls;
      // следующие тики не долбят сервер
      await DiagnosticsService.retryPending();
      await DiagnosticsService.retryPending();
      expect(t.calls, calls);
    });

    test('quota при уже отложенном пакете: повторная отправка ставится на паузу', () async {
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      final n = notifier()..transition(AppState.standby);
      // 1) связи нет — пакет откладывается
      CloudService.transport = _FailTransport('network');
      await DiagnosticsService.collectAndSend(n);
      expect(await DiagnosticsService.hasPending(), isTrue);
      // 2) повтор упирается в квоту — один запрос и пауза
      final t = _FailTransport('quota');
      CloudService.transport = t;
      await DiagnosticsService.retryPending();
      await DiagnosticsService.retryPending();
      await DiagnosticsService.retryPending();
      expect(t.calls, 1);
    });

    test('ответы quota/auth/ошибка не оставляют токен и ключ в журнале и истории', () async {
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      AppLog.install();
      final n = notifier()..transition(AppState.standby);
      AppLog.setSecrets([n.config.servicePin, n.config.cloudToken, n.config.cloudAnonKey]);
      final responses = <http.Response>[
        http.Response('{"ok":false,"error":"quota"}', 200),
        http.Response('{"ok":false,"error":"auth"}', 200),
        // сервер "эхом" возвращает секреты в поле error
        http.Response('{"ok":false,"error":"bad tok-SECRET-123 anon-SECRET-456"}', 200),
        http.Response('Bearer anon-SECRET-456 token tok-SECRET-123 denied', 401),
      ];
      var i = 0;
      await http.runWithClient(() async {
        CloudService.transport = SupabaseTransport(
          baseUrl: 'https://example.invalid',
          anonKey: n.config.cloudAnonKey,
          deviceToken: n.config.cloudToken,
        );
        for (var k = 0; k < responses.length; k++) {
          DiagnosticsService.resetRefusalForTest(); // как после часа паузы
          // каждая команда "через 2 часа": и срок, и лимит частоты проходят
          final at = DateTime.now().add(Duration(hours: 2 * (k + 1)));
          final o = await RemoteCommands.handle(
            cmd('collect_diagnostics', id: 'q$k', createdAt: at),
            n,
            now: at,
          );
          await CommandGuard.record(action: 'collect_diagnostics', ok: o.ok, result: o.result);
        }
      }, () => MockClient((request) async => responses[i++ % responses.length]));
      final log = (await AppLog.tail(500)).join('\n');
      final history = jsonEncode(await CommandGuard.history());
      final status = DiagnosticsService.last?.error ?? '';
      for (final text in [log, history, status]) {
        expect(text, isNot(contains('tok-SECRET-123')));
        expect(text, isNot(contains('anon-SECRET-456')));
      }
      // причина отказа сервера записана только коротким кодом
      expect(history, contains('quota'));
      expect(history, contains('auth'));
      expect(history, contains('rejected'));
    });
  });

  // ------------------------- restart_app: повторная проверка покоя
  group('restart_app: проверка покоя перед перезапуском', () {
    test('состояние стало неспокойным после приёма — перезапуск отменён, причина в истории', () async {
      var restarts = 0;
      RemoteCommands.restartHook = () async => restarts++;
      final n = notifier()..transition(AppState.standby);
      final o = await RemoteCommands.handle(cmd('restart_app'), n);
      expect(o.ok, isTrue);
      n.transition(AppState.selectFlavor); // клиент начал выбор аромата
      await o.afterAck!();
      expect(restarts, 0);
      final h = await CommandGuard.history();
      expect(h.first['action'], 'restart_app');
      expect(h.first['ok'], isFalse);
      expect(h.first['result'], contains('restart_cancelled:state_became_busy:selectFlavor'));
    });

    for (final s in [AppState.payment, AppState.preparing, AppState.treating]) {
      test('(${s.name}) после приёма — отмена, перезапуска нет', () async {
        var restarts = 0;
        RemoteCommands.restartHook = () async => restarts++;
        final n = notifier()..transition(AppState.standby);
        final o = await RemoteCommands.handle(cmd('restart_app', id: 'rs-${s.name}'), n);
        n.transition(s);
        await o.afterAck!();
        expect(restarts, 0);
      });
    }

    test('вопрос нативного таймера isIdleForRestart: true в покое, false после начала цикла', () async {
      SystemService.init();
      final n = notifier()..transition(AppState.standby);
      await RemoteCommands.handle(cmd('restart_app'), n);
      expect(await SystemService.idleForRestartCheck!(), isTrue);
      n.transition(AppState.payment);
      expect(await SystemService.idleForRestartCheck!(), isFalse);
      final h = await CommandGuard.history();
      expect(h.first['result'], contains('restart_cancelled'));
    });
  });

  // ------------------------------------------- update_config: пределы
  group('update_config: пределы значений', () {
    Future<CommandOutcome> upd(AppNotifier n, Map<String, dynamic> p, [String? id]) =>
        RemoteCommands.handle(cmd('update_config', id: id, params: p), n);

    test('значения внутри пределов (включая границы) применяются', () async {
      final n = notifier();
      final o = await upd(n, {
        'treatmentDurationS': 120,
        'treatmentPriceCents': 50,
        'compressorPurgeS': 1,
        'pumpAfterHeaterS': 30,
      });
      expect(o.ok, isTrue);
      expect(n.config.treatmentDurationS, 120);
      expect(n.config.treatmentPriceCents, 50);
      expect(n.config.compressorPurgeS, 1);
      expect(n.config.pumpAfterHeaterS, 30);
      final o2 = await upd(n, {'treatmentDurationS': 10, 'treatmentPriceCents': 2000});
      expect(o2.ok, isTrue);
      expect(n.config.treatmentPriceCents, 2000);
    });

    const cases = <(String, int)>[
      ('treatmentDurationS', 9),
      ('treatmentDurationS', 121),
      ('treatmentPriceCents', 49),
      ('treatmentPriceCents', 2001),
      ('compressorPurgeS', 0),
      ('compressorPurgeS', 31),
      ('pumpAfterHeaterS', 0),
      ('pumpAfterHeaterS', 31),
    ];
    for (final (field, value) in cases) {
      test('$field = $value вне предела: отказ out_of_range:$field, настройки не изменены', () async {
        final n = notifier();
        final before = n.config.treatmentDurationS;
        final o = await upd(n, {field: value}, 'b-$field-$value');
        expect(o.ok, isFalse);
        expect(o.result, 'out_of_range:$field');
        expect(n.config.treatmentDurationS, before);
        expect(n.config.treatmentPriceCents, 200);
      });
    }

    test('отклоняется ЦЕЛИКОМ: годное поле рядом с негодным не применяется', () async {
      final n = notifier();
      final o = await upd(n, {'treatmentPriceCents': 300, 'treatmentDurationS': 500});
      expect(o.result, 'out_of_range:treatmentDurationS');
      expect(n.config.treatmentPriceCents, 200);
    });

    test('не число и плохой PIN', () async {
      final n = notifier();
      expect((await upd(n, {'treatmentDurationS': '40'}, 'bt1')).result, 'bad_type:treatmentDurationS');
      expect((await upd(n, {'treatmentDurationS': 40.5}, 'bt2')).result, 'bad_type:treatmentDurationS');
      expect((await upd(n, {'servicePin': '12'}, 'bt3')).result, 'invalid:servicePin');
      expect(n.config.servicePin, '7351');
    });

    test('пределы — один источник с локальным вводом в сервисном меню', () {
      expect(ConfigLimits.range('treatmentDurationS'), (min: 10, max: 120));
      expect(ConfigLimits.range('treatmentPriceCents'), (min: 50, max: 2000));
      expect(ConfigLimits.range('compressorPurgeS')!.min, 1);
      expect(ConfigLimits.range('pumpAfterHeaterS')!.max, 30);
    });
  });
}

class _FailTransport implements CloudTransport {
  final String error;
  int calls = 0;
  _FailTransport(this.error);

  @override
  Future<DiagUploadResult> uploadDiagnostics(String deviceId, String bundleId, int part, int partsTotal, String data) async {
    calls++;
    return DiagUploadResult.fail(error);
  }

  @override
  Future<bool> send(String deviceId, List<CloudEvent> events) async => true;

  @override
  Future<CloudPollResult> fetchCommands(String deviceId, {Map<String, dynamic>? config}) async =>
      CloudPollResult(commands: const []);

  @override
  Future<bool> ackCommand(String deviceId, String commandId, bool ok, String? result) async => true;
}

class _CaptureTransport implements CloudTransport {
  final List<String> parts;
  final List<String> bundleIds = [];
  _CaptureTransport(this.parts);

  @override
  Future<DiagUploadResult> uploadDiagnostics(String deviceId, String bundleId, int part, int partsTotal, String data) async {
    bundleIds.add(bundleId);
    parts.add(data);
    return const DiagUploadResult.ok();
  }

  @override
  Future<bool> send(String deviceId, List<CloudEvent> events) async => true;

  @override
  Future<CloudPollResult> fetchCommands(String deviceId, {Map<String, dynamic>? config}) async =>
      CloudPollResult(commands: const []);

  @override
  Future<bool> ackCommand(String deviceId, String commandId, bool ok, String? result) async => true;
}
