import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dry_fog_app/brand/brand_colors.dart';

void main() {
  test('встроенный бренд = текущие значения приложения, оба акцента раздельно',
      () {
    const c = BrandColors.carfog;
    expect(c.primary, const Color(0xFF2EC4B6));
    expect(c.primaryAlt, const Color(0xFF00C6B2));
    expect(c.background, const Color(0xFF1A1A1A));
    expect(c.backgroundStandby, const Color(0xFF0B2545));
    expect(c.surface, const Color(0xFF2E2E2E));
    expect(c.textPrimary, const Color(0xFFFFFFFF));
    expect(c.textSecondary, const Color(0xFF8899AA));
    expect(c.primary, isNot(c.primaryAlt));
  });

  test('прозрачности textPrimary совпадают с Colors.whiteNN до бита', () {
    const c = BrandColors.carfog;
    expect(c.textPrimaryA(0xB3), Colors.white70);
    expect(c.textPrimaryA(0x99), Colors.white60);
    expect(c.textPrimaryA(0x62), Colors.white38);
    expect(c.textPrimaryA(0x3D), Colors.white24);
  });

  test('токены доступны по имени, имена как в brand.json', () {
    expect(BrandColors.tokens, [
      'primary', 'primaryAlt', 'background', 'backgroundStandby', 'surface',
      'textPrimary', 'textSecondary',
    ]);
    for (final n in BrandColors.tokens) {
      expect(BrandColors.carfog.byName(n), isNotNull, reason: n);
    }
    expect(BrandColors.carfog.byName('error'), isNull);
  });

  testWidgets('context.brand: без расширения в теме — CaRFog, с ним — бренд',
      (tester) async {
    BrandColors? plain;
    BrandColors? custom;
    await tester.pumpWidget(MaterialApp(
      home: Builder(builder: (c) {
        plain = c.brand;
        return const SizedBox();
      }),
    ));
    const acme = BrandColors(
      primary: Color(0xFFE4572E),
      primaryAlt: Color(0xFFF28C28),
      background: Color(0xFF101820),
      backgroundStandby: Color(0xFF1B2A41),
      surface: Color(0xFF26344A),
      textPrimary: Color(0xFFFFFFFF),
      textSecondary: Color(0xFFB8C4D6),
    );
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: const [acme]),
      home: Builder(builder: (c) {
        custom = c.brand;
        return const SizedBox();
      }),
    ));
    await tester.pumpAndSettle(); // тема в MaterialApp меняется анимацией
    expect(plain, BrandColors.carfog);
    expect(custom, acme);
  });
}
