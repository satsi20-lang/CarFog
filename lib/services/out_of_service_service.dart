import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/app_state.dart';
import '../models/out_of_service.dart';
import 'cloud_service.dart';

// Вывод аппарата из обслуживания (задача "вывод аппарата из обслуживания").
// Один механизм с кодом причины: новые неустранимые отказы подключаются
// через trip(), а не заводят свою логику. Сейчас причины две —
// OutOfServiceCode.heaterNoPower и OutOfServiceCode.tempSensorFault, плюс
// служебная stateUnreadable (fail-closed при старте).
//
// Критерий вывода: безопасная услуга физически невозможна. Отказ
// монетоприёмника сюда НЕ входит — клиент доплачивает картой, услуга
// оказывается.
//
// Порядок при отказе (trip): 1) признак записывается в постоянное
// хранилище с fsync и запись ПОДТВЕРЖДАЕТСЯ (await — не fire-and-forget:
// питание может пропасть именно в этот момент), 2) только потом экран
// "не работает", 3) только потом событие в облако.
class OutOfServiceService {
  OutOfServiceService._();

  static const _channel = MethodChannel('com.carfog.dryfog/system');

  // Сколько раз повторить запись, если нативная сторона не подтвердила.
  // Чтение при старте: сколько раз повторить при исключении канала.
  static const _readAttempts = 3;
  static const _readRetryPause = Duration(milliseconds: 200);

  static const _writeAttempts = 3;
  static const _writeRetryPause = Duration(milliseconds: 100);

  // Пробный цикл считается "свежим" ограниченное время: техник мог пройти
  // его, а потом снова вынуть предохранитель — снимать блокировку по
  // старому проходу нельзя.
  static const trialValidity = Duration(minutes: 15);
  static DateTime? _trialPassedAt;

  static bool get trialPassedRecently {
    final t = _trialPassedAt;
    return t != null && DateTime.now().difference(t) <= trialValidity;
  }

  static DateTime? get trialPassedAt => _trialPassedAt;

  // Запись не подтвердилась (диск/канал не ответили): аппарат уже заблокирован
  // в памяти, но после перезапуска блокировка исчезла бы. Поэтому запись
  // повторяется в фоне, пока не подтвердится или пока блокировку не снимут —
  // раньше это только отмечалось полем persisted=false в событии.
  static const _repersistInterval = Duration(seconds: 20);
  static Timer? _repersistTimer;

  static void _scheduleRepersist(AppNotifier notifier) {
    _repersistTimer?.cancel();
    _repersistTimer = Timer.periodic(_repersistInterval, (timer) async {
      final current = notifier.outOfService;
      if (current == null) {
        timer.cancel();
        _repersistTimer = null;
        return;
      }
      if (await persist(current)) {
        timer.cancel();
        _repersistTimer = null;
        await CloudService.report(
          CloudEventType.outOfService,
          data: {
            'code': current.code,
            'since': current.since.toIso8601String(),
            'persisted': true,
            'late_persist': true,
          },
        );
      }
    });
  }

  // ============================================================
  // ВОССТАНОВЛЕНИЕ ПРИ СТАРТЕ (до того, как экран доступен клиенту)
  // ============================================================

  // null — аппарат рабочий: записи нет совсем (чистое первое включение —
  // это не ошибка). Любая другая ситуация, кроме явно целой записи, —
  // fail-closed: хранилище не читается, запись повреждена или не
  // разбирается → state_unreadable.
  static Future<OutOfServiceState?> restore() async {
    String lastProblem = 'read_failed';
    // Исключение канала / пустой ответ при старте — чаще разовый сбой, чем
    // реальная поломка хранилища: несколько попыток, и только потом
    // fail-closed. Явный ответ "повреждена" повторять незачем.
    for (var attempt = 0; attempt < _readAttempts; attempt++) {
      try {
        final r = await _channel.invokeMethod<Map>('readOutOfService');
        final status = r?['status'];
        if (status == 'none') return null;
        if (status == 'ok') {
          final json = r?['json'];
          if (json is String) {
            final parsed = OutOfServiceState.tryParse(jsonDecode(json));
            if (parsed != null) return parsed;
          }
          return _unreadable('record_not_parsable');
        }
        if (status == 'corrupt') return _unreadable('record_corrupt');
        lastProblem = 'unexpected_status: $status';
      } catch (e) {
        debugPrint('OutOfServiceService.restore error (попытка ${attempt + 1}): $e');
        lastProblem = 'read_failed: $e';
      }
      if (attempt < _readAttempts - 1) {
        await Future.delayed(_readRetryPause);
      }
    }
    return _unreadable(lastProblem);
  }

  static OutOfServiceState _unreadable(String reason) => OutOfServiceState(
    code: OutOfServiceCode.stateUnreadable,
    since: DateTime.now(),
    details: {'reason': reason},
  );

  // ============================================================
  // ВЫВОД ИЗ ОБСЛУЖИВАНИЯ
  // ============================================================

