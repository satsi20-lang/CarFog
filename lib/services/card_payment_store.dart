import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_log_service.dart';

// Запись об оплате картой на диске (1.11.0, ТЗ разделы 6.7 и 8): живёт с
// момента 10 05 (платёж одобрен) до итога цикла — успех, автоматический
// возврат или «нужен ручной возврат». Пишется ДО запуска цикла, чтобы после
// сбоя приложения или питания было видно, что деньги одобрены, а итога нет
// (восстановление — этап 4). Закрытые записи — последние 50 для диагностики.
// Данных карты по MDB нет и здесь их нет.
class CardPaymentRecord {
  final String id;
  // Время 10 05 (мс с эпохи, часы планшета).
  final int approvedAtMs;
  final int amountCents;
  final int units;
  final int flavorIndex;
  final String flavorName;
  final int coinsCents;
  final String? sessionId;
  // pending | success | refunded | manual_refund_needed |
  // client_cancelled_no_refund
  final String status;
  final int? closedAtMs;
  final Map<String, dynamic> outcome;
  // Клиент нажал «Отмена» (1.11.1): {stage, refund, elapsed_s, at_ms} —
  // решение о возврате, принятое в момент нажатия. Пишется ДО команды
  // терминалу: перезапуск во время отмены не превращает её в сбой.
  final Map<String, dynamic>? clientCancel;

  const CardPaymentRecord({
    required this.id,
    required this.approvedAtMs,
    required this.amountCents,
    required this.units,
    required this.flavorIndex,
    required this.flavorName,
    required this.coinsCents,
    this.sessionId,
    this.status = 'pending',
    this.closedAtMs,
    this.outcome = const {},
    this.clientCancel,
  });

  CardPaymentRecord copyWith({
    String? sessionId,
    String? status,
    int? closedAtMs,
    Map<String, dynamic>? outcome,
    Map<String, dynamic>? clientCancel,
  }) => CardPaymentRecord(
    id: id,
    approvedAtMs: approvedAtMs,
    amountCents: amountCents,
    units: units,
    flavorIndex: flavorIndex,
    flavorName: flavorName,
    coinsCents: coinsCents,
    sessionId: sessionId ?? this.sessionId,
    status: status ?? this.status,
    closedAtMs: closedAtMs ?? this.closedAtMs,
    outcome: outcome ?? this.outcome,
    clientCancel: clientCancel ?? this.clientCancel,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'approved_at_ms': approvedAtMs,
    'amount_cents': amountCents,
    'units': units,
    'flavor_index': flavorIndex,
    'flavor': flavorName,
    'coins_cents': coinsCents,
    'session_id': ?sessionId,
    'status': status,
    'closed_at_ms': ?closedAtMs,
    if (outcome.isNotEmpty) 'outcome': outcome,
    'client_cancel': ?clientCancel,
  };

  static CardPaymentRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      return CardPaymentRecord(
        id: raw['id'] as String,
        approvedAtMs: (raw['approved_at_ms'] as num).toInt(),
        amountCents: (raw['amount_cents'] as num).toInt(),
        units: (raw['units'] as num).toInt(),
        flavorIndex: (raw['flavor_index'] as num).toInt(),
        flavorName: raw['flavor'] as String? ?? '',
        coinsCents: (raw['coins_cents'] as num?)?.toInt() ?? 0,
        sessionId: raw['session_id'] as String?,
        status: raw['status'] as String? ?? 'pending',
        closedAtMs: (raw['closed_at_ms'] as num?)?.toInt(),
        outcome: (raw['outcome'] as Map?)?.cast<String, dynamic>() ?? const {},
        clientCancel: (raw['client_cancel'] as Map?)?.cast<String, dynamic>(),
      );
    } catch (_) {
      return null;
    }
  }
}

class CardPaymentStore {
  CardPaymentStore._();

  static const String pendingKey = 'card_payment_pending';
  static const String historyKey = 'card_payment_history';
  static const int historyMax = 50;

  static Future<CardPaymentRecord?> pending() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(pendingKey);
    if (raw == null) return null;
    try {
      return CardPaymentRecord.fromJson(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  // Ждать завершения записи до запуска цикла (раздел 6.7).
  static Future<bool> writePending(CardPaymentRecord r) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await prefs.setString(pendingKey, jsonEncode(r.toJson()));
    } catch (e) {
      AppLog.log('CardPayment', 'payment_pending не записан: $e');
      return false;
    }
  }

  // Итог: запись уходит в историю (последние 50), pending удаляется.
  static Future<CardPaymentRecord?> close(
    String status,
    Map<String, dynamic> outcome, {
    DateTime? now,
  }) async {
    final p = await pending();
    if (p == null) return null;
    final closed = p.copyWith(
      status: status,
      closedAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
      outcome: outcome,
    );
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(historyKey) ?? [];
    list.add(jsonEncode(closed.toJson()));
    while (list.length > historyMax) {
      list.removeAt(0);
    }
    await prefs.setStringList(historyKey, list);
    await prefs.remove(pendingKey);
    return closed;
  }

  static Future<List<CardPaymentRecord>> history() async {
    final prefs = await SharedPreferences.getInstance();
    return [
      for (final s in prefs.getStringList(historyKey) ?? const <String>[])
        ?CardPaymentRecord.fromJson(jsonDecode(s)),
    ];
  }
}
