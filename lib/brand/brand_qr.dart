import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'brand.dart';

/// QR заставки. Порядок выбора (ТЗ, раздел 7.3):
///  а) у аппарата задана ссылка [url] — QR рисуется из неё, логотип бренда в
///     центре, уровень коррекции H;
///  б) иначе картинка qr_default.png бренда;
///  в) иначе встроенный QR CaRFog.
class BrandQr extends StatelessWidget {
  const BrandQr({
    super.key,
    required this.brand,
    required this.url,
    required this.size,
    this.errorBuilder,
  });

  final Brand brand;

  /// Ссылка QR аппарата ('' — не задана).
  final String url;
  final double size;
  final ImageErrorWidgetBuilder? errorBuilder;

  /// Доля стороны QR под логотипом. Уровень H исправляет до ~30 % площади;
  /// логотип занимает не больше (0,2)² = 4 % — большой запас (проверяет тест).
  static const double logoFraction = 0.2;

  /// Размер логотипа в центре QR с сохранением пропорций: бо́льшая сторона —
  /// logoFraction стороны QR, площадь не больше (logoFraction)².
  static Size embeddedLogoSize(double side, double aspect) {
    final a = aspect.isFinite && aspect > 0 ? aspect : 1.0;
    final long = side * logoFraction;
    return a >= 1 ? Size(long, long / a) : Size(long * a, long);
  }

  static final Map<String, double> _aspects = {};

  /// Пропорции PNG по заголовку IHDR (ширина/высота); 1 — если не прочитать.
  /// Файл пакета уже проверен BrandService, читаем только первые 24 байта.
  static double pngAspect(String path) {
    return _aspects.putIfAbsent(path, () {
      try {
        final raf = File(path).openSync();
        try {
          final b = raf.readSync(24);
          if (b.length < 24) return 1.0;
          int u32(int o) =>
              (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
          final w = u32(16), h = u32(20);
          return w > 0 && h > 0 ? w / h : 1.0;
        } finally {
          raf.closeSync();
        }
      } catch (_) {
        return 1.0;
      }
    });
  }

  /// Пропорции встроенного логотипа CaRFog (assets/brand/default/logo.png, 100×106).
  static const double builtinLogoAspect = 100 / 106;

  /// Белая рамка вокруг QR (тихая зона), доля стороны.
  static const double quietFraction = 0.04;

  @override
  Widget build(BuildContext context) {
    if (url.isNotEmpty) {
      final logo = brand.logoPath != null
          ? FileImage(File(brand.logoPath!))
          : const AssetImage(BrandAssets.defaultLogo) as ImageProvider;
      return QrImageView(
        key: const ValueKey('standby_qr_url'),
        data: url,
        size: size,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.H,
        backgroundColor: Colors.white,
        padding: EdgeInsets.all(size * quietFraction),
        embeddedImage: logo,
        embeddedImageStyle: QrEmbeddedImageStyle(
          size: embeddedLogoSize(
            size,
            brand.logoPath != null
                ? pngAspect(brand.logoPath!)
                : builtinLogoAspect,
          ),
        ),
        errorStateBuilder: (_, _) => const SizedBox.shrink(),
      );
    }
    if (brand.qrPath != null) {
      return Image.file(
        File(brand.qrPath!),
        key: const ValueKey('standby_qr_brand'),
        width: size,
        errorBuilder: (c, e, s) => _builtin(c, e, s),
      );
    }
    return _builtin(context, null, null);
  }

  Widget _builtin(BuildContext c, Object? e, StackTrace? s) => Image.asset(
    BrandAssets.defaultQr,
    key: const ValueKey('standby_qr_builtin'),
    width: size,
    errorBuilder: errorBuilder,
  );
}
