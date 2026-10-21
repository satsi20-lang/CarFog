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
      interfaceClasses = (m['interfaceClasses'] as List? ?? const [])
          .cast<int>(),
      hasPermission = m['hasPermission'] as bool? ?? false,
      driver = m['driver'] as String?;

  static String hex4(int v) =>
      v.toRadixString(16).toUpperCase().padLeft(4, '0');

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
  // Приём включён (14 01 отправлено), идёт сессия (10 03 … 10 07), опрос
  // setup раз в 60 с остался без ответа.
  final bool enabled;
  final bool inSession;
  final bool silent;
  // Режим «одна тестовая оплата 0,10 €».
  final bool testActive;
  final String? testState;
  final bool? testOutcomeOk;
  final String? testOutcome;
  // Команд в очереди (одна за раз, после ACK предыдущей).
  final int queueSize;
  // «сессия может висеть, нажмите done» — до прихода 10 07.
  final String? sessionWarning;

  const MdbBenchStatus({
    this.open = false,
    this.device,
    this.setupScale,
    this.setupDecimals,
    this.logFile,
    this.enabled = false,
    this.inSession = false,
    this.silent = false,
    this.testActive = false,
    this.testState,
    this.testOutcomeOk,
    this.testOutcome,
    this.queueSize = 0,
    this.sessionWarning,
  });

  MdbBenchStatus.fromMap(Map<dynamic, dynamic> m)
    : open = m['open'] as bool? ?? false,
      device = m['device'] as String?,
      setupScale = m['setupScale'] as int?,
      setupDecimals = m['setupDecimals'] as int?,
      logFile = m['logFile'] as String?,
      enabled = m['enabled'] as bool? ?? false,
      inSession = m['inSession'] as bool? ?? false,
      silent = m['silent'] as bool? ?? false,
      testActive = m['testActive'] as bool? ?? false,
      testState = m['testState'] as String?,
      testOutcomeOk = m['testOutcomeOk'] as bool?,
      testOutcome = m['testOutcome'] as String?,
      queueSize = m['queueSize'] as int? ?? 0,
      sessionWarning = m['sessionWarning'] as String?;

  bool get hasSetup => setupScale != null && setupDecimals != null;
}

// Запрос оплаты, посчитанный стендом: amount — сумма, обратно пересчитанная
// из единиц терминала (то, что реально уйдёт в адаптер).
class MdbVendPreview {
  final int units;
  final int scale;
  final int decimals;
  final String amount;
  final String hex;

  MdbVendPreview.fromMap(Map<dynamic, dynamic> m)
    : units = m['units'] as int,
      scale = m['scale'] as int,
      decimals = m['decimals'] as int,
      amount = m['amount'] as String,
      hex = m['hex'] as String;
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

  // Возвращает отправленные байты в hex. vend — только через vendPreview и
  // sendVend (сумма подтверждается в окне).
  static Future<String> command(String name, {int item = 1}) async =>
      await _channel.invokeMethod<String>('command', {
        'name': name,
        'item': item,
      }) ??
      '';

  // Расчёт запроса оплаты без отправки. Ошибка суммы (не кратна шагу, вне
  // диапазона, нет ответа на setup) — PlatformException с текстом.
  static Future<MdbVendPreview> vendPreview(String amount) async {
    final r = await _channel.invokeMethod<Map>('vendPreview', {
      'amount': amount,
    });
    if (r == null) {
      throw PlatformException(code: 'MDB', message: 'нет ответа стенда');
    }
    return MdbVendPreview.fromMap(r);
  }

  // Отправка ровно того, что показано в окне подтверждения.
  static Future<String> sendVend(MdbVendPreview p) async =>
      await _channel.invokeMethod<String>('command', {
        'name': 'vend',
        'units': p.units,
        'scale': p.scale,
        'decimals': p.decimals,
        'item': 1,
      }) ??
      '';

  // Одна тестовая оплата 0,10 € — автомат на стороне Kotlin (MdbTestPayment).
  static Future<void> testStart() => _channel.invokeMethod('testStart');

  static Future<void> testAbort() => _channel.invokeMethod('testAbort');

  static Future<String> raw(String hex) async =>
      await _channel.invokeMethod<String>('raw', {'hex': hex}) ?? '';

  static Future<List<({int seq, String line})>> getLog(int since) async {
    final r =
        await _channel.invokeMethod<List>('getLog', {'since': since}) ??
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
