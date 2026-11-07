import 'package:flutter/foundation.dart';

/// Модель и чистая логика плейлиста видео заставки (VIDEO1, ТЗ раздел 4).
/// Без сети и файлов — проверяется обычными тестами.

final RegExp _uuidRe = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final RegExp _sha256Re = RegExp(r'^[0-9a-fA-F]{64}$');

bool isVideoId(Object? v) => v is String && _uuidRe.hasMatch(v);

/// Имя файла на карте — только имя, без путей. Защита от `../` и подмены
/// пути ответом сервера.
bool isSafeLocalName(String? n) {
  if (n == null || n.isEmpty || n.length > 255) return false;
  if (n == '.' || n == '..') return false;
  return !n.contains('/') && !n.contains('\\') && !n.contains('\u0000');
}

/// Расширения, которые заставка и раньше брала с карты.
bool isPlayableName(String name) {
  final p = name.toLowerCase();
  return p.endsWith('.mp4') || p.endsWith('.mkv') || p.endsWith('.webm');
}

/// Строка желаемого состояния из `device_videos_get`.
@immutable
class DesiredVideo {
  const DesiredVideo({
    required this.id,
    required this.title,
    required this.isUpload,
    required this.localName,
    required this.sha256,
    required this.sizeBytes,
    required this.play,
    required this.delete,
    required this.createdAt,
  });

  final String id;
  final String title;

