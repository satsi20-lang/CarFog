import 'package:flutter/foundation.dart';

import 'video_model.dart';

/// Что сейчас играет на заставке (VIDEO1). Заставка слушает [state] и
/// меняет набор на границе ролика — без перезапуска и без чёрного экрана.
@immutable
class VideoPlaylistState {
  const VideoPlaylistState({required this.managed, required this.entries});

  /// false — набор от облака ещё ни разу не получен: заставка играет файлы
  /// с карты по-старому (все файлы папки `vid`). true — набор определён
  /// облаком (он может быть и пустым: тогда видео не играет, остаётся
  /// заставка с логотипом).
  final bool managed;
  final List<PlaylistEntry> entries;

  List<String> get paths => entries.map((e) => e.path).toList();

  @override
  bool operator ==(Object other) =>
      other is VideoPlaylistState &&
      other.managed == managed &&
      listEquals(other.entries, entries);
  @override
  int get hashCode => Object.hash(managed, Object.hashAll(entries));
}

class VideoPlaylist {
  VideoPlaylist._();

  static final ValueNotifier<VideoPlaylistState> state = ValueNotifier(
    const VideoPlaylistState(managed: false, entries: []),
  );

  /// Публикует набор; одинаковый набор слушателей не будит.
  static void publish({required bool managed, required List<PlaylistEntry> entries}) {
    final next = VideoPlaylistState(managed: managed, entries: List.unmodifiable(entries));
    if (next == state.value) return;
    state.value = next;
  }

  static void reset() => state.value = const VideoPlaylistState(managed: false, entries: []);
}
