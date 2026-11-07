import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dry_fog_app/brand/brand.dart';
import 'package:dry_fog_app/brand/brand_service.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

import 'brand_test_util.dart';

void main() {
  late Directory root;
  late AppNotifier n;
  late List<Map<String, dynamic>> events;
  late DateTime now;
  late int ticketCalls;
  late Directory base;

  Future<void> poll(BrandDirective? d) => BrandService.onPoll(n, d);

  Uint8List good(String id, int v, {bool qr = false}) =>
      goodZip(manifest: manifestMap(id: id, version: v, qr: qr), qr: qr);

  File pointer() => File('${root.path}/current.json');
  List<String> names() => root.listSync().map((e) => e.path.split('/').last).toList()..sort();

  setUp(() async {
    BrandService.resetForTest();
    base = Directory.systemTemp.createTempSync('brand_svc_');
    n = AppNotifier()..config = AppConfig(cloudUrl: 'https://abc.supabase.co');
    n.transition(AppState.standby);
    events = [];
    now = DateTime(2026, 11, 7, 12);
    ticketCalls = 0;
    _served = null;
    _downloadError = null;
    _fakeSize = null;
    BrandService.rootProvider = () async => Directory('${base.path}/brand');
    BrandService.clock = () => now;
    BrandService.reporter = (type, data) async => events.add({'type': type, ...data});
    BrandService.ticketFetcher = (cfg) async {
      ticketCalls++;
      final z = _served!;
      // id/версия — из запроса; тест подставляет их через directive.
      return BrandTicket(
        id: _lastId,
        version: _lastVer,
        sha256: _lastSha,
        sizeBytes: _fakeSize ?? z.length,
        url: Uri.parse('https://abc.supabase.co/storage/v1/sign/x?token=SECRET'),
      );
    };
    BrandService.downloader = (url, max) async {
      if (_downloadError != null) throw _downloadError!;
      return _served!;
    };
    root = Directory('${base.path}/brand')..createSync();
    await BrandService.init(n);
  });

  tearDown(() {
    BrandService.resetForTest();
    try {
      base.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('поле brand в device_poll', () {
    test('нет поля → null; null → builtin; верное → assign; мусор → null', () {
      expect(BrandDirective.tryParse({'ok': true}), isNull);
      expect(BrandDirective.tryParse({'brand': null})!.isBuiltin, isTrue);
      final sha = 'a' * 64;
      final d = BrandDirective.tryParse(
          {'brand': {'id': 'acme', 'version': 2, 'sha256': sha.toUpperCase(), 'size_bytes': 500}})!;
      expect(d.id, 'acme');
      expect(d.version, 2);
      expect(d.sha256, sha);
      expect(d.sizeBytes, 500);
      for (final bad in <Object?>[
        'x',
        5,
        [],
        {},
        {'id': 'ACME', 'version': 1, 'sha256': sha, 'size_bytes': 5},
        {'id': 'acme', 'version': 0, 'sha256': sha, 'size_bytes': 5},
        {'id': 'acme', 'version': '1', 'sha256': sha, 'size_bytes': 5},
        {'id': 'acme', 'version': 1, 'sha256': 'abc', 'size_bytes': 5},
        {'id': 'acme', 'version': 1, 'sha256': sha, 'size_bytes': 0},
        {'id': 'acme', 'version': 1, 'sha256': sha, 'size_bytes': 2000000},
        {'id': 'acme', 'version': 1, 'sha256': sha},
      ]) {
        expect(BrandDirective.tryParse({'brand': bad}), isNull, reason: '$bad');
      }
    });
  });

  group('установка', () {
    test('годный пакет: файлы, указатель, применение на заставке', () async {
      final d = await offerD(good('acme', 1, qr: true));
      await poll(d);
      expect(pointer().existsSync(), isTrue);
      expect(jsonDecode(pointer().readAsStringSync()),
          {'id': 'acme', 'version': 1, 'sha256': d.sha256});
      expect(Directory('${root.path}/acme-v1').existsSync(), isTrue);
      expect(names(), ['acme-v1', 'current.json']);
      final b = BrandController.instance.active;
      expect(b.id, 'acme');
      expect(b.name, 'Acme Fog');
      expect(b.logoPath, '${root.path}/acme-v1/logo.png');
      expect(b.qrPath, '${root.path}/acme-v1/qr_default.png');
      expect(BrandService.state, 'applied');
      expect(BrandService.reported(),
          {'brand_id': 'acme', 'brand_version': 1, 'brand_state': 'applied'});
      expect(events, isEmpty);
    });

    test('вне заставки только pending; на заставке применяется', () async {
      n.transition(AppState.payment);
      await poll(await offerD(good('acme', 1)));
      expect(BrandController.instance.active.isBuiltin, isTrue);
      expect(BrandService.state, 'pending');
      expect(BrandService.reported()['brand_id'], 'acme');
      for (final s in [AppState.preparing, AppState.treating, AppState.finished, AppState.serviceMenu]) {
        n.transition(s);
        expect(BrandController.instance.active.isBuiltin, isTrue, reason: '$s');
      }
      n.transition(AppState.standby);
      expect(BrandController.instance.active.id, 'acme');
      expect(BrandService.state, 'applied');
    });

    test('уже стоит такой же — ничего не делает', () async {
      final d = await offerD(good('acme', 1));
      await poll(d);
      final calls = ticketCalls;
      await poll(d);
      expect(ticketCalls, calls);
    });

    test('без брендового ответа (null с сервера до сбоя) ничего не ломает', () async {
      await poll(null);
      expect(BrandService.state, 'builtin');
      expect(ticketCalls, 0);
    });

    test('brand:null возвращает встроенный CaRFog, файлы пока остаются', () async {
      await poll(await offerD(good('acme', 1)));
      await poll(const BrandDirective.builtin());
      expect(pointer().existsSync(), isFalse);
      expect(BrandController.instance.active.isBuiltin, isTrue);
      expect(BrandService.state, 'builtin');
      expect(Directory('${root.path}/acme-v1').existsSync(), isTrue);
      expect(BrandService.reported(),
          {'brand_id': 'carfog', 'brand_version': 0, 'brand_state': 'builtin'});
    });

    test('ссылка brand-url вернула brand:null → встроенный', () async {
      await poll(await offerD(good('acme', 1)));
      BrandService.ticketFetcher = (cfg) async => null;
      await poll(await offerD(good('acme', 2), v: 2));
      expect(BrandController.instance.active.isBuiltin, isTrue);
      expect(pointer().existsSync(), isFalse);
    });
  });

  group('ошибки: прежний бренд остаётся, событие brand_failed', () {
    Future<void> installV1() async {
      await poll(await offerD(good('acme', 1)));
      expect(BrandController.instance.active.version, 1);
      events.clear();
    }

    void expectKept(String reason) {
      expect(BrandController.instance.active.version, 1);
      expect(jsonDecode(pointer().readAsStringSync())['version'], 1);
      expect(names().where((e) => e.startsWith('tmp-')), isEmpty);
      expect(Directory('${root.path}/acme-v1').existsSync(), isTrue);
      expect(BrandService.state, 'failed:$reason');
      expect(events.map((e) => e['reason']), [reason]);
      expect(events.single['type'], 'brand_failed');
    }

    Future<void> failWith(Uint8List zip, String reason,
        {int? size, String? sha, int v = 2}) async {
      await installV1();
      await poll(await offerD(zip, v: v, size: size, sha: sha));
      expectKept(reason);
    }

    test('скачивание не удалось', () async {
      await installV1();
      _downloadError = const SocketException('x');
      await poll(await offerD(good('acme', 2), v: 2));
      expectKept('download');
    });

    test('sha256 не совпал', () async {
      await failWith(good('acme', 2), 'sha256', sha: 'b' * 64);
    });

    test('размер не совпал', () async {
      final z = good('acme', 2);
      await failWith(z, 'sha256', size: z.length + 1);
    });

    test('чужое имя в архиве → zip:name', () async {
      await failWith(
          goodZip(manifest: manifestMap(version: 2), extra: [ZipEntry('../x', Uint8List(3))]), 'zip:name');
    });

    test('манифест: версия не та', () async {
      await failWith(goodZip(manifest: manifestMap(version: 9)), 'manifest:version');
    });

    test('манифест: лишний ключ', () async {
      await failWith(
          goodZip(manifest: manifestMap(version: 2, extra: {'hack': 1})), 'manifest:unknown_key');
    });

    test('логотип не PNG', () async {
      await failWith(
          goodZip(manifest: manifestMap(version: 2), logo: Uint8List.fromList(List.filled(50, 3))),
          'png:not_png');
    });

    test('большой логотип', () async {
      await failWith(
          goodZip(manifest: manifestMap(version: 2), logo: fakePng(pad: 400000)), 'png:too_big');
    });

    test('контраст', () async {
      final c = Map<String, String>.from(manifestMap()['colors'] as Map)..['textPrimary'] = '#222222';
      await failWith(goodZip(manifest: manifestMap(version: 2, colors: c)), 'contrast');
    });

    for (final stage in ['mkdir_tmp', 'rename_dir', 'write_pointer']) {
      test('сбой записи на этапе $stage', () async {
        await installV1();
        BrandService.ioFailureHook = (s) {
          if (s == stage) throw const FileSystemException('boom');
        };
        await poll(await offerD(good('acme', 2), v: 2));
        // указатель и текущий бренд не тронуты
        expect(BrandController.instance.active.version, 1);
        expect(jsonDecode(pointer().readAsStringSync())['version'], 1);
        expect(BrandService.state, 'failed:io');
        expect(events.single['reason'], 'io');
        expect(names().where((e) => e.startsWith('tmp-')), isEmpty);
      });
    }

    test('после сбоя пауза не меньше 30 с и растёт; событие не повторяется', () async {
      await installV1();
      final d = await offerD(good('acme', 2), v: 2, sha: 'c' * 64);
      await poll(d);
      final calls = ticketCalls;
      now = now.add(const Duration(seconds: 29));
      await poll(d);
      expect(ticketCalls, calls, reason: 'раньше 30 с повтора нет');
      now = now.add(const Duration(seconds: 2));
      await poll(d);
      expect(ticketCalls, calls + 1);
      // вторая пауза — 60 с
      now = now.add(const Duration(seconds: 45));
      await poll(d);
      expect(ticketCalls, calls + 1);
      now = now.add(const Duration(seconds: 20));
      await poll(d);
      expect(ticketCalls, calls + 2);
      expect(events.length, 1, reason: 'одинаковая причина — одно событие');
      // потолок 15 минут
      for (var i = 0; i < 12; i++) {
        now = now.add(const Duration(minutes: 16));
        await poll(d);
      }
      final c2 = ticketCalls;
      now = now.add(const Duration(minutes: 14));
      await poll(d);
      expect(ticketCalls, c2);
    });

    test('успех после сбоя снимает failed', () async {
      await installV1();
      await poll(await offerD(good('acme', 2), v: 2, sha: 'c' * 64));
      expect(BrandService.state, startsWith('failed'));
      now = now.add(const Duration(hours: 1));
      await poll(await offerD(good('acme', 2), v: 2));
      expect(BrandService.state, 'applied');
      expect(BrandController.instance.active.version, 2);
    });
  });

  group('чистка версий', () {
    test('остаются текущая и одна предыдущая', () async {
      for (var v = 1; v <= 4; v++) {
        await poll(await offerD(good('acme', v), v: v));
        now = now.add(const Duration(seconds: 1));
      }
      expect(names(), ['acme-v3', 'acme-v4', 'current.json']);
    });

    test('недокачанные tmp-* убираются', () async {
      Directory('${root.path}/tmp-123').createSync();
      await poll(await offerD(good('acme', 1)));
      expect(names().where((e) => e.startsWith('tmp-')), isEmpty);
    });
  });

  group('запуск и устойчивость', () {
    test('без сети последний годный бренд работает после перезапуска', () async {
      await poll(await offerD(good('acme', 1)));
      BrandController.instance.setActive(Brand.builtin);
      // «перезапуск»: новый init, сеть не вызывается
      BrandService.ticketFetcher = (cfg) async => throw StateError('нет сети');
      await BrandService.init(n);
      expect(BrandController.instance.active.id, 'acme');
      expect(BrandService.state, 'applied');
    });

    test('повреждён манифест: встроенный бренд, brand_failed:io, указатель сброшен', () async {
      await poll(await offerD(good('acme', 1)));
      BrandController.instance.setActive(Brand.builtin);
      File('${root.path}/acme-v1/brand.json').writeAsStringSync('{не json');
      events.clear();
      await BrandService.init(n);
      expect(BrandController.instance.active.isBuiltin, isTrue);
      expect(BrandService.state, 'failed:io');
      expect(events.single, {'type': 'brand_failed', 'reason': 'io'});
      expect(pointer().existsSync(), isFalse);
    });

    test('повреждён указатель', () async {
      await poll(await offerD(good('acme', 1)));
      BrandController.instance.setActive(Brand.builtin);
      pointer().writeAsStringSync('[1,2');
      events.clear();
      await BrandService.init(n);
      expect(BrandController.instance.active.isBuiltin, isTrue);
      expect(events.single['reason'], 'io');
    });

    test('нет папки, указатель есть', () async {
      await poll(await offerD(good('acme', 1)));
      BrandController.instance.setActive(Brand.builtin);
      Directory('${root.path}/acme-v1').deleteSync(recursive: true);
      await BrandService.init(n);
      expect(BrandController.instance.active.isBuiltin, isTrue);
      expect(BrandService.state, 'failed:io');
    });

    test('после порчи следующий опрос ставит пакет заново', () async {
      final d = await offerD(good('acme', 1));
      await poll(d);
      File('${root.path}/acme-v1/logo.png').writeAsBytesSync([1, 2, 3]);
      await BrandService.init(n);
      expect(BrandService.state, 'failed:io');
      now = now.add(const Duration(minutes: 1));
      await poll(d);
      expect(BrandService.state, 'applied');
    });

    test('диагностика и слепок не содержат ссылок и токенов', () async {
      await poll(await offerD(good('acme', 1)));
      final text = jsonEncode([BrandService.diagnostics(), BrandService.reported()]);
      expect(text, isNot(contains('SECRET')));
      expect(text, isNot(contains('http')));
      expect(BrandService.diagnostics()['id'], 'acme');
      expect(BrandService.diagnostics()['state'], 'applied');
      expect(BrandService.diagnostics()['last_error'], isNull);
    });
  });
}

String _lastId = '';
int _lastVer = 0;
String _lastSha = '';

/// Директива + запоминание того, что вернёт «brand-url».
Future<BrandDirective> offerD(Uint8List zip, {String id = 'acme', int v = 1, int? size, String? sha}) async {
  final d = BrandDirective.assign(
    id: id,
    version: v,
    sha256: sha ?? sha256.convert(zip).toString(),
    sizeBytes: size ?? zip.length,
  );
  _lastId = id;
  _lastVer = v;
  _lastSha = d.sha256!;
  _served = zip;
  _fakeSize = size;
  return d;
}

Uint8List? _served;
Object? _downloadError;
int? _fakeSize;
