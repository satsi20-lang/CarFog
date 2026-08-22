import 'cloud_service.dart';
import 'modbus_service.dart';

// Контекст текущей платной сессии обработки (Шаг 33, задачи 1/2) — от
// момента, когда на payment.dart набралась нужная сумма, до завершения
// или прерывания на preparing.dart/treating.dart. Раньше внесённая сумма
// жила локальной переменной в PaymentScreen и терялась при переходе
// дальше — посчитать выручку по событиям было нечем.
class SessionService {
  static _Session? _current;

  // Вызывается с payment.dart в момент, когда внесённой суммы достаточно,
  // до перехода к подготовке. Отдельно снимает базовое показание общего
  // счётчика энергии — из него в конце вычитается финальное для расхода
  // за сессию.
  static Future<void> start({
    required int flavorIndex,
    required String flavorNameRu,
    required int priceCents,
    required int paidCents,
  }) async {
    final energy = await ModbusService.readEnergy();
    _current = _Session(
      flavorIndex: flavorIndex,
      flavorNameRu: flavorNameRu,
      priceCents: priceCents,
      paidCents: paidCents,
      startedAt: DateTime.now(),
      startEnergyKwh: energy?['totalEnergy'],
    );
  }

  // Успешное завершение (продувка окончена, переход на финальный экран).
  static Future<void> complete() => _finish(completed: true, reason: null);

  // Прерывание с причиной: 'overheat' | 'timeout' | 'sensor' | 'cancelled'.
  static Future<void> interrupt(String reason) =>
      _finish(completed: false, reason: reason);

  // Отмена/таймаут ДО того, как сессия успела начаться (payment.dart) —
  // просто забывает контекст: событие session_complete в принципе не
  // должно уходить, деньги ещё не были внесены до конца.
  static void discard() {
    _current = null;
  }

  // Идемпотентно — второй вызов complete()/interrupt() для уже
  // завершённой/прерванной сессии ничего не отправляет.
  static Future<void> _finish({
    required bool completed,
    required String? reason,
  }) async {
    final session = _current;
    if (session == null || session.ended) return;
    session.ended = true;
    _current = null;

    final durationS = DateTime.now().difference(session.startedAt).inSeconds;
    final data = <String, dynamic>{
      'flavor_index': session.flavorIndex,
      'flavor': session.flavorNameRu,
      'price_cents': session.priceCents,
      'paid_cents': session.paidCents,
      'duration_s': durationS,
      'completed': completed,
    };
    if (reason != null) data['reason'] = reason;

    // Расход за сессию — только если ОБА показания (старт и сейчас)
    // реально прочитались. Если хоть одно не удалось — поле не
    // включается вовсе, а не подставляется нулём (Шаг 33, задача 1.5).
    final startKwh = session.startEnergyKwh;
    if (startKwh != null) {
      final endEnergy = await ModbusService.readEnergy();
      final endKwh = endEnergy?['totalEnergy'];
      if (endKwh != null) {
        data['energy_wh'] = (endKwh - startKwh) * 1000.0;
      }
    }

    await CloudService.report(CloudEventType.sessionComplete, data: data);
  }
}

class _Session {
  final int flavorIndex;
  final String flavorNameRu;
  final int priceCents;
  final int paidCents;
  final DateTime startedAt;
  final double? startEnergyKwh;
  bool ended = false;

  _Session({
    required this.flavorIndex,
    required this.flavorNameRu,
    required this.priceCents,
    required this.paidCents,
    required this.startedAt,
    required this.startEnergyKwh,
  });
}
