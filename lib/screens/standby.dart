import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';
import '../brand/brand.dart';
import '../brand/brand_colors.dart';
import '../brand/brand_qr.dart';
import '../models/app_state.dart';
import '../services/i18n_service.dart';
import '../services/storage_service.dart';
import '../video/video_model.dart';
import '../video/video_playlist.dart';
import '../widgets/card_hint_banner.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

class StandbyScreen extends StatefulWidget {
  const StandbyScreen({super.key});

  @override
  State<StandbyScreen> createState() => _StandbyScreenState();
}

TextStyle _hintStyle(BuildContext context) => TextStyle(
  color: context.brand.textPrimary,
  fontSize: PUi.bodySp,
  height: 1.4,
);

class _StandbyScreenState extends State<StandbyScreen> {
  static const _idleTimeout = Duration(seconds: 30);

  VideoPlayerController? _controller;
  List<String> _playlist = [];
  // Путь ролика, который играет сейчас (null — видео не играет).
  String? _current;

  // false — заставка (лого/QR), true — идёт видео-заставка с SD-карты.
  bool _showingVideo = false;

  Timer? _idleTimer;

  @override
  void initState() {
    super.initState();
    // Набор от облака (VIDEO1) — слушаем: смена набора подхватывается на
    // границе ролика, без перезапуска и без чёрного экрана.
    VideoPlaylist.state.addListener(_onPlaylistChanged);
    if (VideoPlaylist.state.value.managed) {
      _playlist = VideoPlaylist.state.value.paths;
    } else {
      _scanVideos();
    }
    _armIdleTimer();
  }

  void _onPlaylistChanged() {
    final st = VideoPlaylist.state.value;
    if (!mounted || !st.managed) return;
    final next = st.paths;
    if (listEquals(next, _playlist)) return;
    setState(() => _playlist = next);
    // Один ролик крутится плеером по кругу; как только набор изменился,
    // зацикливание снимается — ролик доиграет и уступит следующему.
    _syncLooping();
  }

  void _syncLooping() {
    final c = _controller;
    final cur = _current;
    if (c == null || cur == null) return;
    c.setLooping(_playlist.length == 1 && _playlist.first == cur);
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

    // Если за время сканирования пришёл набор от облака — он главнее.
    if (mounted && !VideoPlaylist.state.value.managed) {
      setState(() => _playlist = found);
    }
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
    _playVideo(_playlist.first);
  }

  // Тап во время видео не уводит в выбор аромата — сначала возвращает
  // на заставку. Уйти дальше можно только повторным тапом уже с неё.
  void _stopVideo() {
    _idleTimer?.cancel();
    _controller?.dispose();
    _controller = null;
    _current = null;
    if (mounted) setState(() => _showingVideo = false);
    _armIdleTimer();
  }

  // failures считает, сколько файлов подряд не удалось воспроизвести в
  // этом проходе — если ни один файл в плейлисте не читается, возвращаемся
  // на заставку вместо того, чтобы бесконечно перебирать по кругу.
  Future<void> _playVideo(String path, [int failures = 0]) async {
    if (failures >= _playlist.length || _playlist.isEmpty) {
      _stopVideo();
      return;
    }

    _controller?.dispose();
    _controller = null;
    _current = path;
    if (!mounted) return;

    // Громкость задаётся явно на каждом запуске ролика: по умолчанию 0
    // (без звука), 1 — только если включён тумблер «Звук видео ожидания».
    // Без этого video_player играет с громкостью 1.0.
    final volume = context.read<AppNotifier>().config.standbyVideoVolume;
    final controller = VideoPlayerController.file(File(path));
    try {
      await controller.initialize();
    } catch (e) {
      // Файл повреждён или ExoPlayer не распознаёт контейнер — пропускаем
      // и пробуем следующий, а не роняем всю заставку из-за одного
      // битого файла.
      debugPrint('StandbyScreen: playback failed for $path: $e');
      controller.dispose();
      _advance(path, failures + 1);
      return;
    }

    // Один файл в плейлисте — зацикливаем его средствами самого плеера:
    // просто и без риска гонки на границе конец/начало. Несколько — на
    // конце ролика берём следующий по кругу (`nextAfter`). Набор мог
    // смениться за время ролика: следующий берётся из НОВОГО набора, а если
    // текущего в нём нет — первый (смена на границе ролика).
    //
    // "advancing" гарантирует, что переход к следующему файлу запускается
    // ровно один раз за ролик: слушатель дёргается на каждое обновление
    // позиции, и без флага условие окончания срабатывало бы повторно.
    // Ошибку во время воспроизведения (например, карту вынули на ходу)
    // нужно ловить всегда, иначе экран молча зависнет на сломанном кадре.
    controller.setLooping(_playlist.length == 1 && _playlist.first == path);
    var advancing = false;
    controller.addListener(() {
      if (!mounted || advancing) return;
      if (controller.value.hasError) {
        advancing = true;
        debugPrint(
          'StandbyScreen: playback error for $path: '
          '${controller.value.errorDescription}',
        );
        _advance(path, failures + 1);
        return;
      }
      if (controller.value.isCompleted) {
        advancing = true;
        _advance(path, 0);
      }
    });
    await controller.setVolume(volume);
    if (!mounted) {
      controller.dispose();
      return;
    }
    controller.play();

    if (mounted) setState(() => _controller = controller);
  }

