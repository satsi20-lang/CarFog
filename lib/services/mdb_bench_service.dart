import 'package:flutter/services.dart';

// Стенд терминала Nayax по MDB через USB-адаптер Wafer (1.10.9) — тонкая
// обёртка над каналом MdbUsbBench.kt. Вся логика (протокол, журнал, файл
// mdb_bench.log) — на стороне Kotlin, здесь только вызовы. Боевая оплата
// этим сервисом не пользуется.

class MdbUsbDevice {
  final String device;
  final int vendorId;
  final int productId;
  final String? manufacturer;
  final String? product;
  final int deviceClass;
  final List<int> interfaceClasses;
  final bool hasPermission;
  final String? driver;

  MdbUsbDevice.fromMap(Map<dynamic, dynamic> m)
      : device = m['device'] as String,
        vendorId = m['vendorId'] as int,
        productId = m['productId'] as int,
        manufacturer = m['manufacturer'] as String?,
        product = m['product'] as String?,
        deviceClass = m['deviceClass'] as int,
        interfaceClasses =
            (m['interfaceClasses'] as List? ?? const []).cast<int>(),
        hasPermission = m['hasPermission'] as bool? ?? false,
        driver = m['driver'] as String?;

  static String hex4(int v) => v.toRadixString(16).toUpperCase().padLeft(4, '0');

  String get title =>
      'VID ${hex4(vendorId)} PID ${hex4(productId)} — '
      '${manufacturer ?? '?'} / ${product ?? '?'}';
}

class MdbBenchStatus {
  final bool open;
  final String? device;
  final int? setupScale;
  final int? setupDecimals;
  final String? logFile;

  const MdbBenchStatus({
    this.open = false,
    this.device,
    this.setupScale,
    this.setupDecimals,
    this.logFile,
  });

  MdbBenchStatus.fromMap(Map<dynamic, dynamic> m)
      : open = m['open'] as bool? ?? false,
        device = m['device'] as String?,
        setupScale = m['setupScale'] as int?,
        setupDecimals = m['setupDecimals'] as int?,
        logFile = m['logFile'] as String?;

  bool get hasSetup => setupScale != null && setupDecimals != null;
}

class MdbBenchService {
  MdbBenchService._();

  static const _channel = MethodChannel('com.carfog.dryfog/mdb_bench');

  static Future<List<MdbUsbDevice>> listDevices() async {
    final r = await _channel.invokeMethod<List>('listDevices') ?? const [];
    return r.map((e) => MdbUsbDevice.fromMap(e as Map)).toList();
  }

  // 'opened' или 'permission_requested' (порт откроется сам после согласия
  // в системном диалоге). Ошибка — PlatformException с текстом.
  static Future<String> open(String device, {String driver = 'auto'}) async =>
      await _channel.invokeMethod<String>('open', {
        'device': device,
        'driver': driver,
      }) ??
      '';

  static Future<void> close() => _channel.invokeMethod('close');

  static Future<MdbBenchStatus> status() async {
    final r = await _channel.invokeMethod<Map>('status');
    return r == null ? const MdbBenchStatus() : MdbBenchStatus.fromMap(r);
  }

  // Возвращает отправленные байты в hex.
  static Future<String> command(String name, {String? amount, int item = 1}) async =>
      await _channel.invokeMethod<String>('command', {
        'name': name,
        'amount': ?amount,
        'item': item,
      }) ??
      '';

  static Future<String> raw(String hex) async =>
      await _channel.invokeMethod<String>('raw', {'hex': hex}) ?? '';

  static Future<List<({int seq, String line})>> getLog(int since) async {
    final r = await _channel.invokeMethod<List>('getLog', {'since': since}) ??
        const [];
    return r.map((e) {
      final m = e as Map;
      return (seq: (m['seq'] as num).toInt(), line: m['line'] as String);
    }).toList();
  }

  static Future<String> allLog() async =>
      await _channel.invokeMethod<String>('allLog') ?? '';

  static Future<void> clearLog() => _channel.invokeMethod('clearLog');

  // Проверка hex-ввода до отправки (та же, что MdbCashlessProtocol.parseHex):
  // null — ввод верный, иначе текст ошибки.
  static String? validateHex(String text) {
    final s = text.replaceAll(RegExp(r'\s'), '').toUpperCase();
    if (s.isEmpty) return 'пустой ввод';
    if (s.length.isOdd) return 'нужна чётная длина';
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(s)) return 'только символы 0-9 A-F';
    return null;
  }
}
