import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/app_state.dart';
import 'app_log_service.dart';
import 'card_payment_service.dart';
import 'cloud_service.dart';

// Терминал Nayax по MDB в основном потоке оплаты (1.11.0, ТЗ раздел 7) —
// Dart-сторона. Связь с терминалом целиком в Kotlin (MdbCardTerminal +
// MdbLinkSupervisor: очередь команд, опрос раз в 60 с, восстановление, один
// владелец порта); здесь:
//   * раз в секунду сообщить, нужен ли терминал (тип mdb) и нужен ли приём
//     карт (нет out_of_service, блокировки по конфигурации, обновления —
//     раздел 6.11: disable только в этих случаях);
//   * забрать статус и события: строки журнала → AppLog; terminal_offline /
//     terminal_recovered → облако (частоту ограничивает Kotlin: не чаще раза
//     в 5 минут); terminal_unexpected_frame → журнал и облако не чаще раза в
//     10 минут со счётчиком; card_tapped_without_flavor → подсказка экрану
//     (этап 3).
// Данных карты по MDB нет и сюда они не попадают.
class CardTerminalStatus {
  final String state;
  final String stateTitle;
  final bool cardAvailable;
  final bool readerEnabled;
  final bool inSession;
  final int consecutiveFailures;
  final int unexpectedFrames;
  // Автомат оплаты (MdbCardPayment.State) и ожидаемый возврат после
  // перезапуска.
  final String paymentState;
  final bool recoveryPending;

  const CardTerminalStatus({
    this.state = 'INACTIVE',
    this.stateTitle = '',
    this.cardAvailable = false,
    this.readerEnabled = false,
    this.inSession = false,
    this.consecutiveFailures = 0,
    this.unexpectedFrames = 0,
    this.paymentState = 'IDLE',
    this.recoveryPending = false,
  });

  CardTerminalStatus.fromMap(Map<dynamic, dynamic> m)
    : state = m['state'] as String? ?? 'INACTIVE',
      stateTitle = m['stateTitle'] as String? ?? '',
      cardAvailable = m['cardAvailable'] as bool? ?? false,
      readerEnabled = m['readerEnabled'] as bool? ?? false,
      inSession = m['inSession'] as bool? ?? false,
      consecutiveFailures = (m['consecutiveFailures'] as num?)?.toInt() ?? 0,
      unexpectedFrames = (m['unexpectedFrames'] as num?)?.toInt() ?? 0,
      paymentState = m['paymentState'] as String? ?? 'IDLE',
      recoveryPending = m['recoveryPending'] as bool? ?? false;

  // Порт у стенда — экран оплаты покажет «Терминал занят сервисным режимом».
  bool get busyService => state == 'SERVICE';
}

class CardTerminalService {
  CardTerminalService._();

  static const _channel = MethodChannel('com.carfog.dryfog/card_terminal');
  static const Duration pollInterval = Duration(seconds: 1);
  static const Duration unexpectedFrameReportEvery = Duration(minutes: 10);

  static final ValueNotifier<CardTerminalStatus> status = ValueNotifier(
    const CardTerminalStatus(),
  );
  // Клиент приложил карту, не выбрав запах (10 03 вне оплаты, сессия уже
  // закрыта 13 04) — время для подсказки «Сначала выберите запах» (этап 3).
  static final ValueNotifier<DateTime?> tappedWithoutFlavorAt = ValueNotifier(
    null,
  );

  // Последние события терминала и оплаты для вкладки «Карта» сервисного
  // меню (новые в конце, не больше recentMax). Данных карты нет.
  static const int recentMax = 20;
  static final ValueNotifier<List<String>> recent = ValueNotifier(const []);

  static void _remember(DateTime t, String text) {
    final hh = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
    final list = [...recent.value, '$hh $text'];
    recent.value = list.length > recentMax ? list.sublist(list.length - recentMax) : list;
  }

