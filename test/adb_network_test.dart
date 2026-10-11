import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/adb_exposure.dart';
import 'package:dry_fog_app/services/adb_network_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/privileged_installer.dart';
import 'package:dry_fog_app/services/update_service.dart';

// Сетевой adb: разбор состояния (свойства + сокеты), команды на поддельном
// shell, окно 30 минут, закрытие при старте и вне окна, беспроводная отладка.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String probe({
    String internet = '',
    String service = '',
    String persist = '',
    String adbd = 'running',
    String wifi = '0',
    String tls = '',
    String secure = '',
    List<String> listen = const [],
    bool sockets = true,
  }) =>
      [
        'internet_adb=$internet',
        'service_port=$service',
        'persist_port=$persist',
        'adbd=$adbd',
        'adb_wifi=$wifi',
        'tls_port=$tls',
        'secure=$secure',
        if (sockets) '--listen--',
        ...listen,
      ].join('\n');

  // Строка /proc/net/tcp6 в состоянии LISTEN на порту (hex).
  String listen6(int port) =>
      '   0: 00000000000000000000000000000000:${port.toRadixString(16).toUpperCase()} '
      '00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 '
      '00000000  2000        0 22757 1 0000000000000000 99 0 0 10 0';

  group('разбор состояния', () {
    test('CARFOG-100 11.10.2026 (реальный вывод): 5555 слушает, источник internet_adb', () {
      const out = '''internet_adb=1
service_port=5555
persist_port=5555
adbd=running
adb_wifi=0
tls_port=
secure=
--listen--
   0: 00000000000000000000000000000000:15B3 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  2000        0 22757 1 0000000000000000 99 0 0 10 0
''';
      final s = AdbExposure.parse(out)!;
      expect(s.tcpListening, isTrue);
      expect(s.configuredPort, 5555);
      expect(s.source, 'internet_adb');
      expect(s.authRequired, isFalse);
      expect(s.wifiDebug, isFalse);
      expect(s.mismatch, isFalse);
    });

    test('прежняя ошибка: internet_adb=1 при пустом persist-порте — открыт', () {
      final s = AdbExposure.parse(
        probe(internet: '1', service: '5555', listen: [listen6(5555)]),
      )!;
      expect(s.tcpListening, isTrue);
      expect(s.source, 'internet_adb');
      expect(s.persistPort, isFalse);
    });

    test('всё выключено — закрыт', () {
      final s = AdbExposure.parse(probe(internet: '0', service: '0'))!;
      expect(s.tcpListening, isFalse);
      expect(s.configuredPort, 0);
      expect(s.source, 'none');
      expect(s.anyOpen, isFalse);
    });

    test('свойства «закрыто», а сокет слушает (adbd не перезапущен) — открыт, расхождение', () {
      final s = AdbExposure.parse(probe(service: '0', listen: [listen6(5555)]))!;
      expect(s.tcpListening, isTrue);
      expect(s.mismatch, isTrue);
    });

    test('свойства «открыто», а сокета нет — закрыт, расхождение', () {
      final s = AdbExposure.parse(probe(service: '5555'))!;
      expect(s.tcpListening, isFalse);
      expect(s.configuredPort, 5555);
      expect(s.mismatch, isTrue);
    });

    test('только persist.adb.tcp.port', () {
      final s = AdbExposure.parse(probe(persist: '5555', listen: [listen6(5555)]))!;
      expect(s.source, 'persist_port');
      expect(s.tcpListening, isTrue);
    });

    test('adbd остановлен — порт по свойствам не считается', () {
      final s = AdbExposure.parse(probe(service: '5555', adbd: 'stopped'))!;
      expect(s.configuredPort, 0);
      expect(s.tcpListening, isFalse);
    });

    test('сокеты не прочитаны — вывод по свойствам', () {
      final s = AdbExposure.parse(probe(service: '5555', sockets: false))!;
      expect(s.socketsKnown, isFalse);
      expect(s.tcpListening, isTrue);
      expect(s.mismatch, isFalse);
    });

    test('беспроводная отладка: TLS-порт не считается сетевым adb без TLS', () {
      final s = AdbExposure.parse(
        probe(wifi: '1', tls: '37123', listen: [listen6(37123)]),
      )!;
      expect(s.wifiDebug, isTrue);
      expect(s.tlsPort, 37123);
      expect(s.tlsListening, isTrue);
      expect(s.tcpListening, isFalse);
      expect(s.anyOpen, isTrue);
    });

    test('IPv4-сокет и другие слушающие порты', () {
      final s = AdbExposure.parse(probe(listen: [
        '   1: 00000000:15B3 00000000:0000 0A 00000000:00000000 00:00000000 00000000  2000 0 1 1',
        '   2: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000 10000 0 2 1',
        '   3: 0100007F:15B3 0100007F:9C40 01 00000000:00000000 00:00000000 00000000  2000 0 3 1',
      ]))!;
      expect(s.tcpListening, isTrue);
    });

    test('установленное соединение на 5555 (не LISTEN) — не открыт', () {
      final s = AdbExposure.parse(probe(listen: [
        '   3: 0100007F:15B3 0100007F:9C40 01 00000000:00000000 00:00000000 00000000  2000 0 3 1',
      ]))!;
      expect(s.tcpListening, isFalse);
    });

    test('ro.adb.secure=1 — ключ требуется', () {
      expect(AdbExposure.parse(probe(secure: '1'))!.authRequired, isTrue);
    });

    test('мусор — null', () {
      expect(AdbExposure.parse(''), isNull);
      expect(AdbExposure.parse('su: permission denied'), isNull);
    });

    test('в слепок — без лишнего, с признаком расхождения', () {
      final j = AdbExposure.parse(probe(internet: '1', service: '5555', listen: [listen6(5555)]))!.toJson();
      expect(j, {
        'tcp_listening': true,
        'port': 5555,
        'source': 'internet_adb',
        'wifi_debug': false,
        'tls_port': null,
        'tls_listening': false,
        'auth_required': false,
        'sockets_known': true,
        'mismatch': false,
      });
    });
  });

  // Команды на хосте: поддельные getprop/setprop/settings хранят свойства в
  // файлах; setprop persist.internet_adb_enable 0 через 0,3 с, как правило
  // init, ставит service.adb.tcp.port=0 — проверка гонки.
  group('команды (поддельный shell)', () {
    late Directory tmp;
    late Directory bin;
    late Directory props;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('adbcmd');
      bin = Directory('${tmp.path}/bin')..createSync();
      props = Directory('${tmp.path}/props')..createSync();
      void fake(String name, String body) {
        final f = File('${bin.path}/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
        Process.runSync('chmod', ['+x', f.path]);
      }

      fake('getprop', r'cat "$PROPS/$1" 2>/dev/null; echo');
      fake('setprop', r'''
printf '%s' "$2" > "$PROPS/$1"
echo "$1=$2" >> "$PROPS/_log"
if [ "$1" = persist.internet_adb_enable ] && [ "$2" = 0 ]; then
  ( sleep 0.3; printf 0 > "$PROPS/service.adb.tcp.port"; echo "init=restart" >> "$PROPS/_log" ) &
fi''');
      fake('settings', r'''
if [ "$1" = put ]; then printf '%s' "$3=$4" >> "$PROPS/_log"; echo >> "$PROPS/_log"; printf '%s' "$4" > "$PROPS/settings.$3"; else cat "$PROPS/settings.$3" 2>/dev/null || echo null; fi''');
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    void set(String k, String v) => File('${props.path}/$k').writeAsStringSync(v);
    String get(String k) {
      final f = File('${props.path}/$k');
      return f.existsSync() ? f.readAsStringSync() : '';
    }

    Future<ProcessResult> run(String cmd) => Process.run('sh', ['-c', cmd], environment: {
          'PATH': '${bin.path}:/usr/bin:/bin',
          'PROPS': props.path,
        });

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 500));

    test('открыть с internet_adb=1: ждёт правило init, итог — только service-порт', () async {
      set('persist.internet_adb_enable', '1');
      set('persist.adb.tcp.port', '5555');
      set('service.adb.tcp.port', '5555');
      final r = await run(adbOpenCommand);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      await settle();
      expect(get('persist.internet_adb_enable'), '0');
      expect(get('persist.adb.tcp.port'), '');
      expect(get('service.adb.tcp.port'), '5555');
      expect(get('settings.adb_enabled'), '1');
      final log = get('_log').trim().split('\n');
      // Порт 5555 записан ПОСЛЕ того, как сработало правило init, и только потом рестарт.
      expect(log.indexOf('service.adb.tcp.port=5555'), greaterThan(log.indexOf('init=restart')));
      expect(log.last, 'ctl.restart=adbd');
    });

    test('открыть с чистого планшета: internet_adb не трогает', () async {
      final r = await run(adbOpenCommand);
      expect(r.exitCode, 0);
      expect(get('service.adb.tcp.port'), '5555');
      expect(get('_log'), isNot(contains('persist.internet_adb_enable')));
    });

    test('закрыть с internet_adb=1: все три свойства сняты, adbd перезапущен', () async {
      set('persist.internet_adb_enable', '1');
      set('persist.adb.tcp.port', '5555');
      set('service.adb.tcp.port', '5555');
      final r = await run(adbCloseCommand);
      expect(r.exitCode, 0);
      await settle();
      expect(get('persist.internet_adb_enable'), '0');
      expect(get('persist.adb.tcp.port'), '');
      expect(get('service.adb.tcp.port'), '0');
      expect(get('_log').trim().split('\n').last, 'ctl.restart=adbd');
      expect(get('_log'), isNot(contains('adb_enabled')));
    });

    test('чтение: вывод разбирается', () async {
      set('persist.internet_adb_enable', '1');
      set('service.adb.tcp.port', '5555');
      set('init.svc.adbd', 'running');
      final r = await run(adbProbeCommand);
      expect(r.exitCode, 0);
      final s = AdbExposure.parse(r.stdout as String)!;
      expect(s.source, 'internet_adb');
      expect(s.configuredPort, 5555);
      expect(s.wifiDebug, isFalse);
    });

    test('синтаксис sh', () {
      for (final c in [adbProbeCommand, adbOpenCommand, adbCloseCommand, adbWifiOffCommand]) {
        expect(Process.runSync('sh', ['-n', '-c', c]).exitCode, 0, reason: c);
      }
    });
  });

  group('окно 30 минут', () {
    late _FakeAdb adb;
    var now = DateTime(2026, 10, 11, 12, 0);

    Future<List<Map<String, dynamic>>> events() async => (await CloudService.history())
        .where((e) => e.type == CloudEventType.debugModeChanged)
        .map((e) => e.data)
        .toList();

    void boot() {
      AdbNetworkService.resetForTest();
      AdbNetworkService.clock = () => now;
      AdbNetworkService.sleep = (_) async {};
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      CloudService.resetQueueForTest();
      CloudService.transport = LocalLogTransport();
      UpdateService.resetForTest();
      now = DateTime(2026, 10, 11, 12, 0);
      adb = _FakeAdb();
      UpdateService.installer = adb;
      boot();
    });

    tearDown(AdbNetworkService.resetForTest);

    test('при старте открытый вне окна 5555 закрывается (reason=startup)', () async {
      adb.listening = true;
      adb.internetAdb = true;
      await AdbNetworkService.onStartup();
      expect(adb.listening, isFalse);
      expect(AdbNetworkService.adbNetwork, isFalse);
      expect(await events(), [
        {'code': 'adb_network', 'enabled': false, 'reason': 'startup'},
      ]);
    });

    test('при старте закрытый — ничего не делается', () async {
      await AdbNetworkService.onStartup();
      expect(adb.calls, ['read']);
      expect(AdbNetworkService.adbNetwork, isFalse);
      expect(await events(), isEmpty);
    });

    test('тумблер: открыт на 30 минут, через 30 минут закрывается сам', () async {
      await AdbNetworkService.onStartup();
      expect(await AdbNetworkService.open(), isTrue);
      expect(adb.listening, isTrue);
      expect(AdbNetworkService.tcpUntil, now.add(const Duration(minutes: 30)));
      now = now.add(const Duration(minutes: 29, seconds: 59));
      await AdbNetworkService.check();
      expect(adb.listening, isTrue);
      now = now.add(const Duration(seconds: 1));
      await AdbNetworkService.check();
      expect(adb.listening, isFalse);
      expect(AdbNetworkService.tcpUntil, isNull);
      expect(await events(), [
        {'code': 'adb_network', 'enabled': true, 'reason': 'service_menu'},
        {'code': 'adb_network', 'enabled': false, 'reason': 'timer'},
      ]);
    });

    test('продление: срок снова 30 минут от нажатия, без перезапуска adbd', () async {
      await AdbNetworkService.open();
      now = now.add(const Duration(minutes: 20));
      final opens = adb.calls.where((c) => c == 'open').length;
      expect(await AdbNetworkService.open(), isTrue);
      expect(adb.calls.where((c) => c == 'open').length, opens);
      expect(AdbNetworkService.tcpUntil, now.add(const Duration(minutes: 30)));
      expect((await events()).last['reason'], 'extended');
    });

    test('перезапуск приложения внутри окна (adb install) окно не обрывает', () async {
      await AdbNetworkService.open();
      now = now.add(const Duration(minutes: 10));
      boot(); // новый процесс: память пустая, настройки сохранились
      await AdbNetworkService.onStartup();
      expect(adb.listening, isTrue);
      expect(AdbNetworkService.tcpUntil, DateTime(2026, 10, 11, 12, 30));
      now = DateTime(2026, 10, 11, 12, 30);
      await AdbNetworkService.check();
      expect(adb.listening, isFalse);
    });

    test('перезагрузка внутри окна: порт закрыт сам, окно снимается, команд нет', () async {
      await AdbNetworkService.open();
      adb.listening = false; // перезагрузка: service.* пропало
      adb.calls.clear();
      boot();
      await AdbNetworkService.onStartup();
      expect(adb.calls, ['read']);
      expect(AdbNetworkService.tcpUntil, isNull);
    });

    test('открыт вне окна во время работы (системные настройки) — закрывается', () async {
      await AdbNetworkService.onStartup();
      adb.listening = true;
      await AdbNetworkService.check();
      expect(adb.listening, isFalse);
      expect((await events()).last, {'code': 'adb_network', 'enabled': false, 'reason': 'outside_window'});
    });

    test('тумблер «выкл» закрывает 5555 и беспроводную отладку', () async {
      await AdbNetworkService.open();
      adb.wifi = true;
      expect(await AdbNetworkService.close(), isTrue);
      expect(adb.listening, isFalse);
      expect(adb.wifi, isFalse);
      final ev = await events();
      expect(ev.sublist(ev.length - 2), [
        {'code': 'adb_network', 'enabled': false, 'reason': 'manual'},
        {'code': 'adb_wifi', 'enabled': false, 'reason': 'manual'},
      ]);
    });

    test('беспроводная отладка: 30 минут с момента обнаружения, затем выключается', () async {
      await AdbNetworkService.onStartup();
      now = now.add(const Duration(minutes: 3));
      adb.wifi = true;
      await AdbNetworkService.check();
      expect(AdbNetworkService.wifiUntil, now.add(const Duration(minutes: 30)));
      now = now.add(const Duration(minutes: 29));
      await AdbNetworkService.check();
      expect(adb.wifi, isTrue);
      now = now.add(const Duration(minutes: 1));
      await AdbNetworkService.check();
      expect(adb.wifi, isFalse);
      expect(AdbNetworkService.wifiUntil, isNull);
      expect(await events(), [
        {'code': 'adb_wifi', 'enabled': true, 'reason': 'detected'},
        {'code': 'adb_wifi', 'enabled': false, 'reason': 'timer'},
      ]);
    });

    test('беспроводная отладка переживает перезапуск приложения со своим сроком', () async {
      adb.wifi = true;
      await AdbNetworkService.onStartup();
      expect((await events()).single['reason'], 'startup');
      now = now.add(const Duration(minutes: 15));
      boot();
      await AdbNetworkService.onStartup();
      expect(AdbNetworkService.wifiUntil, DateTime(2026, 10, 11, 12, 30));
      expect(adb.wifi, isTrue);
    });

    test('порт не открылся — отказ, свойства сняты', () async {
      adb.openWorks = false;
      expect(await AdbNetworkService.open(), isFalse);
      expect(adb.calls, contains('close'));
      expect(AdbNetworkService.tcpUntil, isNull);
      expect(await events(), isEmpty);
    });

    test('закрыть не удалось — событие не шлётся, срок снят, при следующей проверке ещё попытка', () async {
      adb.listening = true;
      adb.closeWorks = false;
      await AdbNetworkService.onStartup();
      expect(adb.listening, isTrue);
      expect(await events(), isEmpty);
      adb.closeWorks = true;
      await AdbNetworkService.check();
      expect(adb.listening, isFalse);
      expect((await events()).single['reason'], 'outside_window');
    });

    test('нет root — состояние не определено, ничего не делается', () async {
      adb.root = false;
      await AdbNetworkService.onStartup();
      expect(AdbNetworkService.adbNetwork, isNull);
      expect(await AdbNetworkService.open(), isFalse);
      expect(adb.calls.where((c) => c != 'read'), isEmpty);
    });
  });
}

