import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../models/app_state.dart';
import '../services/app_log_service.dart';
import 'video_api.dart';
import 'video_model.dart';
import 'video_platform.dart';
import 'video_playlist.dart';

/// Итог одного прохода синхронизации (для журнала и тестов).
enum VideoSyncResult { skipped, noCloud, noDesired, done, paused, failed }

class _ItemFailure {
  _ItemFailure(this.reason, this.count, this.nextAt);
  final String reason;
  final int count;
  final DateTime nextAt;
}

/// Видео заставки через портал (VIDEO1, ТЗ раздел 4).
///
/// Хранение: новые видео — в `СЪЁМНЫЙ_ТОМ/Android/data/ПАКЕТ/files/videos/
/// ID.mp4` (своя папка приложения: права на запись не нужны, ручные файлы
/// не смешиваются). Скачивание во временный `ID.part`, потом проверка
/// размера, sha256 и воспроизводимости, потом атомарное переименование.
///
/// Приоритет. Скачивание идёт только пока аппарат на заставке
/// (`AppState.standby`): пришёл клиент — загрузка встаёт на паузу (недокачанное
/// остаётся и продолжится по Range), чтобы не мешать оплате и циклу
/// (диск, процессор, связь). Хеширование и проверка кадра — тоже только на
/// заставке. Опрос облака (device_poll) от этого не зависит.
///
/// Любой сбой оставляет проигрывание нетронутым: набор для заставки строится
/// из того, что реально лежит на карте и проверено.
class VideoService {
  VideoService._();

  // ---------------- подменяемые части (для тестов) ----------------

  static VideoPlatform platform = const ChannelVideoPlatform();
  static VideoApi api = const HttpVideoApi();
  static DateTime Function() clock = DateTime.now;

  /// Можно ли сейчас качать (не мешаем обслуживанию клиента).
  static bool Function() canRun = _defaultCanRun;

  /// Пауза между попытками внутри одной загрузки (ссылку нельзя просить
  /// чаще раза в 10 с, поэтому база 12 с).
  static Future<void> Function(Duration d) sleeper = (d) => Future<void>.delayed(d);

  static Future<String> Function(File f) hasher = _sha256Of;

  /// Запас свободного места сверх размера файла.
  static int reserveBytes = 256 * 1024 * 1024;

  static const int maxAttempts = 5;
  static const Duration attemptBackoff = Duration(seconds: 12);
  static const Duration minRetryPause = Duration(seconds: 30);
  static const Duration maxRetryPause = Duration(minutes: 15);
  static const Duration reportEvery = Duration(hours: 24);
  static const int maxProbesPerPass = 40;

  // ---------------- состояние ----------------

  static AppNotifier? _notifier;
  static File? _stateFile;
  static bool _busy = false;
  static DesiredSet? _desired;
  static int? _lastRev;
  static DateTime? _lastReportAt;
  static DateTime? _lastSyncAt;
  static String? _lastError;
  static String _state = 'idle'; // idle | syncing | paused
  static bool _pendingWork = false;
  static DateTime? _nextTry;
  static String? _currentId; // что качается прямо сейчас
  static final Map<String, _ItemFailure> _failures = {};
  static final Map<String, VideoProbe?> _probeCache = {};
  static int? _freeBytes;
  static bool _sdPresent = false;

  static bool _defaultCanRun() => _notifier?.state == AppState.standby;

  /// Блок `videos` пакета удалённой диагностики: без ссылок и токенов.
  static Map<String, dynamic> diagnostics() {
    final d = _desired;
    final uploads = d?.items.where((e) => e.isUpload && !e.delete).toList() ?? const [];
    return {
      'rev': _lastRev,
      'state': _state,
      'sd_present': _sdPresent,
      'free_bytes': _freeBytes,
      'downloading': _currentId,
      'desired_total': d?.items.length ?? 0,
      'desired_uploads': uploads.length,
      'playing': VideoPlaylist.state.value.entries.length,
      'managed': VideoPlaylist.state.value.managed,
      'failed': {for (final e in _failures.entries) e.key: e.value.reason},
      'last_error': _lastError,
      'last_sync_at': _lastSyncAt?.toUtc().toIso8601String(),
      'last_report_at': _lastReportAt?.toUtc().toIso8601String(),
    };
  }