  /// true — загружено через портал (файл в папке приложения), false — файл
  /// с карты (`sd_local`, лежит в `vid`).
  final bool isUpload;
  final String? localName;
  final String? sha256;
  final int sizeBytes;
  final bool play;
  final bool delete;
  final DateTime createdAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'source': isUpload ? 'upload' : 'sd_local',
        'local_name': localName,
        'sha256': sha256,
        'size_bytes': sizeBytes,
        'play': play,
        'delete': delete,
        'created_at': createdAt.toUtc().toIso8601String(),
      };

  /// null — строка негодная (пропускается, остальные работают).
  static DesiredVideo? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (!isVideoId(id)) return null;
    final source = raw['source'];
    if (source != 'upload' && source != 'sd_local') return null;
    final upload = source == 'upload';
    final size = raw['size_bytes'];
    final sizeBytes = size is num && size >= 0 ? size.toInt() : 0;
    final sha = raw['sha256'];
    final name = raw['local_name'];
    if (upload) {
      if (sha is! String || !_sha256Re.hasMatch(sha)) return null;
      if (sizeBytes < 1) return null;
    } else {
      if (name is! String || !isSafeLocalName(name)) return null;
    }
    final created = raw['created_at'];
    return DesiredVideo(
      id: (id as String).toLowerCase(),
      title: raw['title'] is String ? raw['title'] as String : '',
      isUpload: upload,
      localName: name is String ? name : null,
      sha256: sha is String ? sha.toLowerCase() : null,
      sizeBytes: sizeBytes,
      play: raw['play'] == true,
      delete: raw['delete'] == true,
      createdAt: (created is String ? DateTime.tryParse(created) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// Ответ `device_videos_get`: версия и набор.
@immutable
class DesiredSet {
  const DesiredSet(this.rev, this.items);
  final int rev;
  final List<DesiredVideo> items;

  Map<String, dynamic> toJson() => {
        'rev': rev,
        'items': items.map((e) => e.toJson()).toList(),
      };

  /// null — ответ не по форме. Не-ok ответы разбирает вызывающий код.
  static DesiredSet? tryParse(Object? body) {
    if (body is! Map || body['ok'] != true) return null;
    final rev = body['videos_rev'] ?? body['rev'];
    if (rev is! num) return null;
    final list = body['videos'] ?? body['items'];
    if (list is! List) return null;
    final seen = <String>{};
    final items = <DesiredVideo>[];
    for (final x in list) {
      final v = DesiredVideo.tryParse(x);
      if (v != null && seen.add(v.id)) items.add(v);
    }
    return DesiredSet(rev.toInt(), items);
  }
}

/// Поле `videos_rev` из ответа `device_poll`. null — поля нет или оно
/// непонятно: ничего не менять.
int? parsePollVideosRev(Map body) {
  final v = body['videos_rev'];
  return v is int && v >= 0 ? v : null;
}

/// Файл с карты (папка `vid`), как его видит приложение.
@immutable
class LocalVideoFile {
  const LocalVideoFile({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
    this.width,
    this.height,
    this.durationMs,
    this.deletable = false,
  });
  final String name;
  final String path;
  final int sizeBytes;
  final DateTime modified;
  final int? width;
  final int? height;
  final int? durationMs;
  final bool deletable;

  LocalVideoFile withInfo({int? width, int? height, int? durationMs, bool? deletable}) =>
      LocalVideoFile(
        name: name,
        path: path,
        sizeBytes: sizeBytes,
        modified: modified,
        width: width ?? this.width,
        height: height ?? this.height,
        durationMs: durationMs ?? this.durationMs,
        deletable: deletable ?? this.deletable,
      );
}

/// Одна запись проигрывания.
@immutable
class PlaylistEntry {
  const PlaylistEntry({required this.id, required this.path, required this.addedAt});
  final String id;
  final String path;
  final DateTime addedAt;

  @override
  bool operator ==(Object other) =>
      other is PlaylistEntry && other.id == id && other.path == path;
  @override
  int get hashCode => Object.hash(id, path);
}

/// Что играть: отмеченные (`play`) и присутствующие на карте — в порядке
/// даты добавления (ТЗ 2.4). Файлы с карты, о которых сервер ещё не знает,
/// считаются отмеченными: сервер заводит их с галочкой (так до обновления
/// заставка играла все файлы с карты, и она не должна замолчать на время
/// первого отчёта).
///
/// [uploadPaths] — id → путь скачанных и проверенных файлов.
/// [localFiles] — имя → файл с карты.
List<PlaylistEntry> buildPlaylist({
  required List<DesiredVideo> desired,
  required Map<String, String> uploadPaths,
  required Map<String, LocalVideoFile> localFiles,
}) {
  final out = <PlaylistEntry>[];
  final knownLocal = <String>{};
  for (final d in desired) {
    if (!d.isUpload && d.localName != null) knownLocal.add(d.localName!);
    if (d.delete || !d.play) continue;
    if (d.isUpload) {
      final p = uploadPaths[d.id];
      if (p != null) out.add(PlaylistEntry(id: d.id, path: p, addedAt: d.createdAt));
    } else {
      final f = localFiles[d.localName];
      if (f != null) out.add(PlaylistEntry(id: d.id, path: f.path, addedAt: d.createdAt));
    }
  }
  for (final f in localFiles.values) {
    if (knownLocal.contains(f.name)) continue;
    out.add(PlaylistEntry(id: 'local:${f.name}', path: f.path, addedAt: f.modified));
  }
  out.sort((a, b) {
    final c = a.addedAt.compareTo(b.addedAt);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return out;
}

/// Какой ролик играть после [current]: следующий по кругу; если текущего
/// в новом списке нет (набор сменили) — первый. null — играть нечего.
String? nextAfter(List<String> paths, String? current) {
  if (paths.isEmpty) return null;
  final i = current == null ? -1 : paths.indexOf(current);
  if (i < 0) return paths.first;
  return paths[(i + 1) % paths.length];
}

/// Причина сбоя для отчёта: `failed:<причина>`, только безопасные знаки,
/// не длиннее 60 (так же проверяет база).
String failedState(String reason) {
  final clean = reason.replaceAll(RegExp(r'[^A-Za-z0-9_ .-]'), '_');
  final cut = clean.length > 60 ? clean.substring(0, 60) : clean;
  return 'failed:${cut.isEmpty ? 'unknown' : cut}';
}

/// Элемент отчёта о загруженном видео.
Map<String, dynamic> uploadReportItem(String id, String state) =>
    {'kind': 'upload', 'id': id, 'state': state};

/// Элемент отчёта о файле с карты.
Map<String, dynamic> localReportItem(LocalVideoFile f) => {
      'kind': 'local',
      'local_name': f.name,
      'size_bytes': f.sizeBytes,
      if (f.width != null) 'width': f.width,
      if (f.height != null) 'height': f.height,
      if (f.durationMs != null) 'duration_ms': f.durationMs,
      'deletable': f.deletable,
      'mtime_ms': f.modified.millisecondsSinceEpoch,
    };

/// Сколько элементов отчёта разрешает база.
const int maxReportItems = 200;

/// Отчёт не длиннее предела базы: файлы с карты обрезаются первыми
/// (загруженные важнее).
List<Map<String, dynamic>> capReport(
  List<Map<String, dynamic>> uploads,
  List<Map<String, dynamic>> locals,
) {
  final u = uploads.length > maxReportItems ? uploads.sublist(0, maxReportItems) : uploads;
  final room = maxReportItems - u.length;
  final l = locals.length > room ? locals.sublist(0, room) : locals;
  return [...u, ...l];
}
