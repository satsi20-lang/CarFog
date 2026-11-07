import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dry_fog_app/brand/brand_zip.dart';

// Помощники тестов пакета бренда: сборка zip (store/deflate) и PNG-заглушки.

/// Минимальный «PNG»: подпись + IHDR нужного размера (для проверок сторон).
Uint8List fakePng({int w = 64, int h = 64, int pad = 0}) {
  final b = BytesBuilder();
  b.add([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  b.add([0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  void u32(int v) => b.add([(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255]);
  u32(w);
  u32(h);
  b.add([8, 6, 0, 0, 0]);
  u32(0); // crc IHDR (не проверяется)
  if (pad > 0) b.add(Uint8List(pad));
  return b.toBytes();
}

Map<String, Object?> manifestMap({
  String id = 'acme',
  int version = 1,
  String name = 'Acme Fog',
  String slogan = 'Fresh air',
  Map<String, String>? colors,
  bool qr = false,
  Map<String, Object?> extra = const {},
}) =>
    {
      'schema': 1,
      'id': id,
      'version': version,
      'name': name,
      'slogan': slogan,
      'colors': colors ??
          {
            'primary': '#FF8800',
            'primaryAlt': '#FFAA33',
            'background': '#101010',
            'backgroundStandby': '#201030',
            'surface': '#303030',
            'textPrimary': '#FFFFFF',
            'textSecondary': '#B0B0B0',
          },
      'logo': 'logo.png',
      if (qr) 'qr_default': 'qr_default.png',
      ...extra,
    };

class ZipEntry {
  ZipEntry(this.name, this.data, {this.deflate = false, this.rawCompressed, this.declaredSize});
  final String name;
  final Uint8List data;
  final bool deflate;

  /// Подмена сжатых байт (для zip-бомбы с ложным заголовком).
  final Uint8List? rawCompressed;
  final int? declaredSize;
}

Uint8List buildZip(List<ZipEntry> entries, {bool encrypt = false}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255]);
  void u32(BytesBuilder b, int v) =>
      b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  for (final e in entries) {
    final nameBytes = utf8.encode(e.name);
    final comp = e.rawCompressed ??
        (e.deflate ? Uint8List.fromList(ZLibCodec(raw: true).encode(e.data)) : e.data);
    final method = (e.deflate || e.rawCompressed != null) ? 8 : 0;
    final crc = crc32ForTest(e.data);
    final usize = e.declaredSize ?? e.data.length;
    final flags = encrypt ? 1 : 0;
    final offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, flags);
    u16(out, method);
    u32(out, 0);
    u32(out, crc);
    u32(out, comp.length);
    u32(out, usize);
    u16(out, nameBytes.length);
    u16(out, 0);
    out.add(nameBytes);
    out.add(comp);

    u32(central, 0x02014b50);
    u16(central, 20);
    u16(central, 20);
    u16(central, flags);
    u16(central, method);
    u32(central, 0);
    u32(central, crc);
    u32(central, comp.length);
    u32(central, usize);
    u16(central, nameBytes.length);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0);
    u32(central, 0);
    u32(central, offset);
    central.add(nameBytes);
  }
  final cdOff = out.length;
  out.add(central.toBytes());
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, central.length);
  u32(out, cdOff);
  u16(out, 0);
  return out.toBytes();
}

/// Годный пакет: brand.json + logo.png (+ qr_default.png).
Uint8List goodZip({
  Map<String, Object?>? manifest,
  bool qr = false,
  bool deflate = true,
  Uint8List? logo,
  List<ZipEntry> extra = const [],
}) =>
    buildZip([
      ZipEntry('brand.json', Uint8List.fromList(utf8.encode(jsonEncode(manifest ?? manifestMap(qr: qr)))),
          deflate: deflate),
      ZipEntry('logo.png', logo ?? fakePng(), deflate: false),
      if (qr) ZipEntry('qr_default.png', fakePng(w: 200, h: 200), deflate: false),
      ...extra,
    ]);