  // ---------------- запуск ----------------

  /// Один раз при старте: читает сохранённый набор и публикует плейлист из
  /// того, что лежит на карте. Работает и без сети.
  static Future<void> init(AppNotifier notifier) async {
    _notifier = notifier;
    _busy = false;
    _desired = null;
    _lastRev = null;
    _lastReportAt = null;
    _failures.clear();
    final dir = await platform.filesDir();
    _stateFile = dir == null ? null : File('$dir/videos_state.json');
    await _loadState();
    try {
      await _refreshPlaylist();
    } catch (e) {
      AppLog.log('Video', 'init: ${e.runtimeType}');
    }
  }

  static Future<void> _loadState() async {
    final f = _stateFile;
    if (f == null) return;
    try {
      if (!f.existsSync()) return;
      final set = DesiredSet.tryParse({...jsonDecode(await f.readAsString()) as Map, 'ok': true});
      if (set == null) return;
      _desired = set;
      _lastRev = set.rev;
    } catch (_) {
      // Повреждённый файл — как будто набора нет: заставка играет по-старому.
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }

  static Future<void> _saveState(DesiredSet set) async {
    final f = _stateFile;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(set.toJson()), flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      AppLog.log('Video', 'state: ${e.runtimeType}');
    }
  }

  // ---------------- опрос облака ----------------

  /// Вызывается после штатного ответа device_poll. [rev] null — поля нет
  /// (старый сервер): ничего не делать, кроме суточного отчёта.
  static void onPoll(int? rev) {
    if (_notifier == null) return;
    if (!shouldSync(rev)) return;
    unawaited(sync().catchError((Object e) {
      AppLog.log('Video', 'sync: ${e.runtimeType}');
      return VideoSyncResult.failed;
    }));
  }

  @visibleForTesting
  static bool shouldSync(int? rev) {
    if (_busy) return false;
    final now = clock();
    if (rev != null && rev != _lastRev) return true;
    // Отчёт при старте (ещё не было) и раз в сутки.
    final last = _lastReportAt;
    if (rev != null && (last == null || now.difference(last) >= reportEvery)) return true;
    if (_pendingWork) {
      final n = _nextTry;
      return n == null || !now.isBefore(n);
    }
    return false;
  }

  // ---------------- проход синхронизации ----------------

  static Future<VideoSyncResult> sync() async {
    if (_busy) return VideoSyncResult.skipped;
    final n = _notifier;
    if (n == null) return VideoSyncResult.skipped;
    final cfg = n.config;
    if (!cfg.cloudEnabled || cfg.cloudUrl.isEmpty || cfg.cloudToken.isEmpty) {
      return VideoSyncResult.noCloud;
    }
    _busy = true;
    _state = 'syncing';
    try {
      return await _syncOnce(cfg);
    } finally {
      _busy = false;
      if (_state == 'syncing') _state = 'idle';
      _currentId = null;
    }
  }

