import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/factory_config_service.dart';
import 'package:dry_fog_app/services/remote_commands.dart';

// Заводская запись облачных данных. Значения токена и ключа — синтетические.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const token = 'TESTTOKEN_not_real_0123456789';
  const key = 'sb_publishable_TESTKEY_not_real';

  String file({
    Object? format = 1,
    String configId = '2026-10-08-ab12cd34',
    String deviceId = 'CARFOG-123',
    String url = 'https://example.supabase.co',
    String anon = key,
    String tok = token,
    Map<String, Object?> extra = const {},
  }) => jsonEncode({
    'format': format,
    'config_id': configId,
    'device_id': deviceId,
    'cloud_url': url,
    'anon_key': anon,
    'token': tok,
    ...extra,
  });

  // ============================================================== разбор
  group('разбор файла', () {
    test('корректный файл', () {
      final r = parseFactoryConfig(file());
      expect(r.ok, isTrue);
      expect(r.config!.deviceId, 'CARFOG-123');
      expect(r.config!.configId, '2026-10-08-ab12cd34');
      expect(r.config!.cloudUrl, 'https://example.supabase.co');
    });

    test('лишние поля игнорируются', () {
      final r = parseFactoryConfig(file(extra: {'note': 'x', 'ring': 'test', 'n': 5}));
      expect(r.ok, isTrue);
    });

    test('битый JSON и не объект', () {
      for (final bad in ['', '{', 'not json', '[]', '"x"', '5', 'null']) {
        final r = parseFactoryConfig(bad);
        expect(r.ok, isFalse, reason: bad);
        expect(r.error, FactoryConfigError.badJson);
      }
    });

    test('format не равен 1', () {
      for (final f in [2, 0, '1', null, 1.5]) {
        expect(parseFactoryConfig(file(format: f)).error, FactoryConfigError.badFormat, reason: '$f');
      }
    });

    test('пустые и отсутствующие поля', () {
      for (final k in ['config_id', 'device_id', 'cloud_url', 'anon_key', 'token']) {
        final m = jsonDecode(file()) as Map<String, dynamic>;
        m[k] = '';
        expect(parseFactoryConfig(jsonEncode(m)).error, FactoryConfigError.missingField, reason: 'пусто $k');
        m[k] = '   ';
        expect(parseFactoryConfig(jsonEncode(m)).error, FactoryConfigError.missingField, reason: 'пробелы $k');
        m.remove(k);
        expect(parseFactoryConfig(jsonEncode(m)).error, FactoryConfigError.missingField, reason: 'нет $k');
        m[k] = 5;
        expect(parseFactoryConfig(jsonEncode(m)).error, FactoryConfigError.missingField, reason: 'число $k');
      }
    });

    test('http вместо https и негодный адрес отклоняются', () {
      for (final u in ['http://example.supabase.co', 'ftp://x.y', 'example.supabase.co', 'https://', 'https:///x']) {
        expect(parseFactoryConfig(file(url: u)).error, FactoryConfigError.notHttps, reason: u);
      }
    });

    test('номер аппарата: недопустимые символы и длина', () {
      for (final d in ['A B', "A';--", 'a/b', 'x' * 65]) {
        expect(parseFactoryConfig(file(deviceId: d)).error, FactoryConfigError.badDeviceId, reason: d);
      }
    });

    test('слишком длинные значения', () {
      expect(parseFactoryConfig(file(tok: 'x' * 2000)).error, FactoryConfigError.tooLong);
    });

    test('причина отказа не содержит значений полей', () {
      final r = parseFactoryConfig(file(format: 2));
      expect(r.error.toString(), isNot(contains(token)));
      expect(r.error.toString(), isNot(contains(key)));
    });
  });

  // ================================================ правило применения
  group('правило применения', () {
    late _FakeStore store;

    AppConfig base({String url = '', String anon = '', String tok = '', bool enabled = false}) => AppConfig(
      treatmentPriceCents: 300,
      treatmentDurationS: 55,
      servicePin: '7351',
      compressorPurgeS: 12,
      pumpAfterHeaterS: 9,
      deviceId: 'CARFOG-001',
      cloudUrl: url,
      cloudAnonKey: anon,
      cloudToken: tok,
      cloudEnabled: enabled,
      kioskModeEnabled: true,
      thermoInstalled: true,
      energyMeterInstalled: true,
    );

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      store = _FakeStore();
      FactoryConfigService.store = store;
      CloudService.resetQueueForTest();
    });

    test('файла нет — ничего не делает', () async {
      final c = base();
      final r = await FactoryConfigService.evaluate(c);
      expect(r.status, FactoryApplyStatus.noFile);
      expect(r.config, same(c));
    });

    test('файл новый, настройки пусты — применяется, остальное не тронуто', () async {
      store.text = file();
      final r = await FactoryConfigService.evaluate(base());
      expect(r.status, FactoryApplyStatus.applied);
      final c = r.config;
      expect(c.deviceId, 'CARFOG-123');
      expect(c.cloudUrl, 'https://example.supabase.co');
      expect(c.cloudAnonKey, key);
      expect(c.cloudToken, token);
      expect(c.cloudEnabled, isTrue);
      // всё остальное прежнее
      expect(c.treatmentPriceCents, 300);
      expect(c.treatmentDurationS, 55);
      expect(c.servicePin, '7351');
      expect(c.compressorPurgeS, 12);
      expect(c.pumpAfterHeaterS, 9);
      expect(c.kioskModeEnabled, isTrue);
      expect(c.thermoInstalled, isTrue);
      expect(c.energyMeterInstalled, isTrue);
    });

    test('тот же config_id и облако настроено — не применяется повторно', () async {
      store.text = file();
      final cfg = base();
      await FactoryConfigService.applyOnStartup(cfg);
      // оператор поменял токен вручную: тот же config_id файл не перезаписывает
      final manual = base(url: 'https://my.example.co', anon: 'k', tok: 'manualtoken', enabled: true);
      final r = await FactoryConfigService.evaluate(manual);
      expect(r.status, FactoryApplyStatus.upToDate);
      expect(r.config.cloudToken, 'manualtoken');
    });

    test('тот же config_id, но облачные настройки пусты (pm clear) — применяется снова', () async {
      store.text = file();
      await FactoryConfigService.applyOnStartup(base());
      final r = await FactoryConfigService.evaluate(base()); // настройки стёрты
      expect(r.status, FactoryApplyStatus.applied);
      expect(r.config.cloudToken, token);
    });

    test('другой config_id (новый токен) — применяется даже при настроенном облаке', () async {
      store.text = file();
      await FactoryConfigService.applyOnStartup(base());
      store.text = file(configId: '2026-10-09-ffffffff', tok: 'NEWTOKEN_not_real_999');
      final configured = base(url: 'https://example.supabase.co', anon: key, tok: token, enabled: true);
      final r = await FactoryConfigService.evaluate(configured);
      expect(r.status, FactoryApplyStatus.applied);
      expect(r.config.cloudToken, 'NEWTOKEN_not_real_999');
      expect(r.configId, '2026-10-09-ffffffff');
    });

    test('битый файл: не падает, настройки не меняются', () async {
      for (final bad in ['{', file(format: 9), file(url: 'http://x.y'), file(tok: '')]) {
        store.text = bad;
        final c = base();
        final r = await FactoryConfigService.evaluate(c);
        expect(r.status, FactoryApplyStatus.invalid, reason: bad);
        expect(r.config, same(c));
      }
    });

    test('файл не читается — не падает', () async {
      store.unreadable = true;
      final c = base();
      expect((await FactoryConfigService.evaluate(c)).status, FactoryApplyStatus.unreadable);
      store.throwOnRead = true;
      expect((await FactoryConfigService.evaluate(c)).status, FactoryApplyStatus.unreadable);
    });

    test('applyOnStartup сохраняет настройки и запоминает config_id', () async {
      store.text = file();
      final applied = await FactoryConfigService.applyOnStartup(base());
      expect(applied.cloudToken, token);
      expect(await FactoryConfigService.appliedId(), '2026-10-08-ab12cd34');
      final loaded = await ConfigService.load();
      expect(loaded.cloudToken, token);
      expect(loaded.treatmentPriceCents, 300);
    });

    test('applyIfNeeded: работающее приложение — сохраняет и переконфигурирует облако', () async {
      store.text = file();
      final n = AppNotifier()..config = base();
      final st = await FactoryConfigService.applyIfNeeded(n);
      expect(st, FactoryApplyStatus.applied);
      expect(n.config.cloudToken, token);
      expect(CloudService.deviceId, 'CARFOG-123');
      expect(CloudService.isCloudEnabled, isTrue);
      // повторно — ничего
      expect(await FactoryConfigService.applyIfNeeded(n), FactoryApplyStatus.upToDate);
    });

    test('запасной путь через root: на старте разрешён, при возврате на передний план — нет', () async {
      store.text = file();
      await FactoryConfigService.applyOnStartup(base());
      expect(store.readCalls, [true]);
      store.readCalls.clear();
      final n = AppNotifier()..config = base();
      await FactoryConfigService.applyIfNeeded(n);
      expect(store.readCalls, [false]);
    });

    test('resume при отсутствии файла: прямое чтение, без su, ничего не меняется', () async {
      final n = AppNotifier()
        ..config = base(url: 'https://x.y', anon: 'k', tok: 'manualtoken', enabled: true);
      for (var i = 0; i < 3; i++) {
        expect(await FactoryConfigService.applyIfNeeded(n), FactoryApplyStatus.noFile);
      }
      expect(store.readCalls, [false, false, false]);
      expect(n.config.cloudToken, 'manualtoken');
    });

    test('resume при уже выданном разрешении: файл читается и применяется как раньше', () async {
      store.text = file();
      final n = AppNotifier()..config = base();
      expect(await FactoryConfigService.applyIfNeeded(n), FactoryApplyStatus.applied);
      expect(n.config.cloudToken, token);
      expect(store.readCalls, [false]);
    });

    test('SharedStorageConfigStore: allowRoot=false не обращается к su (канал не вызывается)', () async {
      final tmp = await Directory.systemTemp.createTemp('fcroot');
      try {
        var rootCalls = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.carfog.dryfog/system'),
          (c) async {
            if (c.method == 'rootExec') rootCalls++;
            return null;
          },
        );
        final s = SharedStorageConfigStore(path: '${tmp.path}/нет/device_config.json');
        expect((await s.read(allowRoot: false)).status, FileReadStatus.absent);
        expect(rootCalls, 0);
        expect((await s.read()).status, FileReadStatus.absent);
        expect(rootCalls, 1); // на старте запасной путь вызывается
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('com.carfog.dryfog/system'), null);
        await tmp.delete(recursive: true);
      }
    });

    test('секреты из файла маскируются в журнале после применения', () async {
      store.text = file();
      await FactoryConfigService.applyOnStartup(base());
      final line = AppLog.redact('ключ=$key токен=$token');
      expect(line, isNot(contains(token)));
      expect(line, isNot(contains(key)));
    });

    test('заводской сброс сохраняет облако и config_id, остальное сбрасывает', () async {
      store.text = file();
      final n = AppNotifier()
        ..config = await FactoryConfigService.applyOnStartup(base())
        ..transition(AppState.standby);
      final o = await RemoteCommands.handle(
        CloudCommand(id: 'fr-1', action: 'factory_reset', createdAt: DateTime.now()),
        n,
      );
      expect(o.ok, isTrue, reason: o.result);
      expect(n.config.cloudToken, token);
      expect(n.config.cloudAnonKey, key);
      expect(n.config.cloudUrl, 'https://example.supabase.co');
      expect(n.config.deviceId, 'CARFOG-123');
      expect(n.config.cloudEnabled, isTrue);
      expect(n.config.treatmentPriceCents, 200); // остальное — по умолчанию
      expect(await FactoryConfigService.appliedId(), '2026-10-08-ab12cd34'); // config_id остался
      // и после перезапуска (чтения из хранилища) облако на месте
      final loaded = await ConfigService.load();
      expect(loaded.cloudToken, token);
    });

    test('финиш: удалён / файла не было / не удалось', () async {
      store.text = file();
      var r = await FactoryConfigService.finishCommissioning();
      expect(r.status, FileDeleteStatus.deleted);
      expect(store.text, isNull);
      r = await FactoryConfigService.finishCommissioning();
      expect(r.status, FileDeleteStatus.absent);
      store.text = file();
      store.failDelete = 'permission';
      r = await FactoryConfigService.finishCommissioning();
      expect(r.status, FileDeleteStatus.failed);
      expect(r.reason, 'permission');
      expect(store.text, isNotNull);
    });

    test('после финиша облачные настройки в приложении остаются', () async {
      store.text = file();
      final n = AppNotifier()..config = await FactoryConfigService.applyOnStartup(base());
      await FactoryConfigService.finishCommissioning();
      expect(n.config.cloudToken, token);
      // файла больше нет: следующий старт ничего не делает
      expect((await FactoryConfigService.evaluate(n.config)).status, FactoryApplyStatus.noFile);
    });

    test('сводка для экрана не содержит токена и ключа', () async {
      store.text = file();
      final cfg = await FactoryConfigService.applyOnStartup(base());
      final sm = await FactoryConfigService.summary(cfg);
      expect(sm.cloudConfigured, isTrue);
      expect(sm.deviceId, 'CARFOG-123');
      expect(sm.configId, '2026-10-08-ab12cd34');
      expect(sm.toString(), isNot(contains(token)));
      expect(sm.toString(), isNot(contains(key)));
    });
  });

  // ===================== файл генератора читается приложением
  test('файл, созданный tool/provision_devices.py, принимается разбором приложения', () async {
    final py = await Process.run('python3', ['--version']).catchError((_) => ProcessResult(0, 127, '', ''));
    if (py.exitCode != 0) {
      markTestSkipped('python3 недоступен');
      return;
    }
    final out = await Directory.systemTemp.createTemp('provcheck');
    try {
      final r = await Process.run('python3', [
        'tool/provision_devices.py',
        '--org-id', '123e4567-e89b-12d3-a456-426614174000',
        '--cloud-url', 'https://example.supabase.co',
        '--anon-key', key,
        '--prefix', 'CARFOG-', '--start', '501', '--count', '2',
        '--out', out.path,
      ]);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout.toString(), isNot(contains('"token"')));
      final cfgDir = Directory(out.path).listSync().whereType<Directory>().single;
      final f = File('${cfgDir.path}/configs/CARFOG-501.json');
      final parsed = parseFactoryConfig(await f.readAsString());
      expect(parsed.ok, isTrue, reason: '${parsed.error}');
      expect(parsed.config!.deviceId, 'CARFOG-501');
      expect(parsed.config!.cloudUrl, 'https://example.supabase.co');
      expect(parsed.config!.anonKey, key);
      expect(parsed.config!.token.length, greaterThanOrEqualTo(43));
    } finally {
      await out.delete(recursive: true);
    }
  });

  // ============================ реальный файл (прямой доступ, без root)
  group('SharedStorageConfigStore на реальном файле', () {
    late Directory tmp;
    late String path;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('fc');
      path = '${tmp.path}/CarFog/device_config.json';
    });
    tearDown(() => tmp.delete(recursive: true));

    test('чтение: нет файла / есть файл', () async {
      final s = SharedStorageConfigStore(path: path);
      expect((await s.read()).status, FileReadStatus.absent);
      Directory('${tmp.path}/CarFog').createSync();
      File(path).writeAsStringSync(file());
      final r = await s.read();
      expect(r.status, FileReadStatus.ok);
      expect(parseFactoryConfig(r.text!).ok, isTrue);
    });

    test('удаление: удалён / не было', () async {
      final s = SharedStorageConfigStore(path: path);
      Directory('${tmp.path}/CarFog').createSync();
      File(path).writeAsStringSync(file());
      expect((await s.delete()).status, FileDeleteStatus.deleted);
      expect(File(path).existsSync(), isFalse);
      expect((await s.delete()).status, FileDeleteStatus.absent);
    });

    test('путь по умолчанию — общий каталог /storage/emulated/0/CarFog', () {
      expect(SharedStorageConfigStore.defaultPath, '/storage/emulated/0/CarFog/device_config.json');
    });
  });
}

class _FakeStore implements FactoryConfigStore {
  // Как вызывали read: allowRoot на каждом обращении.
  final List<bool> readCalls = [];
  String? text;
  bool unreadable = false;
  bool throwOnRead = false;
  String? failDelete;

  @override
  Future<FileReadResult> read({bool allowRoot = true}) async {
    readCalls.add(allowRoot);
    if (throwOnRead) throw StateError('io');
    if (unreadable) return const FileReadResult(FileReadStatus.unreadable);
    if (text == null) return const FileReadResult(FileReadStatus.absent);
    return FileReadResult(FileReadStatus.ok, text);
  }

  @override
  Future<FileDeleteResult> delete() async {
    if (failDelete != null) return FileDeleteResult(FileDeleteStatus.failed, failDelete);
    if (text == null) return const FileDeleteResult(FileDeleteStatus.absent);
    text = null;
    return const FileDeleteResult(FileDeleteStatus.deleted);
  }
}
