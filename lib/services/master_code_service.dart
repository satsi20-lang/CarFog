import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/security_limits.dart';

// Мастер-код аварийного доступа — свой на КАЖДЫЙ аппарат (R2.0, п. A).
//
// Прежняя схема (константа в коде, одинаковая у всех аппаратов) снята:
// значение оказалось в открытом тексте внутри собранного приложения и в
// репозитории и считается скомпрометированным.
//
// Новая схема:
//  * код — 8 случайных цифр (Random.secure), генерируется на аппарате;
//  * в хранилище лежит ТОЛЬКО хэш с индивидуальной солью (PBKDF2-HMAC-
//    SHA256; простой SHA-256 для 8 цифр перебирался бы за секунды) и число
//    итераций; сам код нигде не хранится — его видно один раз при
//    генерации в сервисном меню после действующего PIN;
//  * проверка — сравнение хэшей за постоянное время;
//  * флаг "записан" (acknowledged) ставится, только когда техник
//    подтвердил, что код записан; до этого аппарат в облачном отчёте
//    значится с master_code_acknowledged=false (незавершённый ввод в
//    эксплуатацию).
class MasterCodeService {
  MasterCodeService._();

  static const _kHash = 'master_code_hash';
  static const _kSalt = 'master_code_salt';
  static const _kIter = 'master_code_iter';
  static const _kAck = 'master_code_ack';

  // Новый код: хэш и соль записываются, прежний перестаёт действовать,
  // флаг "записан" сбрасывается. Возвращает код ОДИН РАЗ — для показа.
  static Future<String> generateNew({Random? random}) async {
    final rnd = random ?? Random.secure();
    final code = List.generate(
      SecurityLimits.masterCodeDigits,
      (_) => rnd.nextInt(10),
    ).join();
    final salt = List<int>.generate(
      SecurityLimits.masterSaltBytes,
      (_) => rnd.nextInt(256),
    );
    final iterations = SecurityLimits.masterKdfIterations;
    final hash = pbkdf2(code, salt, iterations);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHash, _hex(hash));
    await prefs.setString(_kSalt, _hex(salt));
    await prefs.setInt(_kIter, iterations);
    await prefs.setBool(_kAck, false);
    return code;
  }

  static Future<bool> hasCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kHash) != null;
  }

  // Техник подтвердил, что код записан.
  static Future<void> markAcknowledged() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kHash) == null) return;
    await prefs.setBool(_kAck, true);
  }

  static Future<bool> isAcknowledged() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kAck) ?? false;
  }

  // Совпадает ли введённое с действующим кодом. Нет кода — false.
  static Future<bool> verify(String entered) async {
    final prefs = await SharedPreferences.getInstance();
    final hash = prefs.getString(_kHash);
    final salt = prefs.getString(_kSalt);
    if (hash == null || salt == null) return false;
    final iterations = prefs.getInt(_kIter) ?? SecurityLimits.masterKdfIterations;
    final got = pbkdf2(entered, _unhex(salt), iterations);
    return constantTimeEquals(got, _unhex(hash));
  }

  // PBKDF2-HMAC-SHA256, один блок (32 байта). Открыт для тестов
  // (контрольные векторы RFC 7914 / RFC 6070 для SHA-256).
  @visibleForTesting
  static List<int> pbkdf2(String password, List<int> salt, int iterations) {
    final hmac = Hmac(sha256, utf8.encode(password));
    var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
    final t = List<int>.from(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    return t;
  }

  // Сравнение без раннего выхода: время не зависит от того, в каком байте
  // найдено расхождение.
  @visibleForTesting
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static List<int> _unhex(String s) => [
    for (var i = 0; i + 1 < s.length; i += 2)
      int.parse(s.substring(i, i + 2), radix: 16),
  ];

  // Только для тестов: записать хэш заданного кода.
  @visibleForTesting
  static Future<void> setCodeForTest(String code, {List<int>? salt}) async {
    final s = salt ?? List<int>.generate(16, (i) => i + 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kHash, _hex(pbkdf2(code, s, 10)));
    await prefs.setString(_kSalt, _hex(s));
    await prefs.setInt(_kIter, 10);
  }
}
