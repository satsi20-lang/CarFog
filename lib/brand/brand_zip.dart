import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'brand_rules.dart';

/// Ошибка чтения архива. [code] — короткий код для события brand_failed
/// (после «zip:»).
class BrandZipException implements Exception {
  const BrandZipException(this.code);
  final String code;
  @override
  String toString() => 'BrandZipException($code)';
}

/// Читает zip пакета бренда целиком в памяти (архив ≤ 1 МБ) с защитами:
/// ≤8 файлов, имена только из белого списка (без путей и `..`), без
/// дубликатов, методы 0 (store) и 8 (deflate), без шифрования и zip64,
/// суммарно ≤3 МБ распакованных, настоящий размер сверяется с заявленным,
/// CRC32 проверяется. Распаковка идёт кусками и обрывается, как только
/// вывод превышает заявленный размер (zip-бомба с ложным заголовком).
Map<String, Uint8List> readBrandZip(Uint8List zip) {
  if (zip.length > BrandLimits.maxZipBytes) throw const BrandZipException('too_big');
  final bd = ByteData.sublistView(zip);

  // Конец центрального каталога: подпись 0x06054b50, комментарий ≤ 65535.
  int eocd = -1;
  final from = zip.length - 22;
  final stop = from - 65535 < 0 ? 0 : from - 65535;
  for (var i = from; i >= stop; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const BrandZipException('no_eocd');
  final total = bd.getUint16(eocd + 10, Endian.little);
  final cdSize = bd.getUint32(eocd + 12, Endian.little);
  final cdOff = bd.getUint32(eocd + 16, Endian.little);
  if (total == 0xFFFF || cdSize == 0xFFFFFFFF || cdOff == 0xFFFFFFFF) {
    throw const BrandZipException('zip64');
  }
  if (bd.getUint16(eocd + 4, Endian.little) != 0 ||
      bd.getUint16(eocd + 6, Endian.little) != 0) {
    throw const BrandZipException('multi_disk');
  }
  if (total == 0) throw const BrandZipException('empty');
  if (total > BrandLimits.maxZipEntries) throw const BrandZipException('too_many');
  if (cdOff + cdSize > eocd) throw const BrandZipException('bad_dir');

  final out = <String, Uint8List>{};
  var pos = cdOff;
  var declaredTotal = 0;
  for (var n = 0; n < total; n++) {
    if (pos + 46 > eocd || bd.getUint32(pos, Endian.little) != 0x02014b50) {
      throw const BrandZipException('bad_dir');
    }
    final flags = bd.getUint16(pos + 8, Endian.little);
    final method = bd.getUint16(pos + 10, Endian.little);
    final crc = bd.getUint32(pos + 16, Endian.little);
    final csize = bd.getUint32(pos + 20, Endian.little);
    final usize = bd.getUint32(pos + 24, Endian.little);
    final nameLen = bd.getUint16(pos + 28, Endian.little);
    final extraLen = bd.getUint16(pos + 30, Endian.little);
    final commentLen = bd.getUint16(pos + 32, Endian.little);
    final localOff = bd.getUint32(pos + 42, Endian.little);
    if (pos + 46 + nameLen + extraLen + commentLen > eocd) {
      throw const BrandZipException('bad_dir');
    }
    final name = String.fromCharCodes(zip.sublist(pos + 46, pos + 46 + nameLen));
    pos += 46 + nameLen + extraLen + commentLen;

    if (flags & 1 != 0) throw const BrandZipException('encrypted');
    if (csize == 0xFFFFFFFF || usize == 0xFFFFFFFF) throw const BrandZipException('zip64');
    if (!BrandLimits.allowedNames.contains(name)) throw const BrandZipException('name');
    if (out.containsKey(name)) throw const BrandZipException('duplicate');
    if (method != 0 && method != 8) throw const BrandZipException('method');
    if (method == 0 && csize != usize) throw const BrandZipException('bad_size');
    declaredTotal += usize;
    if (declaredTotal > BrandLimits.maxUnpackedBytes) {
      throw const BrandZipException('unpacked_too_big');
    }

    // Локальный заголовок: подпись, то же имя; данные сразу за ним.
    if (localOff + 30 > cdOff || bd.getUint32(localOff, Endian.little) != 0x04034b50) {
      throw const BrandZipException('bad_local');
    }
    final lName = bd.getUint16(localOff + 26, Endian.little);
    final lExtra = bd.getUint16(localOff + 28, Endian.little);
    final dataOff = localOff + 30 + lName + lExtra;
    if (dataOff + csize > cdOff) throw const BrandZipException('bad_local');
    final localName = String.fromCharCodes(zip.sublist(localOff + 30, localOff + 30 + lName));
    if (localName != name) throw const BrandZipException('bad_local');

    final comp = Uint8List.sublistView(zip, dataOff, dataOff + csize);
    final data = method == 0 ? Uint8List.fromList(comp) : _inflate(comp, usize);
    if (data.length != usize) throw const BrandZipException('bad_size');
    if (_crc32(data) != crc) throw const BrandZipException('crc');
    out[name] = data;
  }
  return out;
}

Uint8List _inflate(Uint8List comp, int expected) {
  final buf = BytesBuilder(copy: false);
  var written = 0;
  final sink = _ByteSink((chunk) {
    written += chunk.length;
    if (written > expected) throw const BrandZipException('bomb');
    buf.add(chunk);
  });
  try {
    final conv = ZLibDecoder(raw: true).startChunkedConversion(sink);
    // Малые куски: один кусок сжатых данных не должен разворачиваться в
    // десятки мегабайт до проверки размера.
    const step = 512;
    for (var i = 0; i < comp.length; i += step) {
      final end = i + step > comp.length ? comp.length : i + step;
      conv.add(Uint8List.sublistView(comp, i, end));
    }
    conv.close();
  } on BrandZipException {
    rethrow;
  } catch (_) {
    throw const BrandZipException('inflate');
  }
  return buf.toBytes();
}

class _ByteSink implements Sink<List<int>> {
  _ByteSink(this._on);
  final void Function(List<int>) _on;
  @override
  void add(List<int> data) => _on(data);
  @override
  void close() {}
}

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(Uint8List d) {
  var c = 0xFFFFFFFF;
  for (final b in d) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Для тестов: CRC32 данных.
int crc32ForTest(Uint8List d) => _crc32(d);
