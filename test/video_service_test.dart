import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/video/video_api.dart';
import 'package:dry_fog_app/video/video_model.dart';
import 'package:dry_fog_app/video/video_platform.dart';
import 'package:dry_fog_app/video/video_playlist.dart';
import 'package:dry_fog_app/video/video_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = '0f8fad5b-d9cb-469f-a165-70867728950e';
const _b = '1f8fad5b-d9cb-469f-a165-70867728950e';
const _c = '2f8fad5b-d9cb-469f-a165-70867728950e';
const _base = 'https://abc.supabase.co';

class FakePlatform implements VideoPlatform {
  FakePlatform(this.appDir, this.sdRoot, this.filesDirPath);
  final String appDir;
  final String sdRoot;
  final String filesDirPath;
  bool sdPresent = true;
  int? free = 10 * 1024 * 1024 * 1024;
  bool probeOk = true;
  bool deletable = true;
  int probeCalls = 0;

  @override
  Future<List<String>> removableAppDirs() async => sdPresent ? [appDir] : [];
  @override
  Future<List<String>> volumeRoots() async => [sdRoot];
  @override
  Future<int?> freeBytes(String path) async => free;
  @override
  Future<VideoProbe?> probe(String path) async {
    probeCalls++;
    return probeOk ? const VideoProbe(width: 1280, height: 800, durationMs: 5000) : null;
  }

  @override
  Future<Map<String, bool>> canDelete(List<String> paths) async => {for (final p in paths) p: deletable};
  @override
  Future<String?> filesDir() async => filesDirPath;
}

class FakeApi implements VideoApi {
  DesiredResult desired = const DesiredResult.fail('network');
  final Map<String, List<int>> blobs = {};
  final List<List<Map<String, dynamic>>> reports = [];
  final List<int> starts = [];
  int ticketCalls = 0;
  int getCalls = 0;
  bool reportOk = true;

  /// Оборвать скачивание после стольких байт (один раз).
  int? dropAfter;

  /// Обрывать связь на каждой попытке после стольких байт.
  int? alwaysDrop;
  final List<String> ticketOrder = [];

  /// Отдать другое содержимое (для проверки sha256).
  bool corrupt = false;

  @override
  Future<DesiredResult> getDesired(AppConfig cfg) async {
    getCalls++;
    return desired;
  }

  @override
  Future<VideoTicket> ticket(AppConfig cfg, String videoId) async {
    ticketCalls++;
    currentId = videoId;
    ticketOrder.add(videoId);
    final d = desired.set!.items.firstWhere((e) => e.id == videoId);
    return VideoTicket(
      url: Uri.parse('$_base/storage/v1/sign/x?token=SECRET'),
      sha256: d.sha256!,
      sizeBytes: d.sizeBytes,
    );
  }

  String? currentId;

