import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_state.dart';
import 'app_log_service.dart';
import 'card_payment_store.dart';
import 'card_terminal_service.dart';
import 'cloud_service.dart';
import 'modbus_service.dart';
import 'session_service.dart';

// Оплата картой в основном потоке (1.11.0, ТЗ раздел 6) — Dart-сторона.
// Автомат оплаты в Kotlin (MdbCardPayment): 10 03 → vend → 10 05/10 06,
// 13 02/13 03/13 04. Здесь:
//   * arm / смена суммы / отмена — от экрана оплаты;
//   * 10 05 (approved) — СНАЧАЛА payment_pending на диск, потом экран
//     запускает цикл (раздел 6.7);
//   * итог цикла (SessionService.onFinished) → Kotlin: успех — 13 02/13 04,
//     сбой — 13 03 в окне возврата или ручной возврат (разделы 6.8–6.10);
//   * события в облако (раздел 10), без данных карты;
//   * pre-flight перед «Приложите карту» (раздел 5).
class CardPaymentEvent {
  final String type;
  final Map<String, dynamic> data;
  const CardPaymentEvent(this.type, this.data);
}

// Что сказать клиенту на экране ошибки после сбоя цикла, оплаченного картой.
enum CardCustomerNotice { refunded, contactOperator }

class _ArmContext {
  final int cents;
  final int flavorIndex;
  final String flavorName;
  int coinsCents;
  final String deviceId;
  String? sessionId;
  bool approved = false;
  _ArmContext(this.cents, this.flavorIndex, this.flavorName, this.coinsCents, this.deviceId);
}

class CardPaymentService {
  CardPaymentService._();

  static const _channel = MethodChannel('com.carfog.dryfog/card_terminal');

  static final StreamController<CardPaymentEvent> _events =
      StreamController<CardPaymentEvent>.broadcast();
  static Stream<CardPaymentEvent> get events => _events.stream;

  static final ValueNotifier<CardCustomerNotice?> customerNotice = ValueNotifier(null);

  static _ArmContext? _ctx;
  static bool get approvedPending => _ctx?.approved == true;

  static void install() {
    SessionService.onFinished = _onSessionFinished;
  }

  // ---- от экрана оплаты ----

  // Включить ожидание карты на сумму cents (цена запаха минус монеты).
  // Ошибка (терминал недоступен, сумма не переводится) — PlatformException.
  static Future<int> arm({
    required AppNotifier notifier,
    required int cents,
    required int flavorIndex,
    required int coinsCents,
  }) async {
    final cfg = notifier.config;
    final units = await _channel.invokeMethod<int>('arm', {
      'cents': cents,
      'flavorIndex': flavorIndex,
      'refundWindowS': cfg.cardRefundWindowS,
      'confirmEnabled': cfg.cardConfirmEnabled,
    });
    _ctx = _ArmContext(
      cents,
      flavorIndex,
      (cfg.flavorNames['ru'] ?? const <String>[]).elementAtOrNull(flavorIndex) ??
          cfg.flavorNameFor('ru', flavorIndex),
      coinsCents,
      cfg.deviceId,
    );
    customerNotice.value = null;
    return units ?? 0;
  }

  static Future<void> updateAmount(int cents, int coinsCents) async {
    final c = _ctx;
    if (c == null || c.approved) return;
    await _channel.invokeMethod('updateAmount', {'cents': cents});
    _ctx = _ArmContext(cents, c.flavorIndex, c.flavorName, coinsCents, c.deviceId);
  }

  static Future<void> cancel() async {
    await _channel.invokeMethod('cancel');
    if (_ctx?.approved != true) _ctx = null;
  }

  static Future<void> disarm(String reason) async {
    await _channel.invokeMethod('disarm', {'reason': reason});
    if (_ctx?.approved != true) _ctx = null;
  }

  // Сессия цикла создана (payment.dart) — для записи и итога.
  static void attachSession(String? sessionId) {
    final c = _ctx;
    if (c == null || sessionId == null) return;
    c.sessionId = sessionId;
    unawaited(() async {
      final p = await CardPaymentStore.pending();
      if (p != null && p.sessionId == null) {
        await CardPaymentStore.writePending(p.copyWith(sessionId: sessionId));
      }
    }());
  }

  // ---- итог цикла ----

  static void _onSessionFinished(String sessionId, bool completed, String? reason) {
    final c = _ctx;
    if (c == null || !c.approved) return;
    if (c.sessionId != null && c.sessionId != sessionId) return;
    AppLog.log('CardPayment', 'цикл ${completed ? 'завершён' : 'оборван ($reason)'} — итог оплаты картой');
    unawaited(
      _channel
          .invokeMethod('finish', {'success': completed, 'reason': reason ?? ''})
          .catchError((Object e) {
            AppLog.log('CardPayment', 'итог в терминал не передан: $e');
            return null;
          }),
    );
  }

  // ---- события автомата (из CardTerminalService.poll) ----