  // Что играть после ролика [from]: следующий из актуального набора; набор
  // опустел — назад на заставку.
  void _advance(String from, int failures) {
    final next = nextAfter(_playlist, from);
    if (next == null) {
      _stopVideo();
      return;
    }
    _playVideo(next, failures);
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
    VideoPlaylist.state.removeListener(_onPlaylistChanged);
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
    // Бренд меняется только пока аппарат на заставке (BrandService).
    return ListenableBuilder(
      listenable: BrandController.instance,
      builder: (context, _) => _content(context, BrandController.instance.active),
    );
  }

  Widget _content(BuildContext context, Brand brand) {
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
            else if (PUi.landscape)
              _buildLandscapePlaceholder(context, brand, notifier.config, captionLangs)
            else
              _buildPlaceholder(context, brand, notifier.config, captionLangs),

            // Переключатель языка в правом верхнем углу (один язык — нет).
            if (notifier.displayLangs.length > 1)
              Positioned(
                top: PUi.landscape ? 12 : 24,
                right: PUi.landscape ? 12 : 24,
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
            if (PUi.landscape)
              Positioned(
                bottom: 24,
                left: PUi.m.gutter,
                right: PUi.m.gutter,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 28,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: context.brand.primary,
                        width: 2,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final l in captionLangs)
                          Text(
                            I18n.tr(l, 'standby.tap_to_start'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: context.brand.textPrimary,
                              fontSize: PUi.m.bodySp,
                              height: 1.4,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              )
            else
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
                      border: Border.all(
                        color: context.brand.primary,
                        width: 2,
                      ),
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
                            style: _hintStyle(context),
                          ),
                      ],
                    ),
                  ),
                ),
              ),

            // Карту приложили, не выбрав запах (1.11.0): терминал закрыл
            // сессию без списания — подсказка на языках заставки.
            Positioned(
              top: PUi.landscape ? 84 : 120,
              left: PUi.gutter,
              right: PUi.gutter,
              child: Center(
                child: CardHintBanner(
                  text: {
                    for (final l in captionLangs)
                      I18n.tr(l, 'standby.card_hint'),
                  }.join('\n'),
                ),
              ),
            ),

            // «Powered by CaRFog» — маленькая подпись, зашита в приложение и
            // остаётся при любом бренде (решение владельца 3). На видео её нет.
            if (!_showingVideo)
              Positioned(
                left: 0,
                right: 0,
                bottom: PUi.landscape ? 4 : 16,
                child: IgnorePointer(
                  child: Text(
                    'Powered by CaRFog',
                    key: const ValueKey('powered_by'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.brand.textSecondary,
                      fontSize: PUi.landscape ? 13 : 16,
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

  // Подпись под названием: слоган бренда (английский, одна строка для всех
  // языков) или, если его нет, встроенный standby.subtitle по языкам.
  String _subtitle(Brand brand, List<String> captionLangs, String sep) {
    if (brand.slogan.isNotEmpty) return brand.slogan;
    return captionLangs
        .map((l) => I18n.tr(l, 'standby.subtitle'))
        .toSet()
        .join(sep);
  }

  // Контакты продавца — данные аппарата. Блок есть, только если что-то задано.
  List<String> _contactLines(AppConfig c) => [
    c.sellerPhone,
    c.sellerEmail,
    c.sellerSite,
    c.sellerLegal,
  ].where((v) => v.isNotEmpty).toList();

  Widget _contacts(BuildContext context, AppConfig c, {required bool center}) {
    final lines = _contactLines(c);
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      key: const ValueKey('standby_contacts'),
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: center
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final l in lines)
            Text(
              l,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: center ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                color: context.brand.textPrimaryA(0xB3),
                fontSize: PUi.m.minBodySp - 2,
                height: 1.3,
              ),
            ),
        ],
      ),
    );
  }

  Widget _logo(Brand brand, double maxH, double maxW) {
    if (brand.logoPath == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Image.file(
        File(brand.logoPath!),
        key: const ValueKey('standby_logo'),
        height: maxH,
        width: maxW,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }

  // Альбом 853x533 dp (IXP101M1): QR слева, логотип, название и подпись
  // справа; нижняя полоса свободна под подсказку (Positioned в build).
  Widget _buildLandscapePlaceholder(
    BuildContext context,
    Brand brand,
    AppConfig cfg,
    List<String> captionLangs,
  ) {
    final m = PUi.m;
    return SizedBox.expand(
      child: ColoredBox(
        color: context.brand.backgroundStandby,
        child: LayoutBuilder(
          builder: (context, c) {
            final qr = (c.maxHeight * 0.5).clamp(160.0, c.maxWidth * 0.32);
            return Padding(
              padding: EdgeInsets.fromLTRB(
                m.gutter + 24,
                m.langH + 24,
                m.gutter + 24,
                _landscapeHintReserve(captionLangs.length),
              ),
              child: Row(
                children: [
                  BrandQr(
                    brand: brand,
                    url: cfg.qrUrl,
                    size: qr,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.local_car_wash,
                      size: qr * 0.6,
                      color: context.brand.primary,
                    ),
                  ),
                  const SizedBox(width: 40),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _logo(brand, c.maxHeight * 0.13, c.maxWidth * 0.3),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            brand.name,
                            style: TextStyle(
                              color: context.brand.primary,
                              fontSize: 48,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _subtitle(brand, captionLangs, '\n'),
                          style: TextStyle(
                            color: context.brand.textPrimaryA(0xB3), // white70
                            fontSize: m.minBodySp,
                            height: 1.35,
                          ),
                        ),
                        _contacts(context, cfg, center: false),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // Высота нижней полосы под подсказку в альбоме: строки + поля рамки.
  static double _landscapeHintReserve(int lines) =>
      24 + 20 + lines * PUi.m.bodySp * 1.4 + 24;

  Widget _buildPlaceholder(
    BuildContext context,
    Brand brand,
    AppConfig cfg,
    List<String> captionLangs,
  ) {
    // Портрет 720x1280 dp: крупный QR в верхней половине, название ниже;
    // низ занимает подсказка (Positioned выше). QR масштабируется по
    // ширине экрана, но не больше доступной высоты.
    return SizedBox.expand(
      child: ColoredBox(
        color: context.brand.backgroundStandby,
        child: LayoutBuilder(
          builder: (context, c) {
            final qr = (c.maxWidth * 0.62).clamp(220.0, c.maxHeight * 0.4);
            return Column(
              children: [
                const Spacer(flex: 3),
                BrandQr(
                  brand: brand,
                  url: cfg.qrUrl,
                  size: qr,
                  errorBuilder: (_, _, _) => Icon(
                    Icons.local_car_wash,
                    size: qr * 0.6,
                    color: context.brand.primary,
                  ),
                ),
                const SizedBox(height: 40),
                if (brand.logoPath != null)
                  Center(child: _logo(brand, c.maxHeight * 0.1, c.maxWidth * 0.5)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: PUi.gutter),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      brand.name,
                      style: TextStyle(
                        color: context.brand.primary,
                        fontSize: 56,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: PUi.gutter),
                  child: Text(
                    _subtitle(brand, captionLangs, ' · '),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: context.brand.textPrimaryA(0xB3), // white70
                      fontSize: PUi.minBodySp,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: PUi.gutter),
                  child: _contacts(context, cfg, center: true),
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
