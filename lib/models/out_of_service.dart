// Состояние "аппарат выведен из обслуживания" (задача "вывод аппарата из
// обслуживания"). Хранится долговременно (OutOfServiceService → нативный
// OutOfServiceStore) и переживает перезапуск приложения и пропадание
// питания; снимается только вручную на месте после пробного цикла.

// Коды причин. Критерий вывода один: безопасная услуга физически
// невозможна. Работает с ограничениями (например, отказ монетоприёмника —
// клиент доплачивает картой) — не выводим. Новые причины подключаются
// сюда, а не заводят каждая свою логику.
class OutOfServiceCode {
  OutOfServiceCode._();

  // ТЭН не дал мощности после команды (фаза 2, часть 1: проверка нагрева).
  static const heaterNoPower = 'heater_no_power';
  // Отказ датчика температуры или "убегающий" нагрев (детекторы
  // HeaterSafetyMonitor); подтип — в details['subtype'].
  static const tempSensorFault = 'temp_sensor_fault';
  // Прогрев не достиг цели за HeaterThresholds.preheatTimeout (180 с):
  // ТЭН греет, но цели нет — безопасная услуга невозможна, а раньше это
  // вело в обычную ошибку и возврат к ожиданию, то есть аппарат снова
  // брал деньги (решение оператора 01.10.2026).
  static const heatTimeout = 'heat_timeout';
  // Команду выключения ТЭНа не удалось подтвердить чтением катушки после
  // всех повторов: реле может быть залипшим, безопасно греть нельзя.
  static const heaterOffUnconfirmed = 'heater_off_unconfirmed';
  // Температура достигла аварийного потолка (HeaterThresholds.overheatAbortC)
  // при исправном датчике. В обработке гистерезис выключает ТЭН при 190°C,
  // поэтому 240°C означает, что ТЭН не выключился (залипшее реле) или
  // термостат не работает — безопасная услуга невозможна, возврат к
  // ожиданию с приёмом денег недопустим.
  static const overheat = 'overheat';
  // Сторож выходов нашёл включённый выход, который не гасится даже после
  // safeAllOff и перепроверки (подробности: канал).
  static const outputStuckOn = 'output_stuck_on';
  // Хранилище не читается / запись повреждена при старте — fail-closed.
  static const stateUnreadable = 'state_unreadable';
  // Шина не отвечает дольше BusWatchdogService.downAfter (задача
  // "устойчивость шины"). ВРЕМЕННАЯ причина: на диск не пишется и
  // снимается сама, как только шина снова отвечает (см.
  // OutOfServiceService.enterTransient/leaveTransient).
  static const busDown = 'bus_down';

  // Причины, которые не переживают перезапуск и снимаются автоматически.
  static const transientCodes = {busDown};
  static bool isTransient(String code) => transientCodes.contains(code);
}

class OutOfServiceState {
  final String code;
  // Когда аппарат был выведен впервые. При повторном отказе (в том числе
  // на пробном цикле) не затирается — оператору важно, с какого момента.
  final DateTime since;
  // Мощность, напряжение, температура и т.п. на момент проверки.
  final Map<String, dynamic> details;

  const OutOfServiceState({
    required this.code,
    required this.since,
    this.details = const {},
  });

  static const _version = 1;

  Map<String, dynamic> toJson() => {
    'v': _version,
    'code': code,
    'since': since.toIso8601String(),
    'details': details,
  };

  // null — запись не разобралась (нет кода/времени, неверные типы): вызывающий
  // код считает это повреждённой записью (fail-closed), а не чистым стартом.
  static OutOfServiceState? tryParse(Object? decoded) {
    if (decoded is! Map) return null;
    final code = decoded['code'];
    final since = decoded['since'];
    if (code is! String || code.isEmpty || since is! String) return null;
    final at = DateTime.tryParse(since);
    if (at == null) return null;
    final details = decoded['details'];
    return OutOfServiceState(
      code: code,
      since: at,
      details: details is Map
          ? details.map((k, v) => MapEntry(k.toString(), v))
          : const {},
    );
  }

  OutOfServiceState copyWith({
    String? code,
    Map<String, dynamic>? details,
  }) => OutOfServiceState(
    code: code ?? this.code,
    since: since,
    details: details ?? this.details,
  );
}
