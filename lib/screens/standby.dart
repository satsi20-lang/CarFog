import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/app_state.dart';

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
    final notifier = context.read<AppNotifier>();

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
            const Positioned(top: 16, right: 16, child: _LangSwitcher()),

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
              errorBuilder: (_, __, ___) => const Icon(
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

class _LangSwitcher extends StatelessWidget {
  const _LangSwitcher();

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final currentLang = notifier.lang;

    return GestureDetector(
      onTap: () {},
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: ['et', 'en', 'ru'].map((lang) {
            final isActive = lang == currentLang;
            return GestureDetector(
              onTap: () => notifier.setLanguage(lang),
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 4),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: isActive
                      ? const Color(0xFF2EC4B6)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: const Color(0xFF2EC4B6),
                    width: isActive ? 0 : 1,
                  ),
                ),
                child: Text(
                  lang.toUpperCase(),
                  style: TextStyle(
                    color: isActive ? Colors.black : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
