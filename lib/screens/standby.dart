import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../models/app_state.dart';
import '../services/i18n_service.dart';
import '../services/storage_service.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

class StandbyScreen extends StatefulWidget {
  const StandbyScreen({super.key});

  @override
  State<StandbyScreen> createState() => _StandbyScreenState();
}

const _hintStyle = TextStyle(
  color: Colors.white,
  fontSize: PUi.bodySp,
  height: 1.4,
);

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
                  // .mp4 — основной формат. .mkv/.webm — тоже штатно
                  // читаются ExoPlayer'ом, лишняя строка в фильтре дешевле
                  // разбирательства "почему не играет". .lmxb (формат со
                  // старого аппарата с пиксельным экраном) сюда больше не
                  // входит — ExoPlayer его не распознаёт вообще
                  // (UnrecognizedInputFormatException), только зря тратил
                  // время на попытку открыть. Если конкретный файл всё же
                  // окажется нечитаемым, _playVideo() пропустит его и
                  // перейдёт к следующему (см. ниже).
                  return p.endsWith('.mp4') ||
                      p.endsWith('.mkv') ||
                      p.endsWith('.webm');
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
  // (если на карте нашлось хоть одно видео). Язык, выбранный ушедшим
  // клиентом, возвращается к языку по умолчанию.
  void _armIdleTimer() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_idleTimeout, _startVideo);
  }

  void _setLanguage(String lang) {
    context.read<AppNotifier>().setLanguage(lang);
    _armIdleTimer();
  }

  void _startVideo() {
    if (!mounted) return;
    context.read<AppNotifier>().resetLanguage();
    if (_playlist.isEmpty) return;
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
      // Файл повреждён или ExoPlayer не распознаёт контейнер — пропускаем
      // и пробуем следующий, а не роняем всю заставку из-за одного
      // битого файла.
      debugPrint('StandbyScreen: playback failed for $path: $e');
      controller.dispose();
      final nextIndex = (index + 1) % _playlist.length;
      _currentIndex = nextIndex;
      await _playVideo(nextIndex, attempt + 1);
      return;
    }

    // Один файл в плейлисте — зацикливаем его средствами самого плеера:
    // просто и без риска гонки на границе конец/начало (см. ниже). Но
    // ошибку во время воспроизведения (не при инициализации, а позже —
    // например карту вынули на ходу) всё равно нужно ловить, иначе экран
    // молча зависнет на сломанном кадре навсегда.
    // Несколько файлов — крутим плейлист по кругу, но не через
    // ручное отслеживание "position >= duration" в addListener: тот
    // слушатель дёргается на каждое обновление позиции (много раз в
    // секунду), и пока старый контроллер ещё не задиспоузился, условие
    // окончания успевало сработать повторно — ролик мог оборваться
    // раньше времени и просмотр падал на заставку вместо луп-показа.
    // "_advancing" гарантирует, что переход к следующему файлу
    // запускается ровно один раз за ролик.
    if (_playlist.length == 1) {
      controller.setLooping(true);
      var failed = false;
      controller.addListener(() {
        if (!mounted || failed || !controller.value.hasError) return;
        failed = true;
        debugPrint(
          'StandbyScreen: playback error for $path: '
          '${controller.value.errorDescription}',
        );
        _stopVideo();
      });
    } else {
      controller.setLooping(false);
      var advancing = false;
      controller.addListener(() {
        if (!mounted || advancing) return;
        if (controller.value.hasError) {
          advancing = true;
          final nextIndex = (index + 1) % _playlist.length;
          _currentIndex = nextIndex;
          _playVideo(nextIndex, attempt + 1);
          return;
        }
        if (controller.value.isCompleted) {
          advancing = true;
          _currentIndex = (_currentIndex + 1) % _playlist.length;
          _playVideo(_currentIndex);
        }
      });
    }
    controller.play();

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

  // Многоязычные строки заставки: до 3 языков — на всех показываемых
  // (порядок spec), больше — только на текущем (остальные — через
  // переключатель).
  List<String> _captionLangs(AppNotifier notifier) =>
      notifier.displayLangs.length <= 3
      ? notifier.displayLangs
      : [notifier.lang];

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final captionLangs = _captionLangs(notifier);

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
              _buildPlaceholder(captionLangs),

            // Переключатель языка в правом верхнем углу (один язык — нет).
            if (notifier.displayLangs.length > 1)
              Positioned(
                top: 24,
                right: 24,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: LangSwitcher(
                    current: notifier.lang,
                    langs: notifier.displayLangs,
                    onChanged: _setLanguage,
                  ),
                ),
              ),

            // Подсказка внизу
            Positioned(
              bottom: 64,
              left: PUi.gutter,
              right: PUi.gutter,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 20,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: PUi.accent, width: 2),
                  ),
                  // Строки одна под другой: в портрете одна длинная строка
                  // на 22+ sp не помещается в ширину.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final l in captionLangs)
                        Text(
                          I18n.tr(l, 'standby.tap_to_start'),
                          textAlign: TextAlign.center,
                          style: _hintStyle,
                        ),
                    ],
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
                onLongPress: () => context.read<AppNotifier>().transition(
                  AppState.servicePinEntry,
                ),
                child: const SizedBox(width: 80, height: 80),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceholder(List<String> captionLangs) {
    // Портрет 720x1280 dp: крупный QR в верхней половине, название ниже;
    // низ занимает подсказка (Positioned выше). QR масштабируется по
    // ширине экрана, но не больше доступной высоты.
    return SizedBox.expand(
      child: ColoredBox(
        color: const Color(0xFF0B2545),
        child: LayoutBuilder(
          builder: (context, c) {
            final qr = (c.maxWidth * 0.62).clamp(220.0, c.maxHeight * 0.4);
            return Column(
              children: [
                const Spacer(flex: 3),
                Image.asset(
                  'assets/qr_code.png',
                  width: qr,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.local_car_wash,
                    size: qr * 0.6,
                    color: PUi.accent,
                  ),
                ),
                const SizedBox(height: 40),
                const Text(
                  'CaRFog OÜ',
                  style: TextStyle(
                    color: PUi.accent,
                    fontSize: 56,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: PUi.gutter),
                  child: Text(
                    captionLangs
                        .map((l) => I18n.tr(l, 'standby.subtitle'))
                        .toSet()
                        .join(' · '),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: PUi.minBodySp,
                    ),
                  ),
                ),
                const Spacer(flex: 4),
              ],
            );
          },
        ),
      ),
    );
  }
}
