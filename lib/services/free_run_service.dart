import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_state.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'master_code_service.dart';

// Бесплатный запуск по 6-значному коду (только там, где владелец включил).
//
// Хранение кода: в настройках аппарата лежат ТОЛЬКО соль (16 байт) и хеш
// PBKDF2-HMAC-SHA256 (тот же модуль, что у мастер-кода, 10 000 итераций,
// 32 байта). Хеш приходит из облака командой update_config
// (free_run_code_hash / free_run_code_salt); открытый код приложение
// никогда не видит, не хранит и не пишет в журнал.
//
// Перебор: 5 неверных попыток подряд — блок на 15 минут. Счётчик и срок
// блока лежат в SharedPreferences и переживают перезапуск приложения.
// Событие free_run_locked уходит в облако (без введённых цифр).
//
// По умолчанию функция ВЫКЛЮЧЕНА: пока free_run_enabled не пришёл как true
// вместе с корректными хешем и солью, пункта в меню нет, код не принимается.

class FreeRunLimits {
  FreeRunLimits._();

  static const int digits = 6;
  static const int maxAttempts = 5;
  static const int lockoutMinutes = 15;

  /// PBKDF2: число итераций и размеры. Портал считает по тем же параметрам.
  static const int kdfIterations = 10000;
  static const int saltBytes = 16;
  static const int hashBytes = 32;
  static const int saltHexLen = saltBytes * 2;
  static const int hashHexLen = hashBytes * 2;

  /// Экран ввода кода без касаний столько — назад на заставку (как у PIN).
  static const Duration idleTimeout = Duration(seconds: 30);
}

enum FreeRunResult { ok, wrong, locked, disabled }

/// Проверка значений из update_config и из сохранённых настроек.
class FreeRunParams {
  FreeRunParams._();

  static const String enabledKey = 'free_run_enabled';
  static const String hashKey = 'free_run_code_hash';
  static const String saltKey = 'free_run_code_salt';
  static const List<String> all = [enabledKey, hashKey, saltKey];

  static final RegExp _hex = RegExp(r'^[0-9a-f]+$');

  /// Строка hex ровно [len] символов (нижний регистр) или null.
  static String? hex(Object? v, int len) {
    if (v is! String) return null;
    final s = v.toLowerCase();
    return s.length == len && _hex.hasMatch(s) ? s : null;
  }

  static String hexOrEmpty(Object? v, int len) => hex(v, len) ?? '';

  static bool loadEnabled(Object? enabled, Object? hash, Object? salt) =>
      enabled == true &&
      hex(hash, FreeRunLimits.hashHexLen) != null &&
      hex(salt, FreeRunLimits.saltHexLen) != null;

  /// null — всё в порядке; иначе 'bad_type:поле' (в ответ на команду).
  static String? validate(Map<String, dynamic> params) {
    if (params.containsKey(enabledKey) && params[enabledKey] is! bool) {
      return 'bad_type:$enabledKey';
    }
    if (params.containsKey(hashKey) && hex(params[hashKey], FreeRunLimits.hashHexLen) == null) {
      return 'bad_type:$hashKey';
    }
    if (params.containsKey(saltKey) && hex(params[saltKey], FreeRunLimits.saltHexLen) == null) {
      return 'bad_type:$saltKey';
    }
    return null;
  }
}

class FreeRunService {
  FreeRunService._();

  static const _kFails = 'free_run_fail_count';
  static const _kLockUntil = 'free_run_lock_until_ms';

  static DateTime Function() clock = DateTime.now;

  /// Отправка события в облако (подменяется в тестах).
  static Future<void> Function(String type, Map<String, dynamic> data) reporter =
      (type, data) => CloudService.report(type, data: data);

  /// Функция включена и хеш с солью корректны.
  static bool isEnabled(AppConfig c) => FreeRunParams.loadEnabled(
        c.freeRunEnabled,
        c.freeRunCodeHash,
        c.freeRunCodeSalt,
      );

