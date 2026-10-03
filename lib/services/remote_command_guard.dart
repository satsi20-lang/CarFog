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
