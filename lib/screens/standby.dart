import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/app_state.dart';
import '../widgets/lang_switcher.dart';

class StandbyScreen extends StatefulWidget {
  const StandbyScreen({super.key});

  @override
  State<StandbyScreen> createState() => _StandbyScreenState();
}

class _StandbyScreenState extends State<StandbyScreen> {
  VideoPlayerController? _controller;
  List<String> _playlist = [];
  int _currentIndex = 0;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _scanAndPlay();
  }

  Future<void> _scanAndPlay() async {
    final List<String> found = [];

    final List<String> sdPaths = [
      '/storage/sdcard1/ads',
      '/storage/extSdCard/ads',
      '/mnt/sdcard1/ads',
      '/storage/self/primary/ads',
    ];

    for (final path in sdPaths) {
      final dir = Directory(path);
      if (await dir.exists()) {
        final files =
            dir
                .listSync()
                .where((f) => f.path.toLowerCase().endsWith('.mp4'))
                .map((f) => f.path)
                .toList()
              ..sort();
        found.addAll(files);
        break;
      }
    }

    setState(() {
      _playlist = found.isNotEmpty ? found : ['default'];
      _isLoading = false;
    });

    _playVideo(_currentIndex);
  }

  Future<void> _playVideo(int index) async {
    _controller?.dispose();

    final path = _playlist[index];

    if (path == 'default') {
      setState(() => _controller = null);
      return;
    }

    final controller = VideoPlayerController.file(File(path));
    await controller.initialize();
    controller.setLooping(false);
    controller.play();

    controller.addListener(() {
      if (!mounted) return;
      if (controller.value.position >= controller.value.duration &&
          controller.value.duration.inSeconds > 0) {
        _currentIndex = (_currentIndex + 1) % _playlist.length;
        _playVideo(_currentIndex);
      }
    });

    if (mounted) setState(() => _controller = controller);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();

    return GestureDetector(
      onTap: () => notifier.transition(AppState.selectFlavor),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            // Видео или заглушка
            if (_controller != null && _controller!.value.isInitialized)
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
              'assets/logo.png',
              width: 160,
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
