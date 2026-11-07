import 'package:flutter/material.dart';

/// Семь токенов цвета бренда (ТЗ docs/brands_tz.md, раздел 4).
///
/// Встроенный бренд [BrandColors.carfog] — РОВНО текущие значения приложения
/// (опись docs/inventory/brand_inventory.md): эталоны Syoung не меняются.
/// Два акцента (`primary` и `primaryAlt`) НЕ сливаются: они отличаются на
/// несколько единиц, и слияние сдвинуло бы эталоны.
///
/// Смысловые цвета (ошибка, нагрев, предупреждение, обработка), сервисное
/// меню и экран PIN токенами не являются и брендом не меняются.
@immutable
class BrandColors extends ThemeExtension<BrandColors> {
  const BrandColors({
    required this.primary,
    required this.primaryAlt,
    required this.background,
    required this.backgroundStandby,
    required this.surface,
    required this.textPrimary,
    required this.textSecondary,
  });

  final Color primary;
  final Color primaryAlt;
  final Color background;
  final Color backgroundStandby;
  final Color surface;
  final Color textPrimary;
  final Color textSecondary;

  /// Встроенный бренд CaRFog.
  static const BrandColors carfog = BrandColors(
    primary: Color(0xFF2EC4B6),
    primaryAlt: Color(0xFF00C6B2),
    background: Color(0xFF1A1A1A),
    backgroundStandby: Color(0xFF0B2545),
    surface: Color(0xFF2E2E2E),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFF8899AA),
  );

  /// Порядок и имена токенов — как в brand.json и brand_rules.ts.
  static const List<String> tokens = [
    'primary',
    'primaryAlt',
    'background',
    'backgroundStandby',
    'surface',
    'textPrimary',
    'textSecondary',
  ];

  /// Токен по имени (для проверки контраста); null — такого токена нет.
  Color? byName(String name) => switch (name) {
        'primary' => primary,
        'primaryAlt' => primaryAlt,
        'background' => background,
        'backgroundStandby' => backgroundStandby,
        'surface' => surface,
        'textPrimary' => textPrimary,
        'textSecondary' => textSecondary,
        _ => null,
      };

  /// textPrimary с точной прозрачностью (white70 = 0xB3, white60 = 0x99,
  /// white38 = 0x62, white24 = 0x3D): для встроенного бренда совпадает с
  /// Colors.whiteNN до бита.
  Color textPrimaryA(int alpha) => textPrimary.withAlpha(alpha);

  @override
  BrandColors copyWith({
    Color? primary,
    Color? primaryAlt,
    Color? background,
    Color? backgroundStandby,
    Color? surface,
    Color? textPrimary,
    Color? textSecondary,
  }) =>
      BrandColors(
        primary: primary ?? this.primary,
        primaryAlt: primaryAlt ?? this.primaryAlt,
        background: background ?? this.background,
        backgroundStandby: backgroundStandby ?? this.backgroundStandby,
        surface: surface ?? this.surface,
        textPrimary: textPrimary ?? this.textPrimary,
        textSecondary: textSecondary ?? this.textSecondary,
      );

  @override
  BrandColors lerp(ThemeExtension<BrandColors>? other, double t) {
    if (other is! BrandColors) return this;
    return BrandColors(
      primary: Color.lerp(primary, other.primary, t)!,
      primaryAlt: Color.lerp(primaryAlt, other.primaryAlt, t)!,
      background: Color.lerp(background, other.background, t)!,
      backgroundStandby:
          Color.lerp(backgroundStandby, other.backgroundStandby, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BrandColors &&
      other.primary == primary &&
      other.primaryAlt == primaryAlt &&
      other.background == background &&
      other.backgroundStandby == backgroundStandby &&
      other.surface == surface &&
      other.textPrimary == textPrimary &&
      other.textSecondary == textSecondary;

  @override
  int get hashCode => Object.hash(primary, primaryAlt, background,
      backgroundStandby, surface, textPrimary, textSecondary);
}

/// `context.brand` — токены активного бренда. Если в теме расширения нет
/// (тесты без брендовой темы), берётся встроенный CaRFog.
extension BrandContext on BuildContext {
  BrandColors get brand =>
      Theme.of(this).extension<BrandColors>() ?? BrandColors.carfog;
}
