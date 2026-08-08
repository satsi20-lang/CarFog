import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_service.dart';

enum PinResult { ok, wrong, locked }

class SecurityService {
  // --- Параметры защиты ---
  static const int maxAttempts = 3;
  static const int lockoutMinutes = 20;

  // ⚠️ МАСТЕР-КОД АВАРИЙНОГО ДОСТУПА
  // Сменить перед серийным выпуском. Хранить отдельно от аппарата.
  // Использование фиксируется событием в облаке.
  static const String masterCode = '48217390';

  static const _kFails = 'pin_fail_count';
  static const _kLockUntil = 'pin_lock_until_ms';

  // ============================================================
  // ЧТЕНИЕ СОСТОЯНИЯ
  // ============================================================

  static Future<int> failCount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_kFails) ?? 0;
  }

  static Future<int> attemptsLeft() async {
    final left = maxAttempts - await failCount();
    return left < 0 ? 0 : left;
  }

  // Сколько осталось до разблокировки. Zero — не заблокировано.
  static Future<Duration> remainingLock() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final untilMs = prefs.getInt(_kLockUntil);
      if (untilMs == null) return Duration.zero;

      final until = DateTime.fromMillisecondsSinceEpoch(untilMs);
      final diff = until.difference(DateTime.now());

      if (diff.isNegative) {
        await _clearLock();
        return Duration.zero;
      }

      // Защита от перевода часов планшета назад: блокировка не может
      // длиться дольше номинального срока.
      if (diff.inMinutes > lockoutMinutes) {
        await _clearLock();
        return Duration.zero;
      }

      return diff;
    } catch (e) {
      debugPrint('SecurityService.remainingLock error: $e');
      return Duration.zero;
    }
  }

  static Future<bool> isLocked() async =>
      (await remainingLock()) > Duration.zero;

  // ============================================================
  // ПРОВЕРКА PIN
  // ============================================================

  static Future<PinResult> tryPin(String entered, String correctPin) async {
    if (await isLocked()) return PinResult.locked;

    final prefs = await SharedPreferences.getInstance();

    if (entered == correctPin) {
      await resetAttempts();
      await CloudService.report(CloudEventType.serviceLoginOk);
      return PinResult.ok;
    }

    final fails = (prefs.getInt(_kFails) ?? 0) + 1;
    await prefs.setInt(_kFails, fails);

    if (fails >= maxAttempts) {
      final until = DateTime.now().add(const Duration(minutes: lockoutMinutes));
      await prefs.setInt(_kLockUntil, until.millisecondsSinceEpoch);

      await CloudService.report(
        CloudEventType.unauthorizedAccess,
        data: {
          'attempts': fails,
          'locked_until': until.toIso8601String(),
          'lockout_minutes': lockoutMinutes,
        },
      );
      return PinResult.locked;
    }

    return PinResult.wrong;
  }

  // ============================================================
  // МАСТЕР-КОД
  // ============================================================

  static bool isMasterCode(String code) => code == masterCode;

  // ============================================================
  // СБРОС СЧЁТЧИКОВ
  // ============================================================

  static Future<void> resetAttempts() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kFails);
    await prefs.remove(_kLockUntil);
  }

  static Future<void> _clearLock() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLockUntil);
    await prefs.remove(_kFails);
  }
}