  static Future<void> handlePaymentEvent(Map<String, dynamic> e, {DateTime? now}) async {
    final type = e['type'] as String? ?? '';
    final data = (e['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    final c = _ctx;
    final base = <String, dynamic>{
      if (c != null) ...{
        'amount_cents': c.cents,
        'flavor': c.flavorName,
        'flavor_index': c.flavorIndex,
        'coins_cents': c.coinsCents,
        'device_id': c.deviceId,
        'session_id': ?c.sessionId,
      },
    };
    AppLog.log('CardPayment', '$type $data');
    switch (type) {
      case 'vend_sent':
        unawaited(CloudService.report('payment_card_started', data: base));
      case 'approved':
        if (c != null) {
          c.approved = true;
          final at = now ?? DateTime.now();
          final ok = await CardPaymentStore.writePending(CardPaymentRecord(
            id: 'card-${at.microsecondsSinceEpoch}',
            approvedAtMs: at.millisecondsSinceEpoch,
            amountCents: c.cents,
            units: (data['units'] as num?)?.toInt() ?? 0,
            flavorIndex: c.flavorIndex,
            flavorName: c.flavorName,
            coinsCents: c.coinsCents,
            sessionId: c.sessionId,
          ));
          if (!ok) AppLog.log('CardPayment', 'ВНИМАНИЕ: payment_pending не записан, цикл всё равно запускается');
        }
        unawaited(CloudService.report('payment_card_approved', data: base));
      case 'success':
        await CardPaymentStore.close('success', data, now: now);
        unawaited(CloudService.report('payment_card_success', data: {...base, ...data}));
        _ctx = null;
      case 'refunded':
        await CardPaymentStore.close('refunded', data, now: now);
        unawaited(CloudService.report('payment_refunded_auto', data: {...base, ...data}));
        customerNotice.value = CardCustomerNotice.refunded;
        _ctx = null;
      case 'manual_refund_needed':
        final closed = await CardPaymentStore.close('manual_refund_needed', data, now: now);
        unawaited(CloudService.report('payment_manual_refund_needed', data: {
          ...base,
          ...data,
          if (closed != null) 'approved_at': DateTime.fromMillisecondsSinceEpoch(closed.approvedAtMs).toUtc().toIso8601String(),
        }));
        customerNotice.value = CardCustomerNotice.contactOperator;
        _ctx = null;
      case 'declined':
      case 'insufficient_funds':
      case 'amount_mismatch':
      case 'vend_failed':
      case 'cancelled_by_terminal':
      case 'vend_timeout':
      case 'session_ended':
      case 'approved_after_cancel':
      case 'payment_aborted':
        unawaited(CloudService.report('payment_card_declined', data: {...base, 'reason': type, ...data}));
    }
    _events.add(CardPaymentEvent(type, data));
  }

  // ---- восстановление после перезапуска (раздел 8) ----

  // При старте приложения: незакрытая запись payment_pending — деньги
  // одобрены, итога нет (сбой приложения или питания во время цикла). Окно
  // возврата ещё не прошло и терминал mdb — попросить его вернуть деньги
  // (13 03, 13 04), как только связь будет готова; иначе — ручной возврат
  // (облако и Telegram). Запись закрывается по итогу.
  static Future<void> recoverOnStartup(AppNotifier n, {DateTime? now}) async {
    final p = await CardPaymentStore.pending();
    if (p == null) return;
    final cfg = n.config;
    final t = now ?? DateTime.now();
    final deadlineMs = p.approvedAtMs + cfg.cardRefundWindowS * 1000;
    _ctx = _ArmContext(p.amountCents, p.flavorIndex, p.flavorName, p.coinsCents, cfg.deviceId)
      ..sessionId = p.sessionId
      ..approved = true;
    AppLog.log('CardPayment', 'при старте найдена незакрытая оплата картой ${p.amountCents} центов (${p.id})');
    final canRefund = cfg.paymentTerminalType == PaymentTerminalType.mdb &&
        t.millisecondsSinceEpoch < deadlineMs;
    if (canRefund) {
      try {
        await _channel.invokeMethod('recover', {
          'units': p.units,
          'item': p.flavorIndex + 1,
          'deadlineMs': deadlineMs,
        });
        return;
      } catch (e) {
        AppLog.log('CardPayment', 'возврат при старте не запрошен: $e');
      }
    }
    await handlePaymentEvent({
      'type': 'manual_refund_needed',
      'data': {
        'recovered': true,
        'refund': cfg.paymentTerminalType != PaymentTerminalType.mdb
            ? 'терминал mdb выключен'
            : t.millisecondsSinceEpoch >= deadlineMs
            ? 'окно возврата прошло до перезапуска'
            : 'терминал недоступен',
        'elapsed_s': (t.millisecondsSinceEpoch - p.approvedAtMs) ~/ 1000,
      },
    }, now: t);
  }

  // ---- pre-flight (раздел 5) ----

  // Может ли аппарат выдать услугу: только существующие проверки и узлы,
  // отмеченные установленными (датчика давления в аппарате нет — решение
  // владельца 21.10.2026). null — всё в порядке, иначе код причины.
  static Future<String?> preflight(AppNotifier n, int flavorIndex) async {
    final cfg = n.config;
    if (n.isPaymentBlocked) return 'payment_blocked';
    if (!n.busHealthy) return 'bus';
    final levels = n.levels;
    if (flavorIndex >= levels.length || !levels[flavorIndex]) return 'level';
    if (cfg.dioInstalled && await ModbusService.readAllInputs() == null) return 'io_module';
    if (cfg.thermoInstalled && await ModbusService.readTemperature() == null) return 'thermocouple';
    if (cfg.energyMeterInstalled && await ModbusService.readEnergy() == null) return 'energy_meter';
    return null;
  }

  @visibleForTesting
  static void resetForTest() {
    _ctx = null;
    customerNotice.value = null;
  }

  // Статус терминала для экрана оплаты.
  static CardTerminalStatus get terminal => CardTerminalService.status.value;
}