  static Future<VideoSyncResult> _syncOnce(AppConfig cfg) async {
    final now = clock();
    _lastSyncAt = now;
    final got = await api.getDesired(cfg);
    final set = got.set;
    if (set == null) {
      _lastError = 'get:${got.error}';
      _pendingWork = true;
      _nextTry = now.add(minRetryPause);
      return VideoSyncResult.noDesired;
    }
    _desired = set;
    await _saveState(set);
    _failures.removeWhere((id, _) => !set.items.any((d) => d.id == id));

    final dir = await _videoDir();
    _sdPresent = dir != null;
    var local = await _scanLocal();

    // 1. Удаление помеченного и уборка того, чего сервер уже не знает.
    if (dir != null) await _cleanApp(dir, set);
    local = await _deleteLocals(set, local);

    // 2. Плейлист — сразу: смена галочек не ждёт закачек.
    await _refreshPlaylist(local: local);

    // 3. Скачивание недостающего, по одному.
    var paused = false;
    var retryable = false;
    final todo = set.items.where((d) => d.isUpload && !d.delete && !_isPresent(dir, d)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    // Портал сразу видит «Скачивается» (до первой закачки).
    final eligible = todo.where((d) {
      final f = _failures[d.id];
      return f == null || !now.isBefore(f.nextAt);
    });
    if (eligible.isNotEmpty && canRun()) {
      await _sendReport(set, dir, local, downloadingId: eligible.first.id);
    }
    for (final item in todo) {
      final f = _failures[item.id];
      if (f != null && now.isBefore(f.nextAt)) {
        retryable = true;
        continue; // пауза после неудачи этого же видео
      }
      if (!canRun()) {
        paused = true;
        break;
      }
      _currentId = item.id;
      try {
        if (dir == null) throw const VideoFailure('no_sd');
        await _download(cfg, dir, item);
        _failures.remove(item.id);
        _lastError = null;
        await _refreshPlaylist(local: local);
      } on VideoFailure catch (e) {
        if (e.code == 'paused') {
          paused = true;
          break;
        }
        final count = (_failures[item.id]?.count ?? 0) + 1;
        _failures[item.id] = _ItemFailure(e.code, count, clock().add(_backoff(count)));
        _lastError = '${item.id.substring(0, 8)}:${e.code}';
        retryable = true;
        AppLog.log('Video', 'загрузка ${item.id.substring(0, 8)} не удалась: ${e.code}');
      } finally {
        _currentId = null;
      }
    }
    if (paused) _state = 'paused';

    // 4. Отчёт: фактическое состояние.
    final reported = await _sendReport(set, dir, local);
    _lastRev = set.rev;
    _pendingWork = paused || retryable || !reported;
    _nextTry = paused || !reported ? clock().add(const Duration(minutes: 1)) : _earliestRetry();
    await _refreshPlaylist(local: local);
    return paused ? VideoSyncResult.paused : (_failures.isEmpty && reported ? VideoSyncResult.done : VideoSyncResult.failed);
  }

  static Duration _backoff(int count) {
    var d = minRetryPause * (1 << (count - 1).clamp(0, 10));
    if (d > maxRetryPause) d = maxRetryPause;
    return d;
  }

  static DateTime? _earliestRetry() {
    DateTime? best;
    for (final f in _failures.values) {
      if (best == null || f.nextAt.isBefore(best)) best = f.nextAt;
    }
    return best;
  }

  // ---------------- файлы ----------------

  static Future<String?> _videoDir() async {
    final dirs = await platform.removableAppDirs();
    if (dirs.isEmpty) return null;
    final d = Directory('${dirs.first}/videos');
    try {
      if (!d.existsSync()) d.createSync(recursive: true);
    } catch (e) {
      AppLog.log('Video', 'папка: ${e.runtimeType}');
      return null;
    }
    _freeBytes = await platform.freeBytes(d.path);
    return d.path;
  }

  static String _finalPath(String dir, String id) => '$dir/$id.mp4';
  static String _partPath(String dir, String id) => '$dir/$id.part';

  static bool _isPresent(String? dir, DesiredVideo d) {
    if (dir == null) return false;
    final f = File(_finalPath(dir, d.id));
    try {
      return f.existsSync() && f.lengthSync() == d.sizeBytes;
    } catch (_) {
      return false;
    }
  }

  /// Удаляет файлы, которым место не здесь: помеченные на удаление, а также
  /// «сирот» в папке приложения (видео, которого сервер больше не знает) и
  /// файлы неверного размера. Трогает ТОЛЬКО свои имена `<uuid>.mp4/.part`.
  static Future<void> _cleanApp(String dir, DesiredSet set) async {
    final byId = {for (final d in set.items) d.id: d};
    try {
      for (final e in Directory(dir).listSync()) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final m = RegExp(r'^([0-9a-f-]{36})\.(mp4|part)$').firstMatch(name);
        if (m == null || !isVideoId(m.group(1))) continue;
        final d = byId[m.group(1)];
        var remove = false;
        if (d == null) {
          // «Сирота»: сервер такого видео больше не знает. Пустой набор —
          // подозрительный ответ (например, восстановление базы): ничего
          // не стираем.
          remove = byId.isNotEmpty;
        } else if (!d.isUpload || d.delete) {
          remove = true;
        } else if (m.group(2) == 'mp4' && e.lengthSync() != d.sizeBytes) {
          remove = true; // повреждён или другой файл — перекачать
        } else if (m.group(2) == 'part' && _isPresent(dir, d)) {
          remove = true; // готовый файл уже есть, остаток не нужен
        }
        if (remove) {
          try {
            e.deleteSync();
          } catch (err) {
            AppLog.log('Video', 'удаление: ${err.runtimeType}');
            _lastError = 'delete';
          }
        }
      }
    } catch (e) {
      AppLog.log('Video', 'уборка: ${e.runtimeType}');
    }
  }

