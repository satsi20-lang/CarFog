import 'package:flutter/foundation.dart';
import 'brand_colors.dart';

/// Пути встроенных ассетов бренда CaRFog (assets/brand/default/).
class BrandAssets {
  BrandAssets._();

  static const String defaultLogo = 'assets/brand/default/logo.png';
  static const String defaultQr = 'assets/brand/default/qr.png';
}

/// Применённый на экране бренд. Встроенный CaRFog — [Brand.builtin].
@immutable
class Brand {
  const Brand({
    required this.id,
    required this.version,
    required this.name,
    required this.colors,
    this.slogan = '',
    this.logoPath,
    this.qrPath,
  });

  /// id встроенного бренда (в базе — служебная запись без версий).
  static const String builtinId = 'carfog';

  /// Встроенный бренд: ровно текущий вид приложения. Название — то, что
  /// заставка показывала всегда; слоган пустой — действует `standby.subtitle`
  /// по языкам; логотипа нет (вид заставки не меняется).
  static const Brand builtin = Brand(
    id: builtinId,
    version: 0,
    name: 'CaRFog OÜ',
    colors: BrandColors.carfog,
  );

  final String id;
  final int version;
  final String name;
  final BrandColors colors;

  /// Слоган, английский, одна строка для всех языков. '' — встроенная подпись.
  final String slogan;

  /// Файлы пакета на устройстве (logo.png, qr_default.png) или null.
  final String? logoPath;
  final String? qrPath;

  bool get isBuiltin => id == builtinId;

  @override
  bool operator ==(Object other) =>
      other is Brand &&
      other.id == id &&
      other.version == version &&
      other.name == name &&
      other.colors == colors &&
      other.slogan == slogan &&
      other.logoPath == logoPath &&
      other.qrPath == qrPath;

  @override
  int get hashCode =>
      Object.hash(id, version, name, colors, slogan, logoPath, qrPath);
}

/// Активный бренд экрана. Тема приложения (BrandColors) и заставка берут его
/// отсюда; меняет его только BrandService и только на заставке.
class BrandController extends ChangeNotifier {
  BrandController([Brand initial = Brand.builtin]) : _active = initial;

  static final BrandController instance = BrandController();

  Brand _active;
  Brand get active => _active;

  void setActive(Brand brand) {
    if (brand == _active) return;
    _active = brand;
    notifyListeners();
  }
}