  // ---------------- перебор ----------------

  static Future<int> attemptsLeft() async {
    final prefs = await SharedPreferences.getInstance();
    final left = FreeRunLimits.maxAttempts - (prefs.getInt(_kFails) ?? 0);
    return left < 0 ? 0 : left;
  }

  /// Сколько осталось до конца блока. Zero — не заблокировано.
  static Future<Duration> remainingLock() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final untilMs = prefs.getInt(_kLockUntil);
      if (untilMs == null) return Duration.zero;
      final diff = DateTime.fromMillisecondsSinceEpoch(untilMs).difference(clock());
      if (diff.isNegative || diff == Duration.zero) {
        await _clear(prefs);
        return Duration.zero;
      }
      // Часы переведены назад: блок не может быть дольше номинального срока.
      if (diff > const Duration(minutes: FreeRunLimits.lockoutMinutes)) {
        await _clear(prefs);
        return Duration.zero;
      }
      return diff;
    } catch (_) {
      return Duration.zero;
    }
  }

  static Future<void> _clear(SharedPreferences prefs) async {
    await prefs.remove(_kLockUntil);
    await prefs.remove(_kFails);
  }

  /// Проверка введённого кода. Введённые цифры никуда не пишутся.
  static Future<FreeRunResult> tryCode(AppConfig cfg, String entered) async {
    if (!isEnabled(cfg)) return FreeRunResult.disabled;
    if ((await remainingLock()) > Duration.zero) return FreeRunResult.locked;
    final prefs = await SharedPreferences.getInstance();

    final salt = FreeRunParams.hex(cfg.freeRunCodeSalt, FreeRunLimits.saltHexLen)!;
    final want = FreeRunParams.hex(cfg.freeRunCodeHash, FreeRunLimits.hashHexLen)!;
    var match = false;
    if (RegExp('^[0-9]{${FreeRunLimits.digits}}\$').hasMatch(entered)) {
      final got = MasterCodeService.derive(entered, _unhex(salt), FreeRunLimits.kdfIterations);
      match = MasterCodeService.equalBytes(got, _unhex(want));
    }
    if (match) {
      await _clear(prefs);
      return FreeRunResult.ok;
    }

    final fails = (prefs.getInt(_kFails) ?? 0) + 1;
    await prefs.setInt(_kFails, fails);
    if (fails >= FreeRunLimits.maxAttempts) {
      final until = clock().add(const Duration(minutes: FreeRunLimits.lockoutMinutes));
      await prefs.setInt(_kLockUntil, until.millisecondsSinceEpoch);
      AppLog.log('FreeRun', 'перебор кода: блок на ${FreeRunLimits.lockoutMinutes} мин');
      unawaited(reporter(CloudEventType.freeRunLocked, {
        'attempts': fails,
        'lockout_minutes': FreeRunLimits.lockoutMinutes,
        'locked_until': until.toUtc().toIso8601String(),
      }));
      return FreeRunResult.locked;
    }
    return FreeRunResult.wrong;
  }

  // ---------------- один запуск ----------------

  static bool _armed = false;

  /// Код принят: ближайший выбор аромата запустит процесс без оплаты, один раз.
  static bool get armed => _armed;
  static void arm() => _armed = true;
  static void disarm() => _armed = false;

  /// true — «взвод» был и снят этим вызовом (повторно вернёт false).
  static bool consumeArm() {
    final was = _armed;
    _armed = false;
    return was;
  }

  static List<int> _unhex(String s) => [
        for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16),
      ];

  /// Для тестов: хеш кода в формате настроек.
  static ({String hash, String salt}) hashForTest(String code, List<int> salt) {
    String hx(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return (
      hash: hx(MasterCodeService.derive(code, salt, FreeRunLimits.kdfIterations)),
      salt: hx(salt),
    );
  }

  static void resetForTest() {
    clock = DateTime.now;
    reporter = (type, data) => CloudService.report(type, data: data);
    _armed = false;
  }
}
