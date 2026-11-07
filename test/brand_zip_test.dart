import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dry_fog_app/brand/brand_rules.dart';
import 'package:dry_fog_app/brand/brand_zip.dart';
import 'package:flutter_test/flutter_test.dart';

import 'brand_test_util.dart';

void main() {
  String code(Uint8List z) {
    try {
      readBrandZip(z);
      return 'ok';
    } on BrandZipException catch (e) {
      return e.code;
    }
  }

  Uint8List txt(String s) => Uint8List.fromList(utf8.encode(s));

  test('годный архив: store и deflate', () {
    for (final deflate in [false, true]) {
      final files = readBrandZip(goodZip(deflate: deflate, qr: true));
      expect(files.keys.toSet(), {'brand.json', 'logo.png', 'qr_default.png'});
      expect(files['logo.png'], fakePng());
    }
  });

  test('чужие имена, путь, ..: отказ', () {
    expect(code(goodZip(extra: [ZipEntry('evil.txt', txt('x'))])), 'name');
    expect(code(goodZip(extra: [ZipEntry('../x', txt('x'))])), 'name');
    expect(code(goodZip(extra: [ZipEntry('a/logo.png', txt('x'))])), 'name');
    expect(code(goodZip(extra: [ZipEntry('/logo2.png', txt('x'))])), 'name');
  });

  test('дубликат имени', () {
    expect(code(goodZip(extra: [ZipEntry('logo.png', fakePng())])), 'duplicate');
  });

  test('больше 8 файлов', () {
    final z = buildZip([for (var i = 0; i < 9; i++) ZipEntry('logo.png', fakePng())]);
    expect(code(z), 'too_many');
  });

  test('архив больше 1 МБ', () {
    expect(code(Uint8List(BrandLimits.maxZipBytes + 1)), 'too_big');
  });

  test('не zip', () {
    expect(code(Uint8List.fromList(List.filled(100, 7))), 'no_eocd');
    expect(code(Uint8List(0)), 'no_eocd');
  });

  test('шифрование и неподдерживаемый метод', () {
    expect(code(buildZip([ZipEntry('logo.png', fakePng())], encrypt: true)), 'encrypted');
  });

  test('заявленный распакованный размер больше 3 МБ', () {
    final big = Uint8List(1024);
    final z = buildZip([
      ZipEntry('logo.png', big, rawCompressed: Uint8List.fromList(ZLibCodec(raw: true).encode(big)),
          declaredSize: BrandLimits.maxUnpackedBytes + 1),
    ]);
    expect(code(z), 'unpacked_too_big');
  });

  test('zip-бомба: заявлено мало, внутри много', () {
    final huge = Uint8List(2 * 1024 * 1024); // нули сжимаются в ~2 КБ
    final comp = Uint8List.fromList(ZLibCodec(raw: true).encode(huge));
    expect(comp.length, lessThan(10000));
    final z = buildZip([
      ZipEntry('logo.png', Uint8List(100), rawCompressed: comp, declaredSize: 100),
    ]);
    expect(code(z), 'bomb');
  });

  test('заявлено больше, чем внутри: bad_size', () {
    final data = fakePng();
    final comp = Uint8List.fromList(ZLibCodec(raw: true).encode(data));
    final z = buildZip([ZipEntry('logo.png', data, rawCompressed: comp, declaredSize: data.length + 50)]);
    expect(code(z), 'bad_size');
  });

  test('битые сжатые данные', () {
    final z = buildZip([
      ZipEntry('logo.png', fakePng(), rawCompressed: Uint8List.fromList(List.filled(40, 0xFF)), declaredSize: 40),
    ]);
    expect(code(z), anyOf('inflate', 'bomb'));
  });

  test('CRC не совпал', () {
    final z = goodZip(deflate: false);
    // портим один байт логотипа внутри архива (данные store)
    final i = _indexOf(z, fakePng());
    z[i + 30] ^= 0xFF;
    expect(code(z), 'crc');
  });

  test('усечённый архив', () {
    final z = goodZip();
    expect(code(Uint8List.sublistView(z, 0, z.length - 10)), isNot('ok'));
  });
}

int _indexOf(Uint8List hay, Uint8List needle) {
  outer:
  for (var i = 0; i <= hay.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