  static Timer? _timer;
  static bool _busy = false;
  static ({bool active, bool enabled})? _sent;
  static DateTime? _lastUnexpectedReport;
  static int _unexpectedSinceReport = 0;

  // Нужен ли терминал и приём карт при текущих настройках и состоянии.
  @visibleForTesting
  static ({bool active, bool enabled}) desiredFor(AppNotifier n) {
    final active = n.config.paymentTerminalType == PaymentTerminalType.mdb;
    return (active: active, enabled: active && !n.isPaymentBlocked);
  }

  static void start(AppNotifier notifier) {
    stop();
    _timer = Timer.periodic(pollInterval, (_) => _tick(notifier));
    unawaited(_tick(notifier));
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
    _sent = null;
  }

  static Future<void> _tick(AppNotifier n) async {
    if (_busy) return;
    _busy = true;
    try {
      final want = desiredFor(n);
      // Неактивный терминал после старта не трогаем вовсе.
      if (want != _sent && (want.active || _sent != null)) {
        await _channel.invokeMethod('configure', {
          'active': want.active,
          'desiredEnabled': want.enabled,
        });
        _sent = want;
      }
      if (_sent == null) return;
      final r = await _channel.invokeMethod<Map>('poll');
      if (r == null) return;
      status.value = CardTerminalStatus.fromMap(r);
      for (final e in (r['events'] as List? ?? const [])) {
        handleEvent((e as Map).cast<String, dynamic>(), n.config.deviceId);
      }
    } on MissingPluginException {
      // Тесты и платформы без Kotlin-части.
    } catch (e) {
      AppLog.log('CardTerminal', 'ошибка опроса терминала: $e');
    } finally {
      _busy = false;
    }
  }

  @visibleForTesting
  static void handleEvent(Map<String, dynamic> e, String deviceId, {DateTime? now}) {
    final t = now ?? DateTime.now();
    if (e['kind'] == 'log') {
      AppLog.log('CardTerminal', '${e['text']}');
      return;
    }
    _remember(t, '${e['kind'] == 'payment' ? 'оплата' : 'терминал'}: ${e['type']}'
        '${(e['data'] as Map?)?.isNotEmpty == true ? ' ${e['data']}' : ''}');
    // Оплата картой (автомат MdbCardPayment) — своя обработка.
    if (e['kind'] == 'payment') {
      unawaited(CardPaymentService.handlePaymentEvent(e, now: now));
      return;
    }
    final type = e['type'] as String? ?? '';
    final data = (e['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    switch (type) {
      case 'terminal_offline':
      case 'terminal_recovered':
      // Терминал перезапустился (кадр 10 00, 1.11.2) — только облако, без Telegram.
      case 'terminal_reset':
        AppLog.log('CardTerminal', '$type ${data.isEmpty ? '' : data}');
        unawaited(CloudService.report(type, data: {...data, 'device_id': deviceId}));
      case 'terminal_unexpected_frame':
        _unexpectedSinceReport++;
        AppLog.log('CardTerminal', 'неожиданный кадр терминала: ${data['reason']}');
        final last = _lastUnexpectedReport;
        if (last == null || t.difference(last) >= unexpectedFrameReportEvery) {
          unawaited(CloudService.report('terminal_unexpected_frame', data: {
            'reason': data['reason'],
            'count': _unexpectedSinceReport,
            'device_id': deviceId,
          }));
          _lastUnexpectedReport = t;
          _unexpectedSinceReport = 0;
        }
      case 'card_tapped_without_flavor':
        AppLog.log('CardTerminal', 'карта приложена без выбранного запаха — сессия закрыта 13 04');
        tappedWithoutFlavorAt.value = t;
      default:
        AppLog.log('CardTerminal', 'событие $type');
    }
  }

  @visibleForTesting
  static void resetForTest() {
    stop();
    _busy = false;
    _lastUnexpectedReport = null;
    _unexpectedSinceReport = 0;
    status.value = const CardTerminalStatus();
    tappedWithoutFlavorAt.value = null;
    recent.value = const [];
  }
}
