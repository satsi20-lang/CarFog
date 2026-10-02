import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/bus_map.dart';
import 'cloud_service.dart';
import 'cycle_energy_service.dart';
import 'modbus_service.dart';

// Ключи контрольной точки "счётчик энергии только что отвечал и показывал
// вот это" — задача "контроль цикла по электросчётчику", фаза 2, часть 3:
// отличить пропадание питания от краша софта при следующем старте
// (main.dart). Пишутся здесь же, попутно уже читаемым в _finish() концом
// сессии — отдельного постоянного фонового опроса не заводим.
const String energyCheckpointKwhKey = 'energy_checkpoint_kwh';
const String energyCheckpointAtKey = 'energy_checkpoint_at';

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
    // 'coins' | 'card' | 'mixed' (Шаг "терминал", задача 6) — 'mixed',
    // когда картой оплатили поверх уже внесённых монет: терминал настроен
    // на полную цену независимо от того, что уже в аппарате, так что
    // клиент в этом случае фактически переплатил.
    String paymentMethod = 'coins',
    int? coinsCents,
    // Счётчик неудачных чтений DI8 монетоприёмника за окно этой оплаты
    // (задача "контроль цикла по электросчётчику, готовность оплаты", п.2)
    // — спор с клиентом решается по записи: видно, была ли связь в момент
    // оплаты в норме. null/0 не различаются намеренно — оба означают
    // "нечего сообщить".
    int? coinFailureCount,
    // false — счётчик энергии не установлен: не тратить шину на заведомо
    // неудачное чтение.
    bool readStartEnergy = true,
  }) async {
    // Платный сеанс не может начаться, пока аппарат выведен из
    // обслуживания (задача "вывод аппарата из обслуживания", требование 8).
    if (ModbusService.paymentBlocked) {
      debugPrint('SessionService.start: заблокировано (выведен из обслуживания)');
      return;
    }
    // Сессия создаётся СРАЗУ, до чтения счётчика: отказ или отмена, случившиеся
    // раньше, чем дочитался бы счётчик, иначе не оставили бы записи.
    final session = _Session(
      flavorIndex: flavorIndex,
      flavorNameRu: flavorNameRu,
      priceCents: priceCents,
      paidCents: paidCents,
      paymentMethod: paymentMethod,
      coinsCents: coinsCents,
      coinFailureCount: coinFailureCount,
      startedAt: DateTime.now(),
    );
    _current = session;
    if (readStartEnergy) {
      final energy = await ModbusService.readEnergy();
      session.startEnergyKwh = energy?['totalEnergy'];
    }
  }

  // Успешное завершение (продувка окончена, переход на финальный экран).
  static Future<void> complete() => _finish(completed: true, reason: null);

  // Прерывание с причиной: 'overheat' | 'timeout' | 'sensor' | 'cancelled' |
  // 'heater_failure'. serviceNotDelivered — деньги приняты, а услуга не
  // оказана ни на секунду (задача "контроль цикла по электросчётчику",
  // фаза 2, часть 1) — отдельное поле в записи, а не строкой в reason:
  // спор с клиентом и возврат денег должны решаться простым фильтром по
  // булеву полю, а не разбором текста причины.
  // extra — дополнительные поля записи для решения оператора о возврате
  // (например, доля оказанной услуги при отказе в обработке).
  static Future<void> interrupt(
    String reason, {
    bool serviceNotDelivered = false,
    Map<String, dynamic>? extra,
  }) =>
      _finish(
        completed: false,
        reason: reason,
        serviceNotDelivered: serviceNotDelivered,
        extra: extra,
      );

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
    bool serviceNotDelivered = false,
    Map<String, dynamic>? extra,
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
      'payment_method': session.paymentMethod,
    };
    if (reason != null) data['reason'] = reason;
    if (session.coinsCents != null) data['coins_cents'] = session.coinsCents;
    if (session.coinFailureCount != null) {
      data['coin_failure_count'] = session.coinFailureCount;
    }
    if (serviceNotDelivered) data['service_delivered'] = false;
    if (extra != null) data.addAll(extra);

    // Пять из шести чисел цикла (задача "контроль цикла по
    // электросчётчику", фаза 2, часть 2) — шестое, energy_wh, считается
    // здесь же чуть ниже отдельной парой чтений 0x4000. null, если цикл
    // вообще не успел начаться (не должно происходить: _current
    // создаётся в start(), который вызывается из payment.dart ровно тогда,
    // когда сессия точно начинается) — на всякий случай не подставляем
    // фиктивные нули.
    final cycleSummary = CycleEnergyService.endCycle();
    if (cycleSummary != null) data.addAll(cycleSummary);
    final gridVoltage = cycleSummary?['grid_voltage_v'] as double?;
    if (gridVoltage != null && gridVoltage < PowerSignature.gridVoltageSagWarningV) {
      // Не авария — просто пометка в той же записи, отдельного события не
      // требуется (задача, часть 3: "предупреждение в журнал, не авария").
      data['voltage_low'] = true;
    }

    // Расход за сессию — только если ОБА показания (старт и сейчас)
    // реально прочитались. Если хоть одно не удалось — поле не
    // включается вовсе, а не подставляется нулём (Шаг 33, задача 1.5).
    final startKwh = session.startEnergyKwh;
    double? endKwh;
    final endEnergy = await ModbusService.readEnergy();
    endKwh = endEnergy?['totalEnergy'];
    if (startKwh != null && endKwh != null) {
      data['energy_wh'] = (endKwh - startKwh) * 1000.0;
    }

    // Контрольная точка для различения краша софта и пропадания питания
    // при следующем старте (main.dart) — пишем при каждом завершении
    // сессии, раз уже читаем счётчик здесь же. Если endKwh не прочитался
    // (шина мертва прямо сейчас), контрольную точку не трогаем — старое
    // значение всё ещё лучше, чем пустое.
    if (endKwh != null) {
      unawaited(_saveEnergyCheckpoint(endKwh));
    }

    await CloudService.report(CloudEventType.sessionComplete, data: data);
  }

  static Future<void> _saveEnergyCheckpoint(double kwh) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(energyCheckpointKwhKey, kwh);
      await prefs.setString(
        energyCheckpointAtKey,
        DateTime.now().toIso8601String(),
      );
    } catch (e) {
      debugPrint('SessionService._saveEnergyCheckpoint error: $e');
    }
  }
}

class _Session {
  final int flavorIndex;
  final String flavorNameRu;
  final int priceCents;
  final int paidCents;
  final String paymentMethod;
  final int? coinsCents;
  final int? coinFailureCount;
  final DateTime startedAt;
  double? startEnergyKwh;
  bool ended = false;

  _Session({
    required this.flavorIndex,
    required this.flavorNameRu,
    required this.priceCents,
    required this.paidCents,
    required this.paymentMethod,
    required this.coinsCents,
    required this.coinFailureCount,
    required this.startedAt,
  });
}