  // Записывает с подтверждением. true — нативная сторона подтвердила
  // fsync+rename. Любая неудача — false (аппарат всё равно блокируется в
  // памяти, а не в хранилище это отражается в событии: persisted=false).
  static Future<bool> persist(OutOfServiceState state) async {
    final json = jsonEncode(state.toJson());
    for (var i = 0; i < _writeAttempts; i++) {
      try {
        final ok = await _channel.invokeMethod<bool>('writeOutOfService', {
          'json': json,
        });
        if (ok == true) return true;
      } catch (e) {
        debugPrint('OutOfServiceService.persist error: $e');
      }
      await Future.delayed(_writeRetryPause);
    }
    return false;
  }

  // Вывести из обслуживания. alongside — уже запущенный параллельный
  // шаг (обычно safeAllOff()), чтобы запись на диск не откладывала
  // отключение выходов и наоборот: оба окна должны быть минимальными.
  // showScreen=false — вызывающий код сразу покажет клиенту экран ошибки
  // (оплата уже прошла), экран "не работает" появится после него.
  static Future<void> trip(
    AppNotifier notifier, {
    required String code,
    Map<String, dynamic> details = const {},
    Future<void>? alongside,
    bool showScreen = true,
  }) async {
    final existing = notifier.outOfService;
    final state = OutOfServiceState(
      code: code,
      // Первоначальный момент вывода не затираем повторными отказами.
      since: existing?.since ?? DateTime.now(),
      details: {
        ...details,
        if (existing != null && existing.code != code)
          'previous_code': existing.code,
      },
    );

    // 1) запись на диск с подтверждением — ПЕРВЫМ. Параллельно с
    // отключением выходов.
    final results = await Future.wait<Object?>([persist(state), ?alongside]);
    final persisted = results.first == true;
    _trialPassedAt = null;
    if (!persisted) _scheduleRepersist(notifier);

    // 2) экран.
    notifier.enterOutOfService(state, showScreen: showScreen);

    // 3) облако (если связи нет — в обычную очередь, уйдёт сама).
    await CloudService.report(
      CloudEventType.outOfService,
      data: {
        'code': state.code,
        'since': state.since.toIso8601String(),
        'persisted': persisted,
        ...state.details,
      },
    );
  }

  // Событие при старте, если признак восстановлен из хранилища.
  static Future<void> reportRestored(OutOfServiceState state) {
    return CloudService.report(
      CloudEventType.outOfServiceRestored,
      data: {
        'code': state.code,
        'since': state.since.toIso8601String(),
        ...state.details,
      },
    );
  }

  // ============================================================
  // ПРОБНЫЙ ЦИКЛ И СНЯТИЕ (только вручную на месте)
  // ============================================================

  static void markTrialPassed() {
    _trialPassedAt = DateTime.now();
  }

  static void invalidateTrial() {
    _trialPassedAt = null;
  }

  // Пробный цикл провалился, а аппарат уже выведен — запись о причине
  // обновляется (новый код/подробности), блокировка остаётся.
  static Future<void> recordTrialFailure(
    AppNotifier notifier, {
    required String code,
    required Map<String, dynamic> details,
  }) async {
    invalidateTrial();
    final existing = notifier.outOfService;
    if (existing == null) return;
    final updated = OutOfServiceState(
      code: code,
      since: existing.since,
      details: {
        ...details,
        'last_trial_failed_at': DateTime.now().toIso8601String(),
        if (existing.code != code) 'previous_code': existing.code,
      },
    );
    final persisted = await persist(updated);
    notifier.updateOutOfService(updated);
    if (!persisted) {
      debugPrint('OutOfServiceService.recordTrialFailure: запись не '
          'подтверждена, блокировка остаётся в памяти');
      _scheduleRepersist(notifier);
    }
  }

  // Снять блокировку. Только из сервисного меню на месте и только после
  // успешного пробного цикла (trialPassedRecently). Порядок: сначала
  // подтверждённое удаление записи, потом снятие в памяти, потом облако.
  // Если запись удалить не удалось — блокировка остаётся (fail-closed).
  // Возвращает false, если снять нельзя.
  static Future<bool> clearByTechnician(AppNotifier notifier) async {
    final state = notifier.outOfService;
    if (state == null) return true;
    if (!trialPassedRecently) return false;

    bool cleared = false;
    try {
      cleared = await _channel.invokeMethod<bool>('clearOutOfService') == true;
    } catch (e) {
      debugPrint('OutOfServiceService.clearByTechnician error: $e');
    }
    if (!cleared) return false;

    final passedAt = _trialPassedAt;
    _trialPassedAt = null;
    _repersistTimer?.cancel();
    _repersistTimer = null;
    notifier.leaveOutOfService();

    await CloudService.report(
      CloudEventType.outOfServiceCleared,
      data: {
        'code': state.code,
        'since': state.since.toIso8601String(),
        'cleared_at': DateTime.now().toIso8601String(),
        'by': 'service_menu_on_site',
        if (passedAt != null) 'trial_passed_at': passedAt.toIso8601String(),
      },
    );
    return true;
  }
}
