import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/remote_limits.dart';
import 'cloud_service.dart';

// Защита исполнения удалённых команд (R1): срок действия, идемпотентность
// по command_id, лимит частоты. Состояние хранится в SharedPreferences и
// переживает перезапуск — это существенно для restart_app: если ack не
// дошёл (нет связи), сервер доставит ту же команду снова после
// перезапуска, и без постоянной памяти получился бы цикл перезапусков.
//
// Порядок проверок: дубль → просрочена → (в исполнителе) занят → лимит.
class CommandGuard {
  CommandGuard._();

  static const _seenKey = 'remote_seen_command_ids';
  static const _historyKey = 'remote_command_history';
  static String _rateKey(String action) => 'remote_rate_$action';

  // Дубль и срок. null — выполнять можно. Идентификатор запоминается
  // сразу (в том числе для отказанных команд): повторная доставка ЛЮБОЙ
  // уже обработанной команды не исполняется второй раз.
  // Срок считается по часам СЕРВЕРА: serverTime (из ответа device_poll) −
  // created_at команды. Часы планшета (now) — только запасной вариант, если
  // сервер server_time не отдал.
  static Future<String?> preCheck(
    CloudCommand c, {
    DateTime? now,
    DateTime? serverTime,
  }) async {
    final t = serverTime ?? now ?? DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getStringList(_seenKey) ?? <String>[];
    if (c.id.isNotEmpty && seen.contains(c.id)) return 'duplicate';

    if (c.id.isNotEmpty) {
      seen.add(c.id);
      while (seen.length > RemoteCommandLimits.seenIdsCapacity) {
        seen.removeAt(0);
      }
      await prefs.setStringList(_seenKey, seen);
    }

    final created = c.createdAt;
    if (created == null) {
      // Сервер не отдал created_at (старый ответ, сбой) — срок проверить
      // нечем. Чувствительные команды в этом случае НЕ выполняются;
      // безобидные идут с пометкой в журнале.
      if (RemoteCommandLimits.requireCreatedAt.contains(c.action)) {
        debugPrint('CommandGuard: у команды ${c.action} нет created_at — '
            'отказ (no_created_at)');
        return 'no_created_at';
      }
      debugPrint('CommandGuard: у команды ${c.action} нет created_at — срок '
          'действия не проверен');
      return null;
    }
    if (t.difference(created) > RemoteCommandLimits.maxAge) return 'expired';
    return null;
  }

  // Лимит частоты для action: не чаще minInterval и не более maxPerHour за
  // час. true — можно (попытка записывается), false — rate_limited.
  // Параметры по умолчанию — лимиты R1 (раз в минуту, 3 в час); для команд
  // обновления вызывающий код задаёт свои (10 минут, 3 в сутки).
  static Future<bool> allowRate(
    String action, {
    DateTime? now,
    Duration? minInterval,
    Duration window = const Duration(hours: 1),
    int? maxPerWindow,
  }) async {
    final t = now ?? DateTime.now();
    final interval = minInterval ?? RemoteCommandLimits.minInterval;
    final maxCount = maxPerWindow ?? RemoteCommandLimits.maxPerHour;
    final prefs = await SharedPreferences.getInstance();
    final stamps = (prefs.getStringList(_rateKey(action)) ?? <String>[])
        .map(DateTime.tryParse)
        .whereType<DateTime>()
        .where((d) => t.difference(d) < window)
        .toList();
    if (stamps.isNotEmpty && t.difference(stamps.last) < interval) {
      return false;
    }
    if (stamps.length >= maxCount) return false;
    stamps.add(t);
    await prefs.setStringList(
      _rateKey(action),
      stamps.map((d) => d.toIso8601String()).toList(),
    );
    return true;
  }

  // ---- Лимиты update_app / rollback_app ----
  //  * пауза minInterval между ЛЮБЫМИ принятыми попытками;
  //  * суточный счёт запусков скрипта (maxRuns за window) — метку ставит
  //    countRun, когда скрипт действительно запущен;
  //  * суточный счёт неудач до запуска (maxFailures) — countFailure.
  // Отказ (false) ничего не записывает.
  static String _lastKey(String a) => 'remote_upd_last_$a';
  static String _runsKey(String a) => 'remote_upd_runs_$a';
  static String _failsKey(String a) => 'remote_upd_fails_$a';

  static Future<List<DateTime>> _stamps(
    SharedPreferences prefs,
    String key,
    DateTime now,
    Duration window,
  ) async => (prefs.getStringList(key) ?? <String>[])
      .map(DateTime.tryParse)
      .whereType<DateTime>()
      .where((d) => now.difference(d) < window)
      .toList();

  static Future<bool> allowUpdateAttempt(
    String action, {
    DateTime? now,
    required Duration minInterval,
    required Duration window,
    required int maxRuns,
    required int maxFailures,
  }) async {
    final t = now ?? DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final last = DateTime.tryParse(prefs.getString(_lastKey(action)) ?? '');
    // Часы ушли назад (last в будущем) — паузой не блокируем навсегда.
    if (last != null && t.isAfter(last) && t.difference(last) < minInterval) {
      return false;
    }
    if ((await _stamps(prefs, _runsKey(action), t, window)).length >= maxRuns) {
      return false;
    }
    if ((await _stamps(prefs, _failsKey(action), t, window)).length >= maxFailures) {
      return false;
    }
    await prefs.setString(_lastKey(action), t.toIso8601String());
    return true;
  }

  static Future<void> _append(String key, Duration window, DateTime? now) async {
    final t = now ?? DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final list = await _stamps(prefs, key, t, window)
      ..add(t);
    await prefs.setStringList(key, list.map((d) => d.toIso8601String()).toList());
  }

  // Скрипт обновления/отката запущен.
  static Future<void> countRun(String action, {DateTime? now, required Duration window}) =>
      _append(_runsKey(action), window, now);

  // Попытка закончилась отказом ДО запуска скрипта.
  static Future<void> countFailure(String action, {DateTime? now, required Duration window}) =>
      _append(_failsKey(action), window, now);

  // ---------------- история для сервисного меню ----------------

  static Future<void> record({
    required String action,
    required bool ok,
    required String result,
    DateTime? now,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_historyKey) ?? <String>[];
    list.add(jsonEncode({
      'at': (now ?? DateTime.now()).toIso8601String(),
      'action': action,
      'ok': ok,
      'result': result.length > 300 ? '${result.substring(0, 300)}…' : result,
    }));
    while (list.length > RemoteCommandLimits.historyShown) {
      list.removeAt(0);
    }
    await prefs.setStringList(_historyKey, list);
  }

  // Новые — первыми.
  static Future<List<Map<String, dynamic>>> history() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_historyKey) ?? <String>[];
    return list.reversed
        .map((s) => jsonDecode(s) as Map<String, dynamic>)
        .toList();
  }
}
