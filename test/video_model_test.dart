import 'package:dry_fog_app/video/video_model.dart';
import 'package:dry_fog_app/video/video_playlist.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = '0f8fad5b-d9cb-469f-a165-70867728950e';
const _b = '1f8fad5b-d9cb-469f-a165-70867728950e';
const _c = '2f8fad5b-d9cb-469f-a165-70867728950e';
final _sha = 'a' * 64;

Map<String, dynamic> up(String id, {String created = '2026-11-01T10:00:00Z', bool play = true, bool del = false}) => {
      'id': id,
      'title': 't$id',
      'source': 'upload',
      'sha256': _sha,
      'size_bytes': 1000,
      'play': play,
      'delete': del,
      'created_at': created,
    };

Map<String, dynamic> loc(String id, String name, {bool play = true, bool del = false, String created = '2026-10-01T10:00:00Z'}) => {
      'id': id,
      'title': name,
      'source': 'sd_local',
      'local_name': name,
      'size_bytes': 5,
      'play': play,
      'delete': del,
      'created_at': created,
    };

DesiredVideo d(Map<String, dynamic> m) => DesiredVideo.tryParse(m)!;

LocalVideoFile lf(String name, {DateTime? at}) => LocalVideoFile(
      name: name,
      path: '/sd/vid/$name',
      sizeBytes: 5,
      modified: at ?? DateTime.utc(2026, 1, 1),
    );