// Поддельный планшет: порт открывается и закрывается по командам.
class _FakeAdb implements PrivilegedInstaller {
  bool root = true;
  bool listening = false;
  bool internetAdb = false;
  bool wifi = false;
  bool openWorks = true;
  bool closeWorks = true;
  final List<String> calls = [];

  @override
  String get kind => 'fake';

  @override
  Future<AdbExposure?> readAdbExposure() async {
    calls.add('read');
    if (!root) return null;
    return AdbExposure(
      tcpListening: listening,
      configuredPort: listening ? adbTcpPort : 0,
      source: !listening ? 'none' : (internetAdb ? 'internet_adb' : 'service_port'),
      wifiDebug: wifi,
      tlsPort: wifi ? 37123 : null,
      tlsListening: wifi,
      authRequired: false,
      socketsKnown: true,
      internetAdb: listening && internetAdb,
      persistPort: false,
    );
  }

  @override
  Future<bool> setAdbNetwork(bool enabled) async {
    calls.add(enabled ? 'open' : 'close');
    if (!root) return false;
    if (enabled && openWorks) listening = true;
    if (!enabled && closeWorks) {
      listening = false;
      internetAdb = false;
    }
    return true;
  }

  @override
  Future<bool> disableAdbWifi() async {
    calls.add('wifi_off');
    wifi = false;
    return root;
  }

  @override
  Future<bool> isAvailable(Duration timeout) async => root;

  @override
  Future<bool> startScript(InstallRequest request, String scriptText) async => false;

  @override
  Future<bool> repairAfterUpdate({
    required String dir,
    required String packageName,
    required String aliasClass,
    required bool kiosk,
  }) async => false;
}
