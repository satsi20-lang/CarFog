import 'modbus_service.dart';

// Проба модуля на шине (1.11.3 — pre-flight оплаты картой, 1.11.4 — фоновый
// контроль термопары в простое): до attempts СВЕЖИХ чтений подряд с паузой
// между ними. Первое годное — модуль в порядке, дальше не читаем; «не
// прошла» — только если все чтения негодные. Кэш для решения не
// используется.
class ProbeResult {
  final bool ok;
  // По каждой негодной попытке: value (если keepValue), error
  // (read_failed / out_of_range / no_plugin), ms.
  final List<Map<String, dynamic>> readings;
  const ProbeResult(this.ok, this.readings);

  // Поля события: attempts, readings, last_usable_age_s (возраст последнего
  // годного чтения из любого места приложения; null — с запуска не было).
  Map<String, dynamic> details({DateTime? lastOkAt}) => {
    'attempts': readings.length,
    'readings': readings,
    'last_usable_age_s': lastOkAt == null
        ? null
        : ModbusService.clock().difference(lastOkAt).inSeconds,
  };
}

// keepValue — значение негодного чтения в readings (термопара: −500, 450);
// у модулей без одного числа — только вид ошибки.
Future<ProbeResult> probeModule<T>(
  Future<ModbusRead<T>> Function() read,
  bool Function(T) usable, {
  required int attempts,
  required Duration retryPause,
  required Future<void> Function(Duration) pause,
  bool keepValue = false,
}) async {
  final readings = <Map<String, dynamic>>[];
  for (var i = 0; i < attempts; i++) {
    if (i > 0) await pause(retryPause);
    final t0 = ModbusService.clock();
    final r = await read();
    final ms = ModbusService.clock().difference(t0).inMilliseconds;
    final v = r.value;
    if (v != null && usable(v)) return ProbeResult(true, readings);
    readings.add({
      'value': keepValue ? v : null,
      'error': r.error ?? 'out_of_range',
      'ms': ms,
    });
  }
  return ProbeResult(false, readings);
}
