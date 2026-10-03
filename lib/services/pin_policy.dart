import '../models/security_limits.dart';

// Правила сервисного PIN (R2.0, п. B). PIN 1234 остаётся только начальным
// значением: первый вход с ним принудительно требует установить новый, а
// "слабые" PIN нельзя установить ни локально, ни командой из облака.
class PinPolicy {
  PinPolicy._();

  // Частые PIN на цифровой клавиатуре (вертикали, диагонали, "крест").
  // НЕ ИЗМЕРЕНО: небольшой список очевидных, не словарь утёкших паролей.
  static const Set<String> _commonKeypadPatterns = {
    '2580', '0852', '1357', '2468', '1590', '0951', '7410', '1478',
    '3690', '0963', '1397', '7913',
  };

  // null — PIN допустим. Иначе причина: 'format' | 'same_digits' |
  // 'sequence' | 'repeating_pair' | 'common_pattern'.
  static String? weakReason(String pin) {
    if (pin.length != SecurityLimits.pinLength ||
        int.tryParse(pin) == null ||
        pin.contains(RegExp(r'[^0-9]'))) {
      return 'format';
    }
    final d = pin.codeUnits.map((c) => c - 0x30).toList();
    if (d.every((x) => x == d[0])) return 'same_digits'; // 0000, 7777
    bool step(int delta) {
      for (var i = 1; i < d.length; i++) {
        if ((d[i] - d[i - 1] + 10) % 10 != (delta + 10) % 10) return false;
      }
      return true;
    }

    if (step(1) || step(-1)) return 'sequence'; // 1234, 4321, 0123, 7890
    // 1212, 2121, 1122, 2211
    if ((d[0] == d[2] && d[1] == d[3]) || (d[0] == d[1] && d[2] == d[3])) {
      return 'repeating_pair';
    }
    if (_commonKeypadPatterns.contains(pin)) return 'common_pattern';
    return null;
  }

  static bool isWeak(String pin) => weakReason(pin) != null;
}
