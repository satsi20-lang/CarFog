import 'dart:convert';
import 'dart:io';

import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/video/video_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _a = '0f8fad5b-d9cb-469f-a165-70867728950e';
final _sha = 'a' * 64;
final _cfg = AppConfig(
  cloudEnabled: true,
  cloudUrl: 'https://abc.supabase.co/',
  cloudAnonKey: 'anon',
  cloudToken: 'TOKEN-TOKEN',
  deviceId: 'CARFOG-001',
);

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _ticketBody(String url) => {
      'ok': true,
      'video': {'id': _a, 'sha256': _sha, 'size_bytes': 100, 'url': url},
      'expires_in_s': 21600,
    };

Future<T> _with<T>(MockClient c, Future<T> Function() body) =>
    http.runWithClient(body, () => c);

void main() {
  const api = HttpVideoApi();

  group('ссылка на скачивание (video-url)', () {
    test('верный ответ; в запросе токен аппарата и id видео', () async {
      late http.Request seen;
      final c = MockClient((req) async {
        seen = req;
        return _json(_ticketBody('https://abc.supabase.co/storage/v1/object/sign/x?token=T'));
      });
      final t = await _with(c, () => api.ticket(_cfg, _a));
      expect(t.sizeBytes, 100);
      expect(t.sha256, _sha);
      expect(seen.url.toString(), 'https://abc.supabase.co/functions/v1/video-url');
      final body = jsonDecode(seen.body) as Map;
      expect(body['video'], _a);
      expect(body['device'], 'CARFOG-001');
    });

    test('ссылка на чужой хост или не https отклоняется', () async {
      for (final u in ['https://evil.example.com/x', 'http://abc.supabase.co/x']) {
        final c = MockClient((req) async => _json(_ticketBody(u)));
        await expectLater(
          _with(c, () => api.ticket(_cfg, _a)),
          throwsA(isA<VideoFailure>().having((e) => e.code, 'code', 'ticket')),
        );
      }
    });

    test('коды ответа: 429/500 — повторить, 401 — auth, 404 — not_found, прочее — http_NNN', () async {
      Future<VideoFailure> fail(int s) async {
        final c = MockClient((req) async => _json({'ok': false, 'error': 'x'}, s));
        try {
          await _with(c, () => api.ticket(_cfg, _a));
        } on VideoFailure catch (e) {
          return e;
        }
        fail_('нет ошибки для $s');
        throw StateError('unreachable');
      }

      expect((await fail(429)).retryable, isTrue);
      expect((await fail(500)).retryable, isTrue);
      expect((await fail(401)).code, 'auth');
      expect((await fail(404)).code, 'not_found');
      final e = await fail(418);
      expect(e.code, 'http_418');
      expect(e.retryable, isFalse);
    });

    test('сеть недоступна — network, можно повторить', () async {
      final c = MockClient((req) async => throw const SocketException('down'));
      await expectLater(
        _with(c, () => api.ticket(_cfg, _a)),
        throwsA(isA<VideoFailure>().having((e) => e.retryable, 'retryable', true)),
      );
    });
  });

  group('набор от облака (device_videos_get)', () {
    test('разбор и коды отказа', () async {
      var c = MockClient((req) async => _json({
            'ok': true,
            'videos_rev': 3,
            'videos': [
              {'id': _a, 'title': 'T', 'source': 'upload', 'sha256': _sha, 'size_bytes': 100, 'play': true, 'delete': false, 'created_at': '2026-11-01T00:00:00Z'}
            ],
          }));
      var r = await _with(c, () => api.getDesired(_cfg));
      expect(r.set!.rev, 3);
      expect(r.set!.items.single.play, isTrue);

      c = MockClient((req) async => _json({'ok': false, 'error': 'rate_limited'}));
      r = await _with(c, () => api.getDesired(_cfg));
      expect(r.set, isNull);
      expect(r.error, 'rate_limited');

      c = MockClient((req) async => _json({'ok': true, 'videos': 5}));
      r = await _with(c, () => api.getDesired(_cfg));
      expect(r.error, 'bad_response');

      c = MockClient((req) async => http.Response('', 503));
      r = await _with(c, () => api.getDesired(_cfg));
      expect(r.error, 'http_503');

      c = MockClient((req) async => throw const SocketException('x'));
      r = await _with(c, () => api.getDesired(_cfg));
      expect(r.error, 'network');
    });

    test('отчёт: токен и элементы уходят в device_video_report', () async {
      late http.Request seen;
      final c = MockClient((req) async {
        seen = req;
        return _json({'ok': true, 'videos_rev': 1});
      });
      final ok = await _with(c, () => api.report(_cfg, [
            {'kind': 'upload', 'id': _a, 'state': 'present'}
          ]));
      expect(ok, isTrue);
      expect(seen.url.path, '/rest/v1/rpc/device_video_report');
      final b = jsonDecode(seen.body) as Map;
      expect(b['p_device'], 'CARFOG-001');
      expect((b['p_items'] as List).length, 1);
      final bad = MockClient((req) async => _json({'ok': false, 'error': 'auth'}));
      expect(await _with(bad, () => api.report(_cfg, [])), isFalse);
    });
  });

  group('скачивание (Range)', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('video_api_'));
    tearDown(() => tmp.deleteSync(recursive: true));

    MockClient streaming(int status, List<int> body, void Function(http.BaseRequest) onReq) =>
        MockClient.streaming((req, _) async {
          onReq(req);
          return http.StreamedResponse(Stream.value(body), status);
        });

    test('с нуля: без заголовка Range, файл записан', () async {
      http.BaseRequest? seen;
      final part = File('${tmp.path}/a.part');
      await _with(streaming(200, [1, 2, 3], (r) => seen = r),
          () => api.download(Uri.parse('https://abc.supabase.co/x'), part, 0, shouldContinue: () => true));
      expect(seen!.headers.containsKey('Range'), isFalse);
      expect(part.readAsBytesSync(), [1, 2, 3]);
    });

    test('докачка: Range bytes=N-, 206 дописывает в конец', () async {
      http.BaseRequest? seen;
      final part = File('${tmp.path}/a.part')..writeAsBytesSync([1, 2, 3]);
      await _with(streaming(206, [4, 5], (r) => seen = r),
          () => api.download(Uri.parse('https://abc.supabase.co/x'), part, 3, shouldContinue: () => true));
      expect(seen!.headers['Range'], 'bytes=3-');
      expect(part.readAsBytesSync(), [1, 2, 3, 4, 5]);
    });

    test('сервер ответил 200 на Range — пишем с нуля, без дублей', () async {
      final part = File('${tmp.path}/a.part')..writeAsBytesSync([9, 9, 9]);
      await _with(streaming(200, [1, 2, 3, 4, 5], (_) {}),
          () => api.download(Uri.parse('https://abc.supabase.co/x'), part, 3, shouldContinue: () => true));
      expect(part.readAsBytesSync(), [1, 2, 3, 4, 5]);
    });

    test('416 при докачке — файл уже целиком, не ошибка', () async {
      final part = File('${tmp.path}/a.part')..writeAsBytesSync([1, 2, 3]);
      await _with(streaming(416, [], (_) {}),
          () => api.download(Uri.parse('https://abc.supabase.co/x'), part, 3, shouldContinue: () => true));
      expect(part.readAsBytesSync(), [1, 2, 3]);
    });

    test('403 (ссылка истекла) и 5xx — повторить с новой ссылкой; 404 — окончательно', () async {
      Future<VideoFailure> go(int s) async {
        final part = File('${tmp.path}/b$s.part');
        try {
          await _with(streaming(s, [], (_) {}),
              () => api.download(Uri.parse('https://abc.supabase.co/x'), part, 0, shouldContinue: () => true));
        } on VideoFailure catch (e) {
          return e;
        }
        throw StateError('нет ошибки для $s');
      }

      final e403 = await go(403);
      expect(e403.code, 'ticket');
      expect(e403.retryable, isTrue);
      expect(e403.keepPart, isTrue);
      expect((await go(503)).retryable, isTrue);
      final e404 = await go(404);
      expect(e404.retryable, isFalse);
      expect(e404.code, 'http_404');
    });

    test('shouldContinue=false: пауза, недокачанное остаётся', () async {
      final part = File('${tmp.path}/a.part');
      await expectLater(
        _with(streaming(200, [1, 2, 3], (_) {}),
            () => api.download(Uri.parse('https://abc.supabase.co/x'), part, 0, shouldContinue: () => false)),
        throwsA(isA<VideoFailure>().having((e) => e.code, 'code', 'paused').having((e) => e.keepPart, 'keepPart', true)),
      );
    });

    test('обрыв потока: network, можно повторить', () async {
      final part = File('${tmp.path}/a.part');
      final c = MockClient.streaming((req, _) async => http.StreamedResponse(
            Stream<List<int>>.fromFuture(Future.error(const SocketException('reset'))),
            200,
          ));
      await expectLater(
        _with(c, () => api.download(Uri.parse('https://abc.supabase.co/x'), part, 0, shouldContinue: () => true)),
        throwsA(isA<VideoFailure>().having((e) => e.retryable, 'retryable', true)),
      );
    });
  });
}

void fail_(String m) => throw TestFailure(m);
