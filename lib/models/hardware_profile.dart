// Аппаратные профили планшетов — единственный источник правды (см.
// docs/hardware.md и docs/releases.md). Сборка универсальная: профиль
// выбирается при старте по реальному устройству (detect), а не константой.

enum ScreenOrientation { portrait, landscape }

// Размеры интерфейса профиля (sp/dp): шрифты, кнопки, поля. Портретный набор
// — прежние числа SY156-A510 (portrait_ui.dart держит их и как const для
// портретного кода; тест сверяет совпадение). Альбомный — для малого
// IXP101M1 (853x533 dp): заголовки ≥ 28 sp, текст ≥ 18 sp, кнопки ≥ 56 dp,
// зона касания ≥ 48 dp.
class UiMetrics {
  final double titleSp;
  final double bodySp;
  final double minTitleSp;
  final double minBodySp;
  final double buttonH;
  final double minButtonH;
  final double minTouch;
  final double gutter;
  final double langH;
  final double langW;
  final double langSp;

  const UiMetrics({
    required this.titleSp,
    required this.bodySp,
    required this.minTitleSp,
    required this.minBodySp,
    required this.buttonH,
    required this.minButtonH,
    required this.minTouch,
    required this.gutter,
    required this.langH,
    required this.langW,
    required this.langSp,
  });

  static const portrait = UiMetrics(
    titleSp: 40,
    bodySp: 24,
    minTitleSp: 36,
    minBodySp: 22,
    buttonH: 80,
    minButtonH: 72,
    minTouch: 56,
    gutter: 32,
    langH: 64,
    langW: 88,
    langSp: 24,
  );

  static const landscape = UiMetrics(
    titleSp: 30,
    bodySp: 20,
    minTitleSp: 28,
    minBodySp: 18,
    buttonH: 60,
    minButtonH: 56,
    minTouch: 48,
    gutter: 20,
    langH: 48,
    langW: 64,
    langSp: 20,
  );
}

class HardwareProfile {
  final String id;
  final String title;

  // Порт шины RS485 по умолчанию для этого планшета. Это только значение по
  // умолчанию: рабочий порт — настройка (AppConfig.busPort), сохранённое
  // значение важнее. Запрещённые узлы (BusPortPolicy) одни для всех профилей.
  final String defaultBusPort;

  final int screenWidthPx;
  final int screenHeightPx;
  final int densityDpi;

  // Подстроки ro.product.board/device/model/hardware (нижний регистр),
  // по которым профиль узнаётся.
  final List<String> socTags;

  // Ориентация интерфейса (main.dart выставляет её при старте) и размеры.
  final ScreenOrientation orientation;
  final UiMetrics ui;

  // Сторож системных панелей (SystemBarsGuard.kt): прячет полоску навигации,
  // если она осталась на экране после свайпа снизу. Нужен на IXP101M1
  // (прошивка Lztek, 03.11.2026); на SY156-A510 не включается.
  final bool guardSystemBars;

  const HardwareProfile._({
    required this.id,
    required this.title,
    required this.defaultBusPort,
    required this.screenWidthPx,
    required this.screenHeightPx,
    required this.densityDpi,
    required this.socTags,
    required this.orientation,
    required this.ui,
    this.guardSystemBars = false,
  });

  bool get landscape => orientation == ScreenOrientation.landscape;

  // Логический размер в dp.
  double get logicalWidthDp => screenWidthPx / (densityDpi / 160);
  double get logicalHeightDp => screenHeightPx / (densityDpi / 160);

  // Порт ttyS4 (UART4) совпадает с надписью «ttys4/RS485» у DB9 (проба
  // 10.10.2026, docs/hardware.md).
  static const sy156a510 = HardwareProfile._(
    id: fallbackId,
    title: 'Syoung SY156-A510, 15.6", 1080x1920, портрет',
    defaultBusPort: '/dev/ttyS4',
    screenWidthPx: 1080,
    screenHeightPx: 1920,
    densityDpi: 240,
    socTags: ['rk3562'],
    orientation: ScreenOrientation.portrait,
    ui: UiMetrics.portrait,
  );

  // Прежний планшет CARFOG-001: RS485 на ttyS5 (UART5 fe690000; проба
  // 03.11.2026 — ответили термопара, счётчик и CWT). ttyS1 там занят
  // 4G-модемом. Матрица альбомная 1280x800, плотность 240 → 853x533 dp;
  // планшет стоит горизонтально (решение владельца 03.11.2026), поворот в
  // системе закреплён на ROTATION_0 — интерфейс альбомный.
  static const ixp101m1 = HardwareProfile._(
    id: 'ixp101m1',
    title: 'IXP101M1, 10.1", 1280x800, альбом',
    defaultBusPort: '/dev/ttyS5',
    screenWidthPx: 1280,
    screenHeightPx: 800,
    densityDpi: 240,
    socTags: ['rk3568'],
    orientation: ScreenOrientation.landscape,
    ui: UiMetrics.landscape,
    guardSystemBars: true,
  );

  static const List<HardwareProfile> all = [sy156a510, ixp101m1];

  // Неизвестное устройство считается основным планшетом (как до 1.11).
  static const HardwareProfile fallback = sy156a510;
  // Он же — профиль спецификации по умолчанию (DeviceSpec, const-контекст).
  static const String fallbackId = 'sy156-a510';

  // Профиль этого запуска: выставляется один раз при старте (main.dart).
  static HardwareProfile current = fallback;

  static HardwareProfile? byId(String? id) {
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }

  // Выбор профиля по свойствам устройства: сначала по чипу (board, device,
  // model, hardware), затем по длинной стороне экрана в пикселях; ничего не
  // подошло — fallback.
  static HardwareProfile detect({
    List<String?> props = const [],
    int? longSidePx,
  }) {
    final text = props.whereType<String>().join(' ').toLowerCase();
    for (final p in all) {
      if (p.socTags.any(text.contains)) return p;
    }
    if (longSidePx != null && longSidePx > 0) {
      for (final p in all) {
        final long = p.screenWidthPx > p.screenHeightPx
            ? p.screenWidthPx
            : p.screenHeightPx;
        if (long == longSidePx) return p;
      }
    }
    return fallback;
  }

  // Метка для релизного примечания (tool/build_release.sh берёт её отсюда же,
  // не хранит свою копию).
  static const String releaseNote =
      'универсальная: SY156-A510 (портрет) и IXP101M1 (альбом)';
}
