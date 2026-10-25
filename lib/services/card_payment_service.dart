import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_state.dart';
import 'app_log_service.dart';
import 'card_payment_store.dart';
import 'card_terminal_service.dart';
import 'cloud_service.dart';
import 'heater_safety_monitor.dart';
import 'modbus_service.dart';
import 'module_probe.dart';
import 'session_service.dart';

// Оплата картой в основном потоке (1.11.0, ТЗ раздел 6) — Dart-сторона.
// Автомат оплаты в Kotlin (MdbCardPayment): 10 03 → vend → 10 05/10 06,
// 13 02/13 03/13 04. Здесь:
//   * arm / смена суммы / отмена — от экрана оплаты;
//   * 10 05 (approved) — СНАЧАЛА payment_pending на диск, потом экран
//     запускает цикл (раздел 6.7);
//   * итог цикла (SessionService.onFinished) → Kotlin: успех — 13 02/13 04,
//     сбой — 13 03 в окне возврата или ручной возврат (разделы 6.8–6.10);
//   * отмена клиентом (1.11.1, раздел 15) — отдельно от сбоя, по причине
//     завершения цикла: возврат только в прогреве и в окне, иначе услуга
//     оказана (13 02) без ручного возврата;
//   * события в облако (раздел 10), без данных карты;
//   * pre-flight перед «Приложите карту» (раздел 5).
class CardPaymentEvent {
  final String type;
  final Map<String, dynamic> data;
  const CardPaymentEvent(this.type, this.data);
}

// Что сказать клиенту на экране ошибки после сбоя цикла, оплаченного картой.
enum CardCustomerNotice { refunded, contactOperator }

// Решение о возврате при отмене клиентом — принимается в момент нажатия
// «Отмена» и дальше не пересчитывается: остановка (подтверждение выключения
// ТЭНа) занимает секунды, и клиент, которому не показали предупреждение,
// не должен остаться без возврата из-за них.
class CardCancelQuote {
  final String stage;
  final bool refund;
  final int atMs;
  final int elapsedS;
  const CardCancelQuote({
    required this.stage,
    required this.refund,
    required this.atMs,
    required this.elapsedS,
  });

  Map<String, dynamic> toJson() => {
    'stage': stage,
    'refund': refund,
    'elapsed_s': elapsedS,
    'at_ms': atMs,
  };

  static CardCancelQuote? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return CardCancelQuote(
      stage: j['stage'] as String? ?? '',
      refund: j['refund'] == true,
      atMs: (j['at_ms'] as num?)?.toInt() ?? 0,
      elapsedS: (j['elapsed_s'] as num?)?.toInt() ?? 0,
    );
  }
}

// Причина завершения цикла «клиент нажал Отмена» (preparing.dart,
// treating.dart). Любая другая причина completed=false — сбой аппарата.
const String clientCancelReason = 'cancelled_by_client';

class _ArmContext {
  final int cents;
  final int flavorIndex;
  final String flavorName;
  int coinsCents;
  final String deviceId;
  final int refundWindowS;
  String? sessionId;
  bool approved = false;
  // Время 10 05 по часам автомата (System.currentTimeMillis в Kotlin).
  int? approvedAtMs;
  CardCancelQuote? clientCancel;
  _ArmContext(
    this.cents,
    this.flavorIndex,
    this.flavorName,
    this.coinsCents,
    this.deviceId,
    this.refundWindowS,
  );
}

