import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'brand_colors.dart';

// Правила пакета бренда на стороне аппарата. Зеркало
// supabase/functions/_shared/brand_rules.ts (единственный источник правил,
// ветка brand-stage1-db) и src/brand_rules.ts портала. Меняя число здесь,
// меняйте его и там: test/brand_rules_test.dart сверяет их с константами,
// снятыми из brand_rules.ts.

class BrandLimits {
  BrandLimits._();

  static const int maxZipBytes = 1048576; // MAX_ZIP_BYTES
  static const int maxLogoBytes = 307200; // MAX_LOGO_BYTES
  static const int maxPngSide = 1000; // MAX_PNG_SIDE
  static const int maxZipEntries = 8; // MAX_ZIP_ENTRIES
  static const int maxUnpackedBytes = 3 * 1048576; // MAX_UNPACKED_BYTES
  static const int maxNameLen = 40; // MAX_NAME_LEN
  static const int maxSloganLen = 80; // MAX_SLOGAN_LEN
  static const int schema = 1; // BRAND_SCHEMA
  static const List<String> allowedNames = [
    'brand.json',
    'logo.png',
    'qr_default.png',
  ]; // ALLOWED_ZIP_NAMES
}

/// id бренда: как BRAND_ID_RE на сервере.
final RegExp brandIdRe = RegExp(r'^[a-z0-9][a-z0-9_-]{1,30}$');

/// Токены цвета (порядок как COLOR_TOKENS).
const List<String> brandColorTokens = [
  'primary',
  'primaryAlt',
  'background',
  'backgroundStandby',
  'surface',
  'textPrimary',
  'textSecondary',
];

class ContrastRule {
  const ContrastRule(this.fg, this.bg, this.min);
  final String fg;
  final String bg;
  final double min;
}

/// Те же пары и пороги, что CONTRAST_RULES на сервере.
const List<ContrastRule> contrastRules = [
  ContrastRule('textPrimary', 'background', 4.5),
  ContrastRule('textPrimary', 'surface', 4.5),
  ContrastRule('textPrimary', 'backgroundStandby', 4.5),
  ContrastRule('textSecondary', 'background', 3.0),
  ContrastRule('primary', 'background', 3.0),
];

final RegExp _hexRe = RegExp(r'^#[0-9a-fA-F]{6}$');
final RegExp _controlRe = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

/// '#RRGGBB' → [r,g,b]; null — не цвет.
List<int>? parseHexColor(Object? v) {
  if (v is! String || !_hexRe.hasMatch(v)) return null;
  return [
    int.parse(v.substring(1, 3), radix: 16),
    int.parse(v.substring(3, 5), radix: 16),
    int.parse(v.substring(5, 7), radix: 16),
  ];
}

/// Относительная яркость по WCAG 2.x (sRGB), формула brand_rules.ts.
double relativeLuminance(List<int> rgb) {
  double ch(int c) {
    final s = c / 255;
    return s <= 0.03928 ? s / 12.92 : _pow((s + 0.055) / 1.055, 2.4);
  }

  return 0.2126 * ch(rgb[0]) + 0.7152 * ch(rgb[1]) + 0.0722 * ch(rgb[2]);
}

double _pow(double x, double y) => math.pow(x, y).toDouble();

/// Контраст двух цветов (1…21); null — цвет не разобран.
double? contrastRatio(String a, String b) {
  final ra = parseHexColor(a);
  final rb = parseHexColor(b);
  if (ra == null || rb == null) return null;
  final la = relativeLuminance(ra);
  final lb = relativeLuminance(rb);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// null — все пары прошли; иначе 'fg/bg' первой непрошедшей.
String? firstContrastFailure(Map<String, String> colors) {
  for (final r in contrastRules) {
    final fg = colors[r.fg];
    final bg = colors[r.bg];
    final ratio = (fg == null || bg == null) ? null : contrastRatio(fg, bg);
    if (ratio == null || ratio < r.min) return '${r.fg}/${r.bg}';
  }
  return null;
}

// ---------- PNG ----------

const List<int> _pngSig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/// Размеры PNG из IHDR; null — не PNG (подпись, блок IHDR длиной 13).
({int width, int height})? pngSize(Uint8List b) {
  if (b.length < 24) return null;
  for (var i = 0; i < _pngSig.length; i++) {
    if (b[i] != _pngSig[i]) return null;
  }
  final len = (b[8] << 24) | (b[9] << 16) | (b[10] << 8) | b[11];
  if (len != 13 || b[12] != 0x49 || b[13] != 0x48 || b[14] != 0x44 || b[15] != 0x52) {
    return null;
  }
  int rd(int o) => ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);
  final w = rd(16);
  final h = rd(20);
  if (w < 1 || h < 1) return null;
  return (width: w, height: h);
}