  /// Удаляет файлы с карты, помеченные в портале. Возвращает свежий список.
  static Future<Map<String, LocalVideoFile>> _deleteLocals(
    DesiredSet set,
    Map<String, LocalVideoFile> local,
  ) async {
    var changed = false;
    for (final d in set.items) {
      if (d.isUpload || !d.delete || d.localName == null) continue;
      final f = local[d.localName];
      if (f == null) continue; // уже нет — сервер закроет по отчёту
      try {
        File(f.path).deleteSync();
        changed = true;
      } catch (e) {
        AppLog.log('Video', 'удаление файла с карты: ${e.runtimeType}');
        _lastError = 'delete_local';
      }
    }
    return changed ? await _scanLocal() : local;
  }

  /// Ручные файлы (папка `vid`), как их искала заставка и раньше: первая
  /// папка, где есть файлы.
  static Future<Map<String, LocalVideoFile>> _scanLocal() async {
    final roots = await platform.volumeRoots();
    final candidates = <String>[
      ...roots.map((r) => '$r/vid'),
      '/storage/emulated/0/vid',
      '/storage/self/primary/vid',
    ];
    for (final path in candidates) {
      try {
        final dir = Directory(path);
        if (!dir.existsSync()) continue;
        final out = <String, LocalVideoFile>{};
        for (final e in dir.listSync()) {
          if (e is! File) continue;
          final name = e.uri.pathSegments.last;
          if (!isPlayableName(name) || !isSafeLocalName(name)) continue;
          final st = e.statSync();
          out[name] = LocalVideoFile(
            name: name,
            path: e.path,
            sizeBytes: st.size,
            modified: st.modified,
          );
        }
        if (out.isNotEmpty) return out;
      } catch (_) {
        // карту вынули на ходу — пробуем следующий путь
      }
    }
    return {};
  }

  static Future<void> _refreshPlaylist({Map<String, LocalVideoFile>? local}) async {
    final set = _desired;
    if (set == null) {
      // Набор от облака ещё не получен — старое поведение заставки.
      VideoPlaylist.publish(managed: false, entries: const []);
      return;
    }
    final dir = await _videoDirQuiet();
    final files = local ?? await _scanLocal();
    final uploads = <String, String>{
      for (final d in set.items)
        if (d.isUpload && _isPresent(dir, d)) d.id: _finalPath(dir!, d.id),
    };
    VideoPlaylist.publish(
      managed: true,
      entries: buildPlaylist(desired: set.items, uploadPaths: uploads, localFiles: files),
    );
  }

  /// Как [_videoDir], но без создания папки и запроса места.
  static Future<String?> _videoDirQuiet() async {
    final dirs = await platform.removableAppDirs();
    return dirs.isEmpty ? null : '${dirs.first}/videos';
  }

  // ---------------- скачивание ----------------

