import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../models/update_limits.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'remote_command_guard.dart';
import 'remote_commands.dart';
import 'update_service.dart';

// Раскатка по целевой версии (R3). Сервер в ответе device_poll отдаёт
// «цель», когда для этого аппарата пора (кольцо, окно, задержка считаются на
// сервере). Аппарат сам обновляется тем же UpdateService.startUpdate: все
// проверки, скрипт и откат — те же. Пока аппарат занят или окно закрыто,
// опрос продолжает возвращать цель, поэтому повтор не нужен. Откат остаётся
// ручным.
class RolloutService {
  RolloutService._();

  // Бэкофф после отказа до запуска скрипта (на ЭТОТ релиз). ЗАДАНО
  // владельцем: 6 часов.
  static const Duration failureBackoff = Duration(hours: 6);

  static const _kBlocked = 'rollout_blocked_code';
  static String _kBackoff(String releaseId) => 'rollout_backoff_$releaseId';

  // Код цели, которую сейчас видит аппарат (null — цели нет). Идёт в слепок
  // настроек как rollout_target_code.
  static int? targetCode;

  // Подменяемые в тестах часы.
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  static bool _running = false;

  @visibleForTesting
  static void resetForTest() {
    targetCode = null;
    clock = DateTime.now;
    _running = false;
  }

  // Вызывается после каждого успешного опроса облака.
  static Future<void> onPoll(AppNotifier n, RolloutTarget? target) async {
    targetCode = target?.versionCode;
    if (target == null) return;
    // Тестовая сборка без сигнала здоровья раскатку не получает: она бы
    // откатилась сама, но и пытаться незачем.
    if (UpdateService.skipHealthSignal) return;
    if (_running || UpdateService.inProgress) return;
    _running = true;
    try {
      await _maybeStart(n, target);
    } catch (e) {
      AppLog.log('RolloutService', 'ошибка: ${e.runtimeType}');
    } finally {
      _running = false;
    }
  }

  static Future<void> _maybeStart(AppNotifier n, RolloutTarget target) async {
    // 1. цель новее установленной
    final info = await UpdateService.appInfoProvider();
    if (info == null || target.versionCode <= info.versionCode) return;

    // 2. покой (то же условие, что для update_app из облака) и не идёт
    // обновление/обслуживание
    if (!RemoteCommands.isIdleForUpdate(n.state) || n.isMaintenance) return;

    final prefs = await SharedPreferences.getInstance();
    final now = clock();

    // 3. релиз не заблокирован автооткатом (до цели с БОЛЬШИМ кодом)
    final blocked = prefs.getInt(_kBlocked);
    if (blocked != null && target.versionCode <= blocked) return;

    // 4. бэкофф после неудачи на этот релиз
    final last = DateTime.tryParse(prefs.getString(_kBackoff(target.releaseId)) ?? '');
    if (last != null && now.isAfter(last) && now.difference(last) < failureBackoff) return;

    // 5. те же лимиты, что у update_app: пауза 10 минут, 3 запуска и 12
    // неудач в сутки (метки идут в те же счётчики)
    if (!await CommandGuard.allowUpdateAttempt(
      'update_app',
      now: now,
      minInterval: UpdateLimits.commandMinInterval,
      window: UpdateLimits.quotaWindow,
      maxRuns: UpdateLimits.commandsPerDay,
      maxFailures: UpdateLimits.failuresPerDay,
    )) {
      return;
    }

    AppLog.log('RolloutService', 'цель ${target.versionName}(${target.versionCode}), запускаю обновление');
    final res = await UpdateService.startUpdate(
      n,
      target.releaseId,
      countQuota: true,
      source: 'rollout',
      rolloutId: target.rolloutId,
    );
    if (!res.ok) {
      // busy в этот путь не попадает (покой проверен выше); update_in_progress
      // — не отказ релиза.
      if (res.result != 'update_in_progress') await noteFailure(target.releaseId);
      return;
    }
    // Ack команде не нужен: скрипт запускаем сразу.
    if (res.afterAck != null) await res.afterAck!();
    if (!UpdateService.lastLaunchStarted) await noteFailure(target.releaseId);
  }

  // Любой отказ до запуска (и сбой установки после него): не бить сервер
  // этим релизом 6 часов.
  static Future<void> noteFailure(String releaseId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kBackoff(releaseId), clock().toIso8601String());
    } catch (_) {}
  }

  // Автоматический откат версии с кодом [versionCode]: не пытаться поставить
  // её (и более старые) снова, пока не появится цель с большим кодом.
  static Future<void> markBlocked(int versionCode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cur = prefs.getInt(_kBlocked) ?? 0;
      if (versionCode > cur) await prefs.setInt(_kBlocked, versionCode);
    } catch (_) {}
  }
}