  @override
  Future<void> download(Uri url, File part, int start, {required bool Function() shouldContinue}) async {
    starts.add(start);
    if (alwaysDrop != null) dropAfter = alwaysDrop;
    final data = List<int>.from(blobs[currentId]!);
    if (corrupt) data[0] = (data[0] + 1) & 255;
    final out = data.sublist(start);
    final drop = dropAfter;
    final raf = await part.open(mode: start > 0 ? FileMode.append : FileMode.write);
    try {
      if (drop != null) {
        dropAfter = null;
        await raf.writeFrom(out.sublist(0, drop));
        throw const VideoFailure('network', retryable: true, keepPart: true);
      }
      await raf.writeFrom(out);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<bool> report(AppConfig cfg, List<Map<String, dynamic>> items) async {
    reports.add(items);
    return reportOk;
  }
}

String _sha(List<int> b) => sha256.convert(b).toString();

void main() {
  late Directory tmp;
  late FakePlatform plat;
  late FakeApi api;
  late AppNotifier n;
  late DateTime now;
  late String appDir;
  late Directory vid;

  List<int> bytes(int len, [int seed = 1]) => List.generate(len, (i) => (i * 7 + seed) & 255);

  Map<String, dynamic> upRow(String id, List<int> data, {bool play = true, bool del = false, String created = '2026-11-01T10:00:00Z'}) => {
        'id': id,
        'title': 'v$id',
        'source': 'upload',
        'sha256': _sha(data),
        'size_bytes': data.length,
        'play': play,
        'delete': del,
        'created_at': created,
      };

  Map<String, dynamic> locRow(String id, String name, {bool play = true, bool del = false}) => {
        'id': id,
        'title': name,
        'source': 'sd_local',
        'local_name': name,
        'size_bytes': 5,
        'play': play,
        'delete': del,
        'created_at': '2026-10-01T10:00:00Z',
      };

  File finalFile(String id) => File('$appDir/videos/$id.mp4');
  File partFile(String id) => File('$appDir/videos/$id.part');

  Map<String, dynamic> lastReport(String kind, String key, String value) =>
      api.reports.last.firstWhere((e) => e['kind'] == kind && e[key] == value);

  Future<VideoSyncResult> run() => VideoService.sync();

  setUp(() async {
    VideoService.resetForTest();
    tmp = Directory.systemTemp.createTempSync('video_svc_');
    appDir = '${tmp.path}/app';
    Directory(appDir).createSync();
    vid = Directory('${tmp.path}/sd/vid')..createSync(recursive: true);
    plat = FakePlatform(appDir, '${tmp.path}/sd', '${tmp.path}/files')..free = 10 * 1024 * 1024 * 1024;
    Directory('${tmp.path}/files').createSync();
    api = FakeApi();
    n = AppNotifier()
      ..config = AppConfig(
        cloudEnabled: true,
        cloudUrl: _base,
        cloudAnonKey: 'anon',
        cloudToken: 'SECRET-DEVICE-TOKEN',
        deviceId: 'CARFOG-001',
      );
    n.transition(AppState.standby);
    now = DateTime.utc(2026, 11, 8, 12);
    VideoService.platform = plat;
    VideoService.api = api;
    VideoService.clock = () => now;
    VideoService.sleeper = (_) async {};
    VideoService.reserveBytes = 0;
    await VideoService.init(n);
  });

  tearDown(() {
    VideoService.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  FakeApi f() => api;

  group('скачивание', () {
    test('успех: файл на месте, .part убран, отчёт «есть», видео в плейлисте', () async {
      final data = bytes(5000);
      f().blobs[_a] = data;
      f().desired = DesiredResult.ok(DesiredSet(5, [DesiredVideo.tryParse(upRow(_a, data))!]));
      expect(await run(), VideoSyncResult.done);
      expect(finalFile(_a).existsSync(), isTrue);
      expect(finalFile(_a).lengthSync(), 5000);
      expect(partFile(_a).existsSync(), isFalse);
      expect(f().reports.last, [uploadReportItem(_a, 'present')]);
      final st = VideoPlaylist.state.value;
      expect(st.managed, isTrue);
      expect(st.entries.map((e) => e.id), [_a]);
    });

    test('в отчёте до закачки видно «скачивается»', () async {
      final data = bytes(2000);
      f().blobs[_a] = data;
      serve2(f(), 1, [upRow(_a, data)]);
      await run();
      expect(f().reports.first, [uploadReportItem(_a, 'downloading')]);
      expect(f().reports.last, [uploadReportItem(_a, 'present')]);
    });

    test('нет места: до начала, ни одного запроса ссылки, отчёт failed:no_space', () async {
      final data = bytes(5000);
      f().blobs[_a] = data;
      plat.free = 1000;
      serve2(f(), 1, [upRow(_a, data)]);
      expect(await run(), VideoSyncResult.failed);
      expect(f().ticketCalls, 0);
      expect(finalFile(_a).existsSync(), isFalse);
      expect(partFile(_a).existsSync(), isFalse);
      expect(f().reports.last, [uploadReportItem(_a, 'failed:no_space')]);
      expect(VideoPlaylist.state.value.entries, isEmpty);
    });

    test('запас места учитывается: файл + запас', () async {
      final data = bytes(5000);
      f().blobs[_a] = data;
      VideoService.reserveBytes = 1000;
      plat.free = 5500; // файл влезает, файл + запас — нет
      serve2(f(), 1, [upRow(_a, data)]);
      await run();
      expect(f().ticketCalls, 0);
      expect(f().reports.last, [uploadReportItem(_a, 'failed:no_space')]);
    });

    test('нет карты: failed:no_sd, воспроизведение не страдает', () async {
      final data = bytes(1000);
      f().blobs[_a] = data;
      plat.sdPresent = false;
      serve2(f(), 1, [upRow(_a, data)]);
      await run();
      expect(f().reports.last, [uploadReportItem(_a, 'failed:no_sd')]);
      expect(f().ticketCalls, 0);
    });

    test('обрыв связи: докачка с места обрыва (Range), файл целый', () async {
      final data = bytes(10000);
      f().blobs[_a] = data;
      f().dropAfter = 4000;
      serve2(f(), 1, [upRow(_a, data)]);
      expect(await run(), VideoSyncResult.done);
      expect(f().starts, [0, 4000]);
      expect(finalFile(_a).readAsBytesSync(), data);
      expect(f().ticketCalls, 2); // новая ссылка на каждую попытку
    });

    test('обрывы не кончаются: остаток .part сохраняется для докачки, отчёт failed:network', () async {
      final data = bytes(20000);
      f().blobs[_a] = data;
      f().alwaysDrop = 1000;
      serve2(f(), 1, [upRow(_a, data)]);
      expect(await run(), VideoSyncResult.failed);
      expect(f().reports.last, [uploadReportItem(_a, 'failed:network')]);
      expect(finalFile(_a).existsSync(), isFalse);
      expect(partFile(_a).existsSync(), isTrue); // продолжится по Range
      expect(VideoPlaylist.state.value.entries, isEmpty);
    });

    test('несовпадение sha256: файл удалён, failed:sha256', () async {
      final data = bytes(3000);
      f().blobs[_a] = data;
      f().corrupt = true;
      serve2(f(), 1, [upRow(_a, data)]);
      await run();
      expect(f().reports.last, [uploadReportItem(_a, 'failed:sha256')]);
      expect(finalFile(_a).existsSync(), isFalse);
      expect(partFile(_a).existsSync(), isFalse);
      expect(plat.probeCalls, 0); // дальше sha256 не идём
    });

    test('файл не воспроизводится: удалён, failed:probe, в плейлист не попал', () async {
      final data = bytes(3000);
      f().blobs[_a] = data;
      plat.probeOk = false;
      serve2(f(), 1, [upRow(_a, data)]);
      await run();
      expect(f().reports.last, [uploadReportItem(_a, 'failed:probe')]);
      expect(finalFile(_a).existsSync(), isFalse);
      expect(partFile(_a).existsSync(), isFalse);
      expect(VideoPlaylist.state.value.entries, isEmpty);
    });

    test('сервер отдал файл другого размера: failed:size', () async {
      final data = bytes(3000);
      f().blobs[_a] = data.sublist(0, 2999);
      serve2(f(), 1, [upRow(_a, data)]);
      await run();
      expect(f().reports.last, [uploadReportItem(_a, 'failed:size')]);
      expect(finalFile(_a).existsSync(), isFalse);
    });

    test('после неудачи пауза: до срока ссылку не просим, после — пробуем снова', () async {
      final data = bytes(3000);
      f().blobs[_a] = data;
      plat.probeOk = false;
      serve2(f(), 1, [upRow(_a, data)]);
      await run();
      final t1 = f().ticketCalls;
      plat.probeOk = true;
      await run(); // срок не вышел
      expect(f().ticketCalls, t1);
      expect(f().reports.last, [uploadReportItem(_a, 'failed:probe')]);
      now = now.add(const Duration(minutes: 1));
      expect(await run(), VideoSyncResult.done);
      expect(f().ticketCalls, t1 + 1);
      expect(f().reports.last, [uploadReportItem(_a, 'present')]);
    });

    test('качаем по одному, в порядке даты добавления', () async {
      final d1 = bytes(1500, 1);
      final d2 = bytes(1600, 2);
      f().blobs[_a] = d1;
      f().blobs[_b] = d2;
      serve2(f(), 1, [
        upRow(_a, d1, created: '2026-11-05T00:00:00Z'),
        upRow(_b, d2, created: '2026-11-02T00:00:00Z'),
      ]);
      await run();
      expect(f().ticketOrder, [_b, _a]);
      expect(VideoPlaylist.state.value.entries.map((e) => e.id), [_b, _a]);
    });

    test('пока на экране клиент (не заставка): ничего не качаем, пауза, ничего не ломаем', () async {
      final data = bytes(3000);
      f().blobs[_a] = data;
      n.transition(AppState.selectFlavor);
      serve2(f(), 1, [upRow(_a, data)]);
      expect(await run(), VideoSyncResult.paused);
      expect(f().ticketCalls, 0);
      expect(f().reports.last, [uploadReportItem(_a, 'downloading')]);
      expect(VideoService.diagnostics()['state'], 'paused');
      // Вернулись на заставку — следующий опрос докачивает и без смены rev.
      n.transition(AppState.standby);
      expect(VideoService.shouldSync(1), isFalse); // минута паузы ещё не прошла
      now = now.add(const Duration(minutes: 2));
      expect(VideoService.shouldSync(1), isTrue);
      expect(await run(), VideoSyncResult.done);
    });
  });

  group('набор и проигрывание', () {
    test('смена набора без закачки: файл уже на карте — ссылку не просим', () async {
      final d1 = bytes(1500, 1);
      final d2 = bytes(1600, 2);
      f().blobs[_a] = d1;
      f().blobs[_b] = d2;
      serve2(f(), 1, [upRow(_a, d1), upRow(_b, d2, play: false)]);
      await run();
      expect(VideoPlaylist.state.value.entries.map((e) => e.id), [_a]);
      final tickets = f().ticketCalls;
      serve2(f(), 2, [upRow(_a, d1, play: false), upRow(_b, d2)]);
      await run();
      expect(f().ticketCalls, tickets);
      expect(VideoPlaylist.state.value.entries.map((e) => e.id), [_b]);
    });

    test('ничего не отмечено: набор пустой, но определён облаком', () async {
      final d1 = bytes(1500, 1);
      f().blobs[_a] = d1;
      serve2(f(), 1, [upRow(_a, d1, play: false)]);
      await run();
      final st = VideoPlaylist.state.value;
      expect(st.managed, isTrue);
      expect(st.entries, isEmpty);
      expect(finalFile(_a).existsSync(), isTrue); // скачано и хранится
    });

    test('rev не изменился: ничего не делаем', () async {
      final d1 = bytes(1500, 1);
      f().blobs[_a] = d1;
      serve2(f(), 4, [upRow(_a, d1)]);
      await run();
      expect(VideoService.shouldSync(4), isFalse);
      expect(VideoService.shouldSync(5), isTrue);
      expect(VideoService.shouldSync(null), isFalse); // старый сервер
    });

    test('отчёт при старте и раз в сутки, даже если rev тот же', () async {
      expect(VideoService.shouldSync(0), isTrue); // ещё не отчитывались
      f().desired = DesiredResult.ok(const DesiredSet(0, []));
      await run();
      expect(VideoService.shouldSync(0), isFalse);
      now = now.add(const Duration(hours: 23));
      expect(VideoService.shouldSync(0), isFalse);
      now = now.add(const Duration(hours: 2));
      expect(VideoService.shouldSync(0), isTrue);
    });

    test('облако недоступно: прежний набор не трогаем, повтор позже', () async {
      final d1 = bytes(1500, 1);
      f().blobs[_a] = d1;
      serve2(f(), 1, [upRow(_a, d1)]);
      await run();
      f().desired = const DesiredResult.fail('rate_limited');
      expect(await run(), VideoSyncResult.noDesired);
      expect(VideoPlaylist.state.value.entries.map((e) => e.id), [_a]);
      expect(finalFile(_a).existsSync(), isTrue);
      expect(VideoService.diagnostics()['last_error'], 'get:rate_limited');
    });

    test('после перезапуска без сети набор берётся с диска', () async {
      final d1 = bytes(1500, 1);
      f().blobs[_a] = d1;
      serve2(f(), 1, [upRow(_a, d1)]);
      await run();
      // «Перезапуск»: состояние в памяти сброшено, файлы и videos_state.json на месте.
      VideoPlaylist.reset();
      await VideoService.init(n);
      final st = VideoPlaylist.state.value;
      expect(st.managed, isTrue);
      expect(st.entries.map((e) => e.id), [_a]);
    });

    test('набор ни разу не получен: заставка остаётся в старом режиме', () async {
      expect(VideoPlaylist.state.value.managed, isFalse);
    });

    test('нет облачных настроек: ничего не делаем', () async {
      n.config = AppConfig();
      expect(await run(), VideoSyncResult.noCloud);
      expect(f().getCalls, 0);
    });
  });

  group('удаление', () {
    test('помеченное на удаление скачанное видео удаляется и пропадает из отчёта', () async {
      final d1 = bytes(1500, 1);
      f().blobs[_a] = d1;
      serve2(f(), 1, [upRow(_a, d1)]);
      await run();
      expect(finalFile(_a).existsSync(), isTrue);
      serve2(f(), 2, [upRow(_a, d1, del: true)]);
      await run();
      expect(finalFile(_a).existsSync(), isFalse);
      expect(f().reports.last.where((e) => e['kind'] == 'upload'), isEmpty);
      expect(VideoPlaylist.state.value.entries, isEmpty);
    });

    test('помеченный файл с карты удаляется, если разрешено', () async {
      File('${vid.path}/ручной.mp4').writeAsBytesSync([1, 2, 3, 4, 5]);
      serve2(f(), 1, [locRow(_a, 'ручной.mp4', del: true)]);
      await run();
      expect(File('${vid.path}/ручной.mp4').existsSync(), isFalse);
      expect(f().reports.last.where((e) => e['kind'] == 'local'), isEmpty);
    });

    test('«сирота» в папке приложения (сервер видео не знает) убирается', () async {
      final d1 = bytes(1500, 1);
      f().blobs[_a] = d1;
      Directory('$appDir/videos').createSync(recursive: true);
      finalFile(_b).writeAsBytesSync(bytes(10));
      partFile(_c).writeAsBytesSync(bytes(10));
      File('$appDir/videos/чужое.txt').writeAsStringSync('x');
      serve2(f(), 1, [upRow(_a, d1)]);
      await run();
      expect(finalFile(_b).existsSync(), isFalse);
      expect(partFile(_c).existsSync(), isFalse);
      expect(File('$appDir/videos/чужое.txt').existsSync(), isTrue); // чужие имена не трогаем
    });

    test('пустой набор от сервера не стирает файлы (подозрительный ответ)', () async {
      Directory('$appDir/videos').createSync(recursive: true);
      finalFile(_b).writeAsBytesSync(bytes(10));
      f().desired = DesiredResult.ok(const DesiredSet(9, []));
      await run();
      expect(finalFile(_b).existsSync(), isTrue);
    });

    test('файл неверного размера перекачивается', () async {
      final d1 = bytes(1500, 1);
      f().blobs[_a] = d1;
      Directory('$appDir/videos').createSync(recursive: true);
      finalFile(_a).writeAsBytesSync(bytes(100));
      serve2(f(), 1, [upRow(_a, d1)]);
      await run();
      expect(finalFile(_a).readAsBytesSync(), d1);
    });
  });

  group('файлы, положенные на карту вручную', () {
    test('попадают в отчёт с размером, длительностью и правом удаления; играют сразу', () async {
      File('${vid.path}/a.mp4').writeAsBytesSync([1, 2, 3, 4, 5]);
      File('${vid.path}/заметки.txt').writeAsStringSync('не видео');
      f().desired = DesiredResult.ok(const DesiredSet(1, []));
      await run();
      final locals = f().reports.last.where((e) => e['kind'] == 'local').toList();
      expect(locals.length, 1);
      expect(locals.first['local_name'], 'a.mp4');
      expect(locals.first['size_bytes'], 5);
      expect(locals.first['width'], 1280);
      expect(locals.first['deletable'], isTrue);
      // Сервер ещё не завёл строку — файл всё равно играет (как до обновления).
      expect(VideoPlaylist.state.value.entries.map((e) => e.id), ['local:a.mp4']);
    });

    test('Android не даёт удалить: deletable=false уходит в отчёт', () async {
      File('${vid.path}/a.mp4').writeAsBytesSync([1, 2, 3, 4, 5]);
      plat.deletable = false;
      f().desired = DesiredResult.ok(const DesiredSet(1, []));
      await run();
      expect(lastReport('local', 'local_name', 'a.mp4')['deletable'], isFalse);
    });

    test('снятая в портале галочка: файл остаётся на карте, но не играет', () async {
      File('${vid.path}/a.mp4').writeAsBytesSync([1, 2, 3, 4, 5]);
      serve2(f(), 2, [locRow(_a, 'a.mp4', play: false)]);
      await run();
      expect(File('${vid.path}/a.mp4').existsSync(), isTrue);
      expect(VideoPlaylist.state.value.managed, isTrue);
      expect(VideoPlaylist.state.value.entries, isEmpty);
    });

    test('проверка кадра для ручных файлов кэшируется', () async {
      File('${vid.path}/a.mp4').writeAsBytesSync([1, 2, 3, 4, 5]);
      f().desired = DesiredResult.ok(const DesiredSet(1, []));
      await run();
      final calls = plat.probeCalls;
      await run();
      expect(plat.probeCalls, calls);
    });
  });

  group('отчёт и диагностика', () {
    test('отчёт не принят: повтор в ближайший опрос', () async {
      f().reportOk = false;
      f().desired = DesiredResult.ok(const DesiredSet(1, []));
      await run();
      expect(VideoService.diagnostics()['last_error'], 'report');
      now = now.add(const Duration(minutes: 2));
      expect(VideoService.shouldSync(1), isTrue);
    });

    test('блок videos: число, состояние, место, ошибка — без ссылок и токенов', () async {
      final d1 = bytes(1500, 1);
      f().blobs[_a] = d1;
      plat.probeOk = false;
      serve2(f(), 3, [upRow(_a, d1)]);
      await run();
      final dg = VideoService.diagnostics();
      expect(dg['rev'], 3);
      expect(dg['desired_uploads'], 1);
      expect(dg['sd_present'], isTrue);
      expect(dg['free_bytes'], isNotNull);
      expect((dg['failed'] as Map)[_a], 'probe');
      final text = jsonEncode(dg);
      expect(text.contains('SECRET'), isFalse);
      expect(text.contains('http'), isFalse);
      expect(text.contains(_base), isFalse);
    });
  });
}

void serve2(FakeApi api, int rev, List<Map<String, dynamic>> rows) {
  api.desired = DesiredResult.ok(DesiredSet.tryParse({'ok': true, 'videos_rev': rev, 'videos': rows})!);
}