void main() {
  group('разбор ответа device_videos_get', () {
    test('верный ответ', () {
      final s = DesiredSet.tryParse({
        'ok': true,
        'videos_rev': 7,
        'videos': [up(_a), loc(_b, 'a.mp4')],
      })!;
      expect(s.rev, 7);
      expect(s.items.length, 2);
      expect(s.items[0].isUpload, isTrue);
      expect(s.items[1].localName, 'a.mp4');
    });

    test('мусор и отказ — null; плохие строки пропускаются, остальные живут', () {
      expect(DesiredSet.tryParse(null), isNull);
      expect(DesiredSet.tryParse({'ok': false, 'error': 'auth'}), isNull);
      expect(DesiredSet.tryParse({'ok': true, 'videos': []}), isNull); // нет rev
      expect(DesiredSet.tryParse({'ok': true, 'videos_rev': 1, 'videos': 'x'}), isNull);
      final s = DesiredSet.tryParse({
        'ok': true,
        'videos_rev': 1,
        'videos': [
          up(_a),
          {'id': 'x', 'source': 'upload'},
          {...up(_b), 'sha256': 'zz'},
          {...up(_c), 'size_bytes': 0},
          loc(_c, '../etc/passwd'),
          loc(_c, 'a/b.mp4'),
          up(_a), // повтор id
          5,
          null,
        ],
      })!;
      expect(s.items.map((e) => e.id), [_a]);
    });

    test('туда и обратно через toJson (сохранённое состояние)', () {
      final s = DesiredSet.tryParse({
        'ok': true,
        'videos_rev': 3,
        'videos': [up(_a), loc(_b, 'a.mp4', play: false)],
      })!;
      final j = {...s.toJson(), 'ok': true};
      final s2 = DesiredSet.tryParse(j)!;
      expect(s2.rev, 3);
      expect(s2.items.map((e) => e.id), [_a, _b]);
      expect(s2.items[1].play, isFalse);
    });

    test('videos_rev из device_poll', () {
      expect(parsePollVideosRev({'videos_rev': 4}), 4);
      expect(parsePollVideosRev({}), isNull);
      expect(parsePollVideosRev({'videos_rev': 'x'}), isNull);
      expect(parsePollVideosRev({'videos_rev': -1}), isNull);
    });

    test('безопасные имена файлов', () {
      expect(isSafeLocalName('a.mp4'), isTrue);
      expect(isSafeLocalName('../a.mp4'), isFalse);
      expect(isSafeLocalName('a/b'), isFalse);
      expect(isSafeLocalName('..'), isFalse);
      expect(isSafeLocalName(''), isFalse);
      expect(isSafeLocalName(null), isFalse);
      expect(isSafeLocalName('a' * 256), isFalse);
    });
  });

  group('что играть', () {
    test('отмеченные и присутствующие — в порядке даты добавления', () {
      final desired = [
        d(up(_a, created: '2026-11-03T00:00:00Z')),
        d(up(_b, created: '2026-11-01T00:00:00Z')),
        d(up(_c, created: '2026-11-02T00:00:00Z')),
      ];
      final p = buildPlaylist(
        desired: desired,
        uploadPaths: {_a: '/v/a.mp4', _b: '/v/b.mp4', _c: '/v/c.mp4'},
        localFiles: {},
      );
      expect(p.map((e) => e.id), [_b, _c, _a]);
    });

    test('не отмеченные, помеченные на удаление и отсутствующие не играют', () {
      final desired = [
        d(up(_a, play: false)),
        d(up(_b, del: true)),
        d(up(_c)),
      ];
      final p = buildPlaylist(desired: desired, uploadPaths: {_a: '/a', _b: '/b'}, localFiles: {});
      expect(p, isEmpty); // _c не скачан
    });

    test('пустой набор — пустой плейлист', () {
      expect(buildPlaylist(desired: [], uploadPaths: {}, localFiles: {}), isEmpty);
    });

    test('файл с карты: по галочке; снятая галочка — не играет', () {
      final files = {'a.mp4': lf('a.mp4'), 'b.mp4': lf('b.mp4')};
      final p = buildPlaylist(
        desired: [d(loc(_a, 'a.mp4')), d(loc(_b, 'b.mp4', play: false))],
        uploadPaths: {},
        localFiles: files,
      );
      expect(p.map((e) => e.path), ['/sd/vid/a.mp4']);
    });

    test('неизвестные серверу файлы с карты играют (как до обновления)', () {
      final p = buildPlaylist(
        desired: [],
        uploadPaths: {},
        localFiles: {'x.mp4': lf('x.mp4')},
      );
      expect(p.map((e) => e.id), ['local:x.mp4']);
    });

    test('загруженное и с карты вперемешку — по дате', () {
      final p = buildPlaylist(
        desired: [d(up(_a, created: '2026-11-05T00:00:00Z')), d(loc(_b, 'a.mp4', created: '2026-10-01T00:00:00Z'))],
        uploadPaths: {_a: '/v/a.mp4'},
        localFiles: {'a.mp4': lf('a.mp4')},
      );
      expect(p.map((e) => e.id), [_b, _a]);
    });
  });

  group('переход к следующему ролику', () {
    test('по кругу', () {
      expect(nextAfter(['a', 'b', 'c'], 'a'), 'b');
      expect(nextAfter(['a', 'b', 'c'], 'c'), 'a');
      expect(nextAfter(['a'], 'a'), 'a');
    });
    test('нет текущего в новом наборе — первый; пустой набор — null', () {
      expect(nextAfter(['x', 'y'], 'gone'), 'x');
      expect(nextAfter(['x', 'y'], null), 'x');
      expect(nextAfter([], 'a'), isNull);
    });
  });

  group('отчёт', () {
    test('failed: только безопасные знаки и ≤ 60', () {
      expect(failedState('no_space'), 'failed:no_space');
      expect(failedState("a'b;c"), 'failed:a_b_c');
      expect(failedState(''), 'failed:unknown');
      expect(failedState('x' * 100).length, 'failed:'.length + 60);
    });

    test('элементы отчёта', () {
      expect(uploadReportItem(_a, 'present'), {'kind': 'upload', 'id': _a, 'state': 'present'});
      final m = localReportItem(lf('a.mp4').withInfo(width: 1280, height: 800, durationMs: 5000, deletable: true));
      expect(m['kind'], 'local');
      expect(m['local_name'], 'a.mp4');
      expect(m['width'], 1280);
      expect(m['deletable'], isTrue);
      expect(localReportItem(lf('b.mp4')).containsKey('width'), isFalse);
    });

    test('не больше 200: файлы с карты обрезаются первыми', () {
      final u = List.generate(150, (i) => uploadReportItem('u$i', 'present'));
      final l = List.generate(100, (i) => {'kind': 'local', 'local_name': 'f$i'});
      final r = capReport(u, l);
      expect(r.length, 200);
      expect(r.where((e) => e['kind'] == 'upload').length, 150);
    });
  });

  group('VideoPlaylist', () {
    setUp(VideoPlaylist.reset);
    test('одинаковый набор слушателей не будит', () {
      var n = 0;
      void l() => n++;
      VideoPlaylist.state.addListener(l);
      final e = [PlaylistEntry(id: _a, path: '/a', addedAt: DateTime.utc(2026))];
      VideoPlaylist.publish(managed: true, entries: e);
      VideoPlaylist.publish(managed: true, entries: List.of(e));
      expect(n, 1);
      VideoPlaylist.publish(managed: true, entries: const []);
      expect(n, 2);
      VideoPlaylist.state.removeListener(l);
    });
    test('по умолчанию набор не определён (старое поведение заставки)', () {
      expect(VideoPlaylist.state.value.managed, isFalse);
    });
  });
}