// Итог pre-flight (раздел 5): reason null — всё в порядке; details — поля
// для события hardware_error card_preflight (1.11.3).
class PreflightResult {
  final String? reason;
  final Map<String, dynamic> details;
  const PreflightResult(this.reason, [this.details = const {}]);
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

  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

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
      cfg.cardRefundWindowS,
    );
    customerNotice.value = null;
    return units ?? 0;
  }

  static Future<void> updateAmount(int cents, int coinsCents) async {
    final c = _ctx;
    if (c == null || c.approved) return;
    await _channel.invokeMethod('updateAmount', {'cents': cents});
    _ctx = _ArmContext(cents, c.flavorIndex, c.flavorName, coinsCents, c.deviceId, c.refundWindowS);
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

  // ---- отмена клиентом (1.11.1, ТЗ раздел 15) ----

  // Правило: возврат при отмене клиентом — только в прогреве (распыления ещё
  // не было) и только пока не прошло окно возврата с 10 05 (ровно на границе
  // — уже нет, как у сбоя). После прогрева — никогда.
  static bool refundOnClientCancel({
    required String stage,
    required int elapsedMs,
    required int refundWindowS,
  }) => stage == 'preheat' && elapsedMs >= 0 && elapsedMs < refundWindowS * 1000;

  // Что будет с деньгами, если клиент остановит цикл сейчас. null — цикл
  // оплачен не картой (или карта не одобрена): прежнее поведение экрана.
  // Повторное нажатие после принятого решения — то же решение.
  static CardCancelQuote? quoteClientCancel(String stage) {
    final c = _ctx;
    if (c == null || !c.approved) return null;
    final sid = SessionService.currentSessionId;
    if (c.sessionId != null && sid != null && c.sessionId != sid) return null;
    final done = c.clientCancel;
    if (done != null) return done;
    final at = clock().millisecondsSinceEpoch;
    final elapsedMs = at - (c.approvedAtMs ?? at);
    return CardCancelQuote(
      stage: stage,
      refund: refundOnClientCancel(
        stage: stage,
        elapsedMs: elapsedMs,
        refundWindowS: c.refundWindowS,
      ),
      atMs: at,
      elapsedS: elapsedMs ~/ 1000,
    );
  }

  // Клиент подтвердил остановку (или подтверждение не требовалось): решение
  // — в запись payment_pending, затем терминалу. Вызывать ДО остановки
  // выходов: возврат 13 03 в окне не должен ждать подтверждения выключения.
  static Future<void> clientCancel(CardCancelQuote q) async {
    final c = _ctx;
    if (c == null || !c.approved || c.clientCancel != null) return;
    c.clientCancel = q;
    AppLog.log(
      'CardPayment',
      'отмена клиентом (${q.stage}, ${q.elapsedS} с после одобрения): '
          '${q.refund ? 'автовозврат' : 'без возврата, услуга оказана'}',
    );
    final p = await CardPaymentStore.pending();
    if (p != null) {
      final ok = await CardPaymentStore.writePending(p.copyWith(clientCancel: q.toJson()));
      if (!ok) AppLog.log('CardPayment', 'ВНИМАНИЕ: решение об отмене не записано');
    }
    try {
      await _channel.invokeMethod('clientCancel', {'stage': q.stage, 'refund': q.refund});
    } catch (e) {
      // Автомат недоступен — итог без терминала: возврат положен, но не
      // выполнен — ручной; без возврата — закрыть как оказанную услугу.
      AppLog.log('CardPayment', 'отмена клиентом в терминал не передана: $e');
      await handlePaymentEvent({
        'type': q.refund ? 'manual_refund_needed' : 'client_cancelled_no_refund',
        'data': {
          'stage': q.stage,
          'cycle_reason': clientCancelReason,
          'elapsed_s': q.elapsedS,
          'refund': q.refund ? 'терминал недоступен' : 'не положен (отмена клиентом)',
          'confirm': 'терминал недоступен',
        },
      });
    }
  }

  // ---- итог цикла ----

  static void _onSessionFinished(
    String sessionId,
    bool completed,
    String? reason, [
    Map<String, dynamic>? extra,
  ]) {
    final c = _ctx;
    if (c == null || !c.approved) return;
    if (c.sessionId != null && c.sessionId != sessionId) return;
    // Отмена клиентом различается по причине завершения, не по таймеру.
    // Экран уже передал решение при нажатии — здесь только запасной путь
    // (причина пришла без clientCancel).
    if (!completed && reason == clientCancelReason) {
      if (c.clientCancel != null) return;
      final q = quoteClientCancel(extra?['stage'] as String? ?? '');
      if (q != null) unawaited(clientCancel(q));
      return;
    }
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
          c.approvedAtMs = (data['approved_at'] as num?)?.toInt() ?? at.millisecondsSinceEpoch;
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
      // Отмена клиентом без возврата (1.11.1): услуга оказана, только облако —
      // ни ручного возврата, ни Telegram.
      case 'client_cancelled_no_refund':
        final closed = await CardPaymentStore.close('client_cancelled_no_refund', data, now: now);
        final q = c?.clientCancel ?? CardCancelQuote.fromJson(closed?.clientCancel);
        unawaited(CloudService.report('payment_client_cancelled_no_refund', data: {
          ...base,
          ...data,
          'stage': q?.stage ?? data['stage'],
          'elapsed_s': q?.elapsedS ?? data['elapsed_s'],
        }));
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
    final cancel = CardCancelQuote.fromJson(p.clientCancel);
    _ctx = _ArmContext(p.amountCents, p.flavorIndex, p.flavorName, p.coinsCents, cfg.deviceId, cfg.cardRefundWindowS)
      ..sessionId = p.sessionId
      ..approved = true
      ..approvedAtMs = p.approvedAtMs
      ..clientCancel = cancel;
    AppLog.log('CardPayment', 'при старте найдена незакрытая оплата картой ${p.amountCents} центов (${p.id})');
    // Клиент успел отменить без возврата — это не сбой: закрыть как
    // оказанную услугу (терминал подтвердит списание сам).
    if (cancel != null && !cancel.refund) {
      await handlePaymentEvent({
        'type': 'client_cancelled_no_refund',
        'data': {
          'recovered': true,
          'stage': cancel.stage,
          'cycle_reason': clientCancelReason,
          'elapsed_s': cancel.elapsedS,
          'confirm': 'не отправлен (перезапуск)',
        },
      }, now: t);
      return;
    }
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
  static Future<String?> preflight(AppNotifier n, int flavorIndex) async =>
      (await preflightDetailed(n, flavorIndex)).reason;

  // Модули (ввод-вывод, термопара, счётчик) — до preflightAttempts СВЕЖИХ
  // чтений подряд с паузой preflightRetryPause (1.11.3): одиночный сбой
  // обмена по RS-485 больше не закрывает оплату. Первое годное — модуль в
  // порядке; «недоступно» — только если все чтения негодные (тот же
  // критерий «3 подряд», что у детектора в цикле). Кэш для решения не
  // используется. details — для события hardware_error card_preflight.
  static const int preflightAttempts = 3;
  static const Duration preflightRetryPause = Duration(milliseconds: 300);
  @visibleForTesting
  static Future<void> Function(Duration) preflightPause = Future<void>.delayed;

  static Future<ProbeResult> _probe<T>(
    Future<ModbusRead<T>> Function() read,
    bool Function(T) usable, {
    bool keepValue = false,
  }) => probeModule<T>(
    read,
    usable,
    attempts: preflightAttempts,
    retryPause: preflightRetryPause,
    pause: preflightPause,
    keepValue: keepValue,
  );

  static Future<PreflightResult> preflightDetailed(AppNotifier n, int flavorIndex) async {
    final cfg = n.config;
    if (n.isPaymentBlocked) return const PreflightResult('payment_blocked');
    if (!n.busHealthy) return const PreflightResult('bus');
    final levels = n.levels;
    if (flavorIndex >= levels.length || !levels[flavorIndex]) {
      return const PreflightResult('level');
    }
    if (cfg.dioInstalled) {
      final p = await _probe<List<bool>>(ModbusService.readAllInputsDetailed, (_) => true);
      if (!p.ok) {
        return PreflightResult('io_module', p.details(lastOkAt: ModbusService.lastInputsOkAt));
      }
    }
    // Негодное показание (null, обрыв −500, вне диапазона) — то же, что нет
    // показания (1.11.2): греть по нему нельзя.
    if (cfg.thermoInstalled) {
      final p = await _probe<double>(
        ModbusService.readTemperatureDetailed,
        HeaterSafetyMonitor.isUsable,
        keepValue: true,
      );
      if (!p.ok) {
        final last = ModbusService.lastUsableTemperature;
        return PreflightResult('thermocouple', {
          ...p.details(lastOkAt: last?.at),
          'last_usable_c': last?.c,
        });
      }
    }
    if (cfg.energyMeterInstalled) {
      final p = await _probe<Map<String, double>>(ModbusService.readEnergyDetailed, (_) => true);
      if (!p.ok) {
        return PreflightResult('energy_meter', p.details(lastOkAt: ModbusService.lastEnergyOkAt));
      }
    }
    return const PreflightResult(null);
  }

  @visibleForTesting
  static void resetForTest() {
    _ctx = null;
    customerNotice.value = null;
    clock = DateTime.now;
    preflightPause = Future<void>.delayed;
  }

  // Статус терминала для экрана оплаты.
  static CardTerminalStatus get terminal => CardTerminalService.status.value;
}
