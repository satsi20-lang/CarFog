import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class ModbusService {
  static const _channel = MethodChannel('com.carfog.dryfog/modbus');
  static bool _open = false;

  // Открыть порт. Вызывать один раз при старте.
  // port: '/dev/ttyS5' — уточнить после запуска find_port.py
  static Future<bool> open({String port = '/dev/ttyS5', int baud = 9600}) async {
    try {
      final ok = await _channel.invokeMethod<bool>('open', {'port': port, 'baud': baud});
      _open = ok == true;
      return _open;
    } catch (e) {
      debugPrint('ModbusService.open error: $e');
      return false;
    }
  }

  static Future<void> close() async {
    try {
      await _channel.invokeMethod('close');
      _open = false;
    } catch (e) {
      debugPrint('ModbusService.close error: $e');
    }
  }

  static bool get isOpen => _open;

  // Читает 8 датчиков уровня канистр. true = есть жидкость.
  static Future<List<bool>> readLevels() async {
    try {
      final result = await _channel.invokeMethod<List>('readLevels');
      return result?.map((e) => e as bool).toList() ?? List.filled(8, false);
    } catch (e) {
      debugPrint('ModbusService.readLevels error: $e');
      return List.filled(8, false);
    }
  }

  // Читает сигнал монетоприёмника.
  static Future<bool> readCoin() async {
    try {
      return await _channel.invokeMethod<bool>('readCoin') ?? false;
    } catch (e) {
      debugPrint('ModbusService.readCoin error: $e');
      return false;
    }
  }

  // Управляет одним DO. channel 0-based:
  //   0-7  → насосы 1-8
  //   8    → компрессор
  //   9    → ТЭН испарителя
  //   10   → LED зелёная
  //   11   → LED красная
  static Future<bool> setDO(int channel, bool value) async {
    try {
      return await _channel.invokeMethod<bool>('setDO', {
            'channel': channel,
            'value': value,
          }) ??
          false;
    } catch (e) {
      debugPrint('ModbusService.setDO error: $e');
      return false;
    }
  }

  // Удобные обёртки для конкретных устройств
  static Future<bool> setPump(int flavorIndex, bool on) =>
      setDO(flavorIndex, on); // 0-7

  static Future<bool> setCompressor(bool on) => setDO(8, on);

  static Future<bool> setHeater(bool on) => setDO(9, on);

  static Future<bool> setLedGreen(bool on) => setDO(10, on);

  static Future<bool> setLedRed(bool on) => setDO(11, on);

  // Выключить ВСЕ выходы — вызывать при старте и при любой ошибке.
  static Future<bool> safeAllOff() async {
    try {
      return await _channel.invokeMethod<bool>('safeAllOff') ?? false;
    } catch (e) {
      debugPrint('ModbusService.safeAllOff error: $e');
      return false;
    }
  }

  // Читает температуру термопары, канал 0-3. Возвращает °C.
  static Future<double> readTemperature({int channel = 0}) async {
    try {
      return await _channel.invokeMethod<double>('readTemperature', {
            'channel': channel,
          }) ??
          0.0;
    } catch (e) {
      debugPrint('ModbusService.readTemperature error: $e');
      return 0.0;
    }
  }
}