/// Код ошибки картинки или null, если годна: too_big / not_png / side.
String? checkPng(Uint8List b, int maxBytes) {
  if (b.length > maxBytes) return 'too_big';
  final s = pngSize(b);
  if (s == null) return 'not_png';
  if (s.width > BrandLimits.maxPngSide || s.height > BrandLimits.maxPngSide) {
    return 'side';
  }
  return null;
}

// ---------- brand.json ----------

class BrandManifest {
  BrandManifest({
    required this.id,
    required this.version,
    required this.name,
    required this.slogan,
    required this.colors,
    required this.hasQr,
    required this.colorsHex,
  });
  final String id;
  final int version;
  final String name;
  final String slogan;
  final BrandColors colors;
  final bool hasQr;

  /// Цвета как '#RRGGBB' (верхний регистр) — для проверки контраста.
  final Map<String, String> colorsHex;
}

class ManifestResult {
  ManifestResult.ok(this.manifest) : error = null;
  ManifestResult.fail(this.error) : manifest = null;
  final BrandManifest? manifest;

  /// Короткий код: schema / id / version / name / slogan / colors /
  /// color:<токен> / unknown_key / logo / qr / not_object.
  final String? error;
}

const Set<String> _manifestKeys = {
  'schema',
  'id',
  'version',
  'name',
  'colors',
  'slogan',
  'logo',
  'qr_default',
};

/// Проверка brand.json по схеме 1 (validateManifest). Лишние ключи — отказ.
ManifestResult validateManifest(Object? raw, {required String wantId, required int wantVersion}) {
  if (raw is! Map) return ManifestResult.fail('not_object');
  for (final k in raw.keys) {
    if (k is! String || !_manifestKeys.contains(k)) return ManifestResult.fail('unknown_key');
  }
  if (raw['schema'] != BrandLimits.schema) return ManifestResult.fail('schema');
  final id = raw['id'];
  if (id is! String || !brandIdRe.hasMatch(id) || id != wantId) {
    return ManifestResult.fail('id');
  }
  final version = raw['version'];
  if (version is! int || version < 1 || version != wantVersion) {
    return ManifestResult.fail('version');
  }
  final name = raw['name'];
  if (name is! String ||
      name.trim().isEmpty ||
      name.length > BrandLimits.maxNameLen ||
      _controlRe.hasMatch(name)) {
    return ManifestResult.fail('name');
  }
  final sloganRaw = raw['slogan'];
  final slogan = sloganRaw ?? '';
  if (slogan is! String ||
      slogan.length > BrandLimits.maxSloganLen ||
      _controlRe.hasMatch(slogan)) {
    return ManifestResult.fail('slogan');
  }
  final c = raw['colors'];
  if (c is! Map) return ManifestResult.fail('colors');
  for (final k in c.keys) {
    if (k is! String || !brandColorTokens.contains(k)) return ManifestResult.fail('colors');
  }
  final hex = <String, String>{};
  for (final t in brandColorTokens) {
    if (parseHexColor(c[t]) == null) return ManifestResult.fail('color:$t');
    hex[t] = (c[t] as String).toUpperCase();
  }
  if (raw['logo'] != 'logo.png') return ManifestResult.fail('logo');
  final qr = raw['qr_default'];
  if (qr != null && qr != 'qr_default.png') return ManifestResult.fail('qr');

  Color col(String t) {
    final v = parseHexColor(hex[t])!;
    return Color.fromARGB(255, v[0], v[1], v[2]);
  }

  return ManifestResult.ok(BrandManifest(
    id: id,
    version: version,
    name: name.trim(),
    slogan: slogan,
    hasQr: qr == 'qr_default.png',
    colorsHex: hex,
    colors: BrandColors(
      primary: col('primary'),
      primaryAlt: col('primaryAlt'),
      background: col('background'),
      backgroundStandby: col('backgroundStandby'),
      surface: col('surface'),
      textPrimary: col('textPrimary'),
      textSecondary: col('textSecondary'),
    ),
  ));
}
