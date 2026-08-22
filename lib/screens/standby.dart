import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/app_state.dart';
import '../services/storage_service.dart';
import '../widgets/lang_switcher.dart';

class StandbyScreen extends StatefulWidget {
  const StandbyScreen({super.key});

  @override
  State<StandbyScreen> createState() => _StandbyScreenState();
}

class _StandbyScreenState extends State<StandbyScreen> {
  static const _idleTimeout = Duration(seconds: 30);

  VideoPlayerController? _controller;
  List<String> _playlist = [];
  int _currentIndex = 0;

  // false — заставка (лого/QR), true — идёт видео-заставка с SD-карты.
  bool _showingVideo = false;

  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    _scanVideos();
    _armIdleTimer();
  }

  Future<void> _scanVideos() async {
    final List<String> found = [];

    // SD-карта монтируется по ID конкретного тома (например
    // /storage/DCA3-BA1A), а не по предсказуемому имени вроде "sdcard1",
    // а прямой листинг /storage/ приложению запрещён политикой хранения
    // (Permission denied) — поэтому список томов берём через нативный
    // Android API (см. StorageService), а не перебором вручную.
    final roots = await StorageService.listVolumeRoots();
    final candidates = roots.map((r) => '$r/vid').toList()
      ..addAll(['/storage/emulated/0/vid', '/storage/self/primary/vid']);

    for (final path in candidates) {
      final dir = Directory(path);
      if (await dir.exists()) {
        final files =
            dir
                .listSync()
                .where((f) {
                  final p = f.path.toLowerCase();
                  // .lmxb встречается на некоторых картах наравне с .mp4 —
                  // принимаем оба расширения. Если конкретный файл
                  // окажется нечитаемым, _playVideo() просто пропустит
                  // его и перейдёт к следующему (см. ниже).
                  return p.endsWith('.mp4') || p.endsWith('.lmxb');
                })
                .map((f) => f.path)
                .toList()
              ..sort();
        if (files.isNotEmpty) {
          found.addAll(files);
          break;
        }
      }
    }

    if (mounted) setState(() => _playlist = found);
  }

  // 30 секунд без тапа на заставке — переключаемся на видео-заставку
  // (если на карте нашлось хоть одно видео).
  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, _startVideo);
  }

  void _startVideo() {
    if (!mounted || _playlist.isEmpty) return;
    setState(() => _showingVideo = true);
    _currentIndex = 0;
    _playVideo(_currentIndex);
  }

  // Тап во время видео не уводит в выбор аромата — сначала возвращает
  // на заставку. Уйти дальше можно только повторным тапом уже с неё.
  void _stopVideo() {
    _idleTimer?.cancel();
    _controller?.dispose();
    _controller = null;
    if (mounted) setState(() => _showingVideo = false);
    _armIdleTimer();
  }

  // attempt считает, сколько файлов подряд не удалось воспроизвести в
  // этом проходе — если ни один файл в плейлисте не читается, возвращаемся
  // на заставку вместо того, чтобы бесконечно перебирать по кругу.
  Future<void> _playVideo(int index, [int attempt = 0]) async {
    if (attempt >= _playlist.length) {
      _stopVideo();
      return;
    }

    _controller?.dispose();
    _controller = null;

    final path = _playlist[index];
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
    } catch (e) {
      // Файл повреждён/не тот формат (например .lmxb без валидного
      // контейнера) — пропускаем и пробуем следующий, а не роняем экран.
      debugPrint('StandbyScreen: playback failed for $path: $e');
      controller.dispose();
      final nextIndex = (index + 1) % _playlist.length;
      _currentIndex = nextIndex;
      await _playVideo(nextIndex, attempt + 1);
      return;
    }

    controller.setLooping(false);
    controller.play();

    controller.addListener(() {
      if (!mounted) return;
      if (controller.value.hasError) {
        final nextIndex = (index + 1) % _playlist.length;
        _currentIndex = nextIndex;
        _playVideo(nextIndex, attempt + 1);
        return;
      }
      if (controller.value.position >= controller.value.duration &&
          controller.value.duration.inSeconds > 0) {
        _currentIndex = (_currentIndex + 1) % _playlist.length;
        _playVideo(_currentIndex);
      }
    });

    if (mounted) setState(() => _controller = controller);
  }

  void _onTap() {
    if (_showingVideo) {
      _stopVideo();
    } else {
      context.read<AppNotifier>().transition(AppState.selectFlavor);
    }
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();

    return GestureDetector(
      onTap: _onTap,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Видео-заставка или заглушка (лого/QR)
            if (_showingVideo &&
                _controller != null &&
                _controller!.value.isInitialized)
              SizedBox.expand(
                child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _controller!.value.size.width,
                    height: _controller!.value.size.height,
                    child: VideoPlayer(_controller!),
                  ),
                ),
              )
            else
              _buildPlaceholder(),

            // Переключатель языка в правом верхнем углу
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: LangSwitcher(
                  current: notifier.lang,
                  onChanged: notifier.setLanguage,
                ),
              ),
            ),

            // Подсказка внизу
            Positioned(
              bottom: 40,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF2EC4B6),
                      width: 1,
                    ),
                  ),
                  child: const Text(
                    'Нажмите для начала  ·  Tap to start  ·  Puudutage alustamiseks',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),

            // Невидимая зона долгого нажатия — левый верхний угол
            Positioned(
              left: 0,
              top: 0,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () =>
                    context.read<AppNotifier>().transition(AppState.servicePinEntry),
                child: const SizedBox(width: 80, height: 80),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF0B2545),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'assets/qr_code.png',
              width: 220,
              errorBuilder: (_, _, _) => const Icon(
                Icons.local_car_wash,
                size: 100,
                color: Color(0xFF2EC4B6),
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              'CaRFog OÜ',
              style: TextStyle(
                color: Color(0xFF2EC4B6),
                fontSize: 32,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'СУХОЙ ТУМАН · KUIV UDU · DRY FOG',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
