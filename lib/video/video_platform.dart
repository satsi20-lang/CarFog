import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../services/system_service.dart';

/// Результат проверки воспроизводимости файла.
@immutable
class VideoProbe {
  const VideoProbe({required this.width, required this.height, required this.durationMs});
  final int width;
  final int height;
  final int durationMs;
}

/// Всё, что требует Android: тома, свободное место, проверка кадра, права
/// на удаление. Интерфейс подменяется в тестах.
abstract class VideoPlatform {
  /// Папки приложения (`Android/data/<пакет>/files`) на СЪЁМНЫХ томах, где
  /// карта примонтирована. Пусто — карты нет.
  Future<List<String>> removableAppDirs();

  /// Корни всех томов (SD первой) — для поиска ручных файлов в `vid`.
  Future<List<String>> volumeRoots();

  /// Свободно байт на томе, где лежит [path]. null — узнать не удалось.
  Future<int?> freeBytes(String path);

  /// Открывает файл и читает кадр (MediaMetadataRetriever). null — файл
  /// не воспроизводится.
  Future<VideoProbe?> probe(String path);

  /// Можно ли приложению удалить каждый из файлов.
  Future<Map<String, bool>> canDelete(List<String> paths);

  /// Каталог файлов приложения (для состояния плейлиста).
  Future<String?> filesDir();
}

class ChannelVideoPlatform implements VideoPlatform {
  const ChannelVideoPlatform();
  static const _channel = MethodChannel('com.carfog.dryfog/storage');

  @override
  Future<List<String>> removableAppDirs() async {
    try {
      final r = await _channel.invokeMethod<List>('videoDirs');
      return r?.whereType<String>().toList() ?? const [];
    } catch (e) {
      debugPrint('VideoPlatform.removableAppDirs: ${e.runtimeType}');
      return const [];
    }
  }

  @override
  Future<List<String>> volumeRoots() async {
    try {
      final r = await _channel.invokeMethod<List>('listVolumeRoots');
      return r?.whereType<String>().toList() ?? const [];
    } catch (e) {
      return const [];
    }
  }

  @override
  Future<int?> freeBytes(String path) async {
    try {
      final r = await _channel.invokeMethod<num>('freeBytes', {'path': path});
      return r?.toInt();
    } catch (e) {
      debugPrint('VideoPlatform.freeBytes: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<VideoProbe?> probe(String path) async {
    try {
      final r = await _channel.invokeMethod<Map>('probeVideo', {'path': path});
      if (r == null) return null;
      final w = r['width'];
      final h = r['height'];
      final d = r['durationMs'];
      if (w is! num || h is! num || d is! num) return null;
      if (r['frame'] != true) return null;
      return VideoProbe(width: w.toInt(), height: h.toInt(), durationMs: d.toInt());
    } catch (e) {
      debugPrint('VideoPlatform.probe: ${e.runtimeType}');
      return null;
    }
  }

  @override
  Future<Map<String, bool>> canDelete(List<String> paths) async {
    if (paths.isEmpty) return const {};
    try {
      final r = await _channel.invokeMethod<Map>('canDelete', {'paths': paths});
      return {
        for (final e in (r ?? const {}).entries)
          if (e.key is String) e.key as String: e.value == true,
      };
    } catch (e) {
      return const {};
    }
  }

  @override
  Future<String?> filesDir() => SystemService.getFilesDir();
}
