import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class ModbusService {
  static const _channel = MethodChannel('com.carfog.dryfog/modbus');
  static bool _open = false;

  // Открыть порт. Вызывать один раз при старте.
  // port: '/dev/ttyS5' — уточнить после запуска find_port.py
  static Future<bool> open({
    String port = '/dev/ttyS5',
    int baud = 9600,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('open', {
        'port': port,
        'baud': baud,
      });
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

  // Читает ВСЕ 16 дискретных входов одной транзакцией (каналы 0-7 —
  // уровни канистр, 8 — монетоприёмник, остальные, включая платёжный
  // терминал — по месту распайки). Один запрос на 16 входов стоит по
  // времени столько же, сколько на 8 — служебная часть кадра одинакова.
  // null = ошибка чтения.
  static Future<List<bool>?> readAllInputs() async {
    try {
      final result = await _channel.invokeMethod<List>('readAllInputs');
      return result?.map((e) => e as bool).toList();
    } catch (e) {
      debugPrint('ModbusService.readAllInputs error: $e');
      return null;
    }
  }

  // Уровни канистр (каналы 0-7) — тонкая обёртка над readAllInputs() для
  // мест, которым не нужны остальные каналы. true = есть жидкость.
  // null = ошибка чтения (не путать с настоящим "все канистры пусты").
  static Future<List<bool>?> readLevels() async {
    final all = await readAllInputs();
    if (all == null || all.length < 8) return null;
    return all.sublist(0, 8);
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

  // Читает температуру термопары, канал 0-3. Возвращает °C,
  // либо null при ошибке чтения (не путать с настоящим 0°C).
  static Future<double?> readTemperature({int channel = 0}) async {
    try {
      return await _channel.invokeMethod<double>('readTemperature', {
        'channel': channel,
      });
    } catch (e) {
      debugPrint('ModbusService.readTemperature error: $e');
      return null;
    }
  }

  // Читает данные счётчика энергии DDS6619: voltage (В), current (А),
  // power (Вт), totalEnergy (кВт⋅ч, общий накопленный расход).
  // null = ошибка чтения (не путать с настоящим нулевым потреблением) —
  // раньше здесь была нулевая заглушка на ошибку, из-за которой расход за
  // сессию (Шаг 33, задача 1) в принципе нельзя было отличить от честного
  // "не потребили ничего": разница показаний старт/финиш с подменённым
  // нулём вместо null считалась бы неверно, а не пропускалась.
  static Future<Map<String, double>?> readEnergy() async {
    try {
      final result = await _channel.invokeMethod<Map>('readEnergy');
      if (result == null) return null;
      return result.map((k, v) => MapEntry(k as String, (v as num).toDouble()));
    } catch (e) {
      debugPrint('ModbusService.readEnergy error: $e');
      return null;
    }
  }

  // Расход за текущий календарный месяц (кВт⋅ч).
  static Future<double> getMonthlyEnergy() async {
    try {
      return await _channel.invokeMethod<double>('getMonthlyEnergy') ?? 0.0;
    } catch (e) {
      debugPrint('ModbusService.getMonthlyEnergy error: $e');
      return 0.0;
    }
  }

  // Расход за прошлый (уже завершившийся) календарный месяц (кВт⋅ч).
  static Future<double> getPreviousMonthEnergy() async {
    try {
      return await _channel.invokeMethod<double>('getPreviousMonthEnergy') ??
          0.0;
    } catch (e) {
      debugPrint('ModbusService.getPreviousMonthEnergy error: $e');
      return 0.0;
    }
  }

  // История расхода по месяцам: JSON-строка вида
  // [{"year":2026,"month":7,"kwh":12.34}, ...], не более 12 записей.
  static Future<String> getEnergyHistory() async {
    try {
      return await _channel.invokeMethod<String>('getEnergyHistory') ?? '[]';
    } catch (e) {
      debugPrint('ModbusService.getEnergyHistory error: $e');
      return '[]';
    }
  }

  // Запускает фоновый счётчик импульсов монетоприёмника (экран оплаты).
  static Future<void> startPaymentCoinCounting() async {
    try {
      await _channel.invokeMethod('startPaymentCoinCounting');
    } catch (e) {
      debugPrint('ModbusService.startPaymentCoinCounting error: $e');
    }
  }

  // Останавливает фоновый счётчик — обязательно вызывать при уходе с экрана оплаты.
  static Future<void> stopPaymentCoinCounting() async {
    try {
      await _channel.invokeMethod('stopPaymentCoinCounting');
    } catch (e) {
      debugPrint('ModbusService.stopPaymentCoinCounting error: $e');
    }
  }

  // Номинал последней принятой монеты в центах (0 = новой монеты нет).
  static Future<int> getLastCoinCents() async {
    try {
      return await _channel.invokeMethod<int>('getLastCoinCents') ?? 0;
    } catch (e) {
      debugPrint('ModbusService.getLastCoinCents error: $e');
      return 0;
    }
  }

  // Один опрос платёжного терминала: читает канал, определяет фронт и
  // защитную паузу на стороне Kotlin (состояние между тиками хранится
  // там), пишет в журнал. Опрашивать часто — обязанность вызывающего
  // (Timer.periodic на стороне Dart), сам метод не заводит поток.
  static Future<TerminalPoll?> pollTerminal({
    required int channel,
    required String mode,
    required int guardMs,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('pollTerminal', {
        'channel': channel,
        'mode': mode,
        'guardMs': guardMs,
      });
      if (result == null) return null;
      return TerminalPoll(
        state: result['state'] as bool,
        confirmed: result['confirmed'] as bool,
        all: (result['all'] as List?)?.map((e) => e as bool).toList(),
      );
    } catch (e) {
      debugPrint('ModbusService.pollTerminal error: $e');
      return null;
    }
  }

  // Журнал сигнала терминала — кольцевой буфер строк для калибровки
  // (вкладка "Датчики" сервисного меню).
  static Future<List<String>> getTerminalJournal() async {
    try {
      final raw = await _channel.invokeMethod<List>('getTerminalJournal');
      return raw?.map((e) => e as String).toList() ?? [];
    } catch (e) {
      debugPrint('ModbusService.getTerminalJournal error: $e');
      return [];
    }
  }

  static Future<void> clearTerminalJournal() async {
    try {
      await _channel.invokeMethod('clearTerminalJournal');
    } catch (e) {
      debugPrint('ModbusService.clearTerminalJournal error: $e');
    }
  }
}

// Результат одного pollTerminal(): текущее сырое состояние входа и признак
// "именно этим тиком засчитана оплата" (уже с учётом режима и защитной
// паузы — см. ModbusChannel.pollTerminalEdge на нативной стороне).
class TerminalPoll {
  final bool state;
  final bool confirmed;
  // Тот же снимок всех 16 входов, что использован для state/confirmed —
  // для диагностики "на другом ли канале сигнал" на вкладке "Датчики",
  // без отдельной транзакции по шине (см. ModbusChannel.pollTerminal).
  final List<bool>? all;

  const TerminalPoll({required this.state, required this.confirmed, this.all});
}
