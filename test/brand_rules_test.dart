import 'dart:typed_data';

import 'package:dry_fog_app/brand/brand_colors.dart';
import 'package:dry_fog_app/brand/brand_rules.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

import 'brand_test_util.dart';

String hex(Color c) =>
    '#${c.toARGB32().toRadixString(16).substring(2).toUpperCase()}';

void main() {
  // Числа ниже СНЯТЫ с supabase/functions/_shared/brand_rules.ts (ветка
  // brand-stage1-db). Менять их можно только вместе с сервером и порталом.
  test('пределы совпадают с brand_rules.ts', () {
    expect(BrandLimits.maxZipBytes, 1048576);
    expect(BrandLimits.maxLogoBytes, 307200);
    expect(BrandLimits.maxPngSide, 1000);
    expect(BrandLimits.maxZipEntries, 8);
    expect(BrandLimits.maxUnpackedBytes, 3145728);
    expect(BrandLimits.maxNameLen, 40);
    expect(BrandLimits.maxSloganLen, 80);
    expect(BrandLimits.schema, 1);
    expect(BrandLimits.allowedNames, ['brand.json', 'logo.png', 'qr_default.png']);
    expect(brandIdRe.pattern, r'^[a-z0-9][a-z0-9_-]{1,30}$');
    expect(brandColorTokens, [
      'primary',
      'primaryAlt',
      'background',
      'backgroundStandby',
      'surface',
      'textPrimary',
      'textSecondary',
    ]);
  });

  test('пары и пороги контраста совпадают с CONTRAST_RULES', () {
    final got = contrastRules.map((r) => '${r.fg}|${r.bg}|${r.min}').toList();
    expect(got, [
      'textPrimary|background|4.5',
      'textPrimary|surface|4.5',
      'textPrimary|backgroundStandby|4.5',
      'textSecondary|background|3.0',
      'primary|background|3.0',
    ]);
  });

  test('контраст: чёрный/белый = 21, формула WCAG, порядок не важен', () {
    expect(contrastRatio('#000000', '#FFFFFF'), closeTo(21, 1e-9));
    expect(contrastRatio('#FFFFFF', '#000000'), closeTo(21, 1e-9));
    expect(contrastRatio('#777777', '#777777'), closeTo(1, 1e-9));
    expect(contrastRatio('#12', '#FFFFFF'), isNull);
  });

  test('встроенный CaRFog проходит все пары, плохой бренд — нет', () {
    final carfog = <String, String>{for (final t in BrandColors.tokens) t: hex(BrandColors.carfog.byName(t)!)};
    expect(firstContrastFailure(carfog), isNull);
    final bad = {...carfog, 'textPrimary': '#222222'};
    expect(firstContrastFailure(bad), 'textPrimary/background');
    final badAccent = {...carfog, 'primary': '#202020'};
    expect(firstContrastFailure(badAccent), 'primary/background');
    final missing = {...carfog}..remove('surface');
    expect(firstContrastFailure(missing), 'textPrimary/surface');
  });

  group('PNG', () {
    test('годный, большой, не PNG, сторона', () {
      expect(checkPng(fakePng(), BrandLimits.maxLogoBytes), isNull);
      expect(checkPng(fakePng(pad: BrandLimits.maxLogoBytes), BrandLimits.maxLogoBytes), 'too_big');
      expect(checkPng(Uint8List.fromList(List.filled(40, 1)), BrandLimits.maxLogoBytes), 'not_png');
      expect(checkPng(fakePng(w: 1001), BrandLimits.maxLogoBytes), 'side');
      expect(checkPng(fakePng(w: 1000, h: 1000), BrandLimits.maxLogoBytes), isNull);
      expect(checkPng(fakePng(w: 0), BrandLimits.maxLogoBytes), 'not_png');
    });
  });

  group('brand.json', () {
    ManifestResult v(Object? raw, {String id = 'acme', int ver = 1}) =>
        validateManifest(raw, wantId: id, wantVersion: ver);

    test('годный манифест', () {
      final r = v(manifestMap());
      expect(r.error, isNull);
      expect(r.manifest!.name, 'Acme Fog');
      expect(r.manifest!.colors.primary.toARGB32(), 0xFFFF8800);
    });

    test('ошибки', () {
      expect(v('x').error, 'not_object');
      expect(v(manifestMap(extra: {'schema': 2})).error, 'schema');
      expect(v(manifestMap(id: 'other')).error, 'id');
      expect(v(manifestMap(), id: 'zzz').error, 'id');
      expect(v(manifestMap(version: 2)).error, 'version');
      expect(v(manifestMap(name: '')).error, 'name');
      expect(v(manifestMap(name: 'x' * 41)).error, 'name');
      expect(v(manifestMap(name: 'a\nb')).error, 'name');
      expect(v(manifestMap(slogan: 'x' * 81)).error, 'slogan');
      expect(v(manifestMap(extra: {'evil': 1})).error, 'unknown_key');
      expect(v(manifestMap(extra: {'logo': '../logo.png'})).error, 'logo');
      expect(v(manifestMap(extra: {'qr_default': 'a.png'})).error, 'qr');
      final c = Map<String, String>.from(manifestMap()['colors'] as Map);
      expect(v(manifestMap(colors: {...c, 'primary': 'red'})).error, 'color:primary');
      expect(v(manifestMap(colors: {...c, 'extra': '#FFFFFF'})).error, 'colors');
      expect((v(manifestMap(slogan: ''))).error, isNull);
    });

    test('цвета берутся в верхнем регистре', () {
      final c = Map<String, String>.from(manifestMap()['colors'] as Map)
        ..['primary'] = '#ff8800';
      expect(v(manifestMap(colors: c)).manifest!.colorsHex['primary'], '#FF8800');
    });
  });
}