  static Future<void> _download(AppConfig cfg, String dir, DesiredVideo item) async {
    final part = File(_partPath(dir, item.id));
    final fin = File(_finalPath(dir, item.id));
    try {
      var have = part.existsSync() ? part.lengthSync() : 0;
      if (have > item.sizeBytes) {
        part.deleteSync();
        have = 0;
      }

      // Место проверяем ДО начала: остаток файла + запас.
      final free = await platform.freeBytes(dir);
      if (free == null) throw const VideoFailure('io');
      _freeBytes = free;
      if (free < item.sizeBytes - have + reserveBytes) {
        throw const VideoFailure('no_space');
      }

      for (var attempt = 1;; attempt++) {
        if (!canRun()) throw const VideoFailure('paused', keepPart: true);
        try {
          final ticket = await api.ticket(cfg, item.id);
          if (ticket.sizeBytes != item.sizeBytes ||
              ticket.sha256 != item.sha256) {
            throw const VideoFailure('size');
          }
          final start = part.existsSync() ? part.lengthSync() : 0;
          await api.download(ticket.url, part, start, shouldContinue: canRun);
          break;
        } on VideoFailure catch (e) {
          if (!e.retryable || attempt >= maxAttempts) {
            throw e.code == 'ticket' || e.code == 'network'
                ? VideoFailure(e.code, keepPart: true)
                : e;
          }
          await sleeper(attemptBackoff * attempt);
        }
      }

      // Проверки: размер, sha256, воспроизводимость.
      if (part.lengthSync() != item.sizeBytes) throw const VideoFailure('size');
      final sha = await hasher(part);
      if (sha != item.sha256) throw const VideoFailure('sha256');
      final probe = await platform.probe(part.path);
      if (probe == null || probe.width < 1 || probe.height < 1 || probe.durationMs < 1) {
        throw const VideoFailure('probe');
      }
      await part.rename(fin.path); // атомарно: в той же папке
    } on VideoFailure catch (e) {
      // Любая ошибка — недокачанное и негодное удаляется; кроме обрыва
      // связи и паузы: там остаток нужен для докачки по Range.
      if (!e.keepPart) _tryDelete(part);
      rethrow;
    } on FileSystemException catch (e) {
      _tryDelete(part);
      throw VideoFailure(e.osError?.errorCode == 28 ? 'no_space' : 'io');
    }
  }

  static void _tryDelete(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  static Future<String> _sha256Of(File f) async {
    final digest = await sha256.bind(f.openRead()).first;
    return digest.toString();
  }

  // ---------------- отчёт ----------------

  static Future<bool> _sendReport(
    DesiredSet set,
    String? dir,
    Map<String, LocalVideoFile> local, {
    String? downloadingId,
  }) async {
    final cfg = _notifier?.config;
    if (cfg == null) return false;
    final uploads = <Map<String, dynamic>>[];
    for (final d in set.items) {
      if (!d.isUpload || d.delete) continue;
      final String state;
      if (_isPresent(dir, d)) {
        state = 'present';
      } else if (downloadingId == d.id) {
        state = 'downloading';
      } else if (_failures[d.id] != null) {
        state = failedState(_failures[d.id]!.reason);
      } else {
        state = 'downloading'; // ждёт своей очереди
      }
      uploads.add(uploadReportItem(d.id, state));
    }

    // Ручные файлы: размеры, длительность, право на удаление.
    final names = local.keys.toList()..sort();
    final deletable = await platform.canDelete(names.map((n) => local[n]!.path).toList());
    var probes = 0;
    final locals = <Map<String, dynamic>>[];
    for (final name in names) {
      var f = local[name]!;
      final key = '${f.path}|${f.sizeBytes}|${f.modified.millisecondsSinceEpoch}';
      if (!_probeCache.containsKey(key) && probes < maxProbesPerPass && canRun()) {
        probes++;
        _probeCache[key] = await platform.probe(f.path);
      }
      final p = _probeCache[key];
      f = f.withInfo(
        width: p?.width,
        height: p?.height,
        durationMs: p?.durationMs,
        deletable: deletable[f.path] ?? false,
      );
      locals.add(localReportItem(f));
    }

    final ok = await api.report(cfg, capReport(uploads, locals));
    if (ok) {
      _lastReportAt = clock();
    } else {
      _lastError = 'report';
    }
    return ok;
  }

  @visibleForTesting
  static void resetForTest() {
    _notifier = null;
    _stateFile = null;
    _busy = false;
    _desired = null;
    _lastRev = null;
    _lastReportAt = null;
    _lastSyncAt = null;
    _lastError = null;
    _state = 'idle';
    _pendingWork = false;
    _nextTry = null;
    _currentId = null;
    _failures.clear();
    _probeCache.clear();
    _freeBytes = null;
    _sdPresent = false;
    platform = const ChannelVideoPlatform();
    api = const HttpVideoApi();
    clock = DateTime.now;
    canRun = _defaultCanRun;
    sleeper = (d) => Future<void>.delayed(d);
    hasher = _sha256Of;
    reserveBytes = 256 * 1024 * 1024;
    VideoPlaylist.reset();
  }

  @visibleForTesting
  static void attachForTest(AppNotifier n) => _notifier = n;
}
