/// Данные продавца и ссылка QR — это данные АППАРАТА, а не бренда
/// (ТЗ docs/brands_tz.md, раздел 3): у каждого владельца свои. Приходят из
/// облака командой update_config и хранятся в настройках аппарата, поэтому
/// переживают обновление APK как остальные настройки.
///
/// Всё, что не прошло проверку, игнорируется (прежнее значение остаётся),
/// в журнал пишется только имя поля — без значения.
class SellerLimits {
  SellerLimits._();

  static const int qrUrlMax = 300;
  static const int phoneMax = 32;
  static const int emailMax = 80;
  static const int siteMax = 120;
  static const int legalMax = 120;
}

/// Ключи update_config.
class SellerFields {
  SellerFields._();

  static const String qrUrl = 'qr_url';
  static const String phone = 'seller_phone';
  static const String email = 'seller_email';
  static const String site = 'seller_site';
  static const String legal = 'seller_legal';

  static const List<String> all = [qrUrl, phone, email, site, legal];
}

class SellerInfo {
  SellerInfo._();

  // Управляющие символы (C0, DEL, C1), разделители строк и символы
  // двунаправленного письма (подмена порядка текста) отбрасываются.
  static final RegExp _control = RegExp(
    r'[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]',
  );
  static final RegExp _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// Убирает управляющие символы и крайние пробелы.
  static String clean(String raw) => raw.replaceAll(_control, '').trim();

  /// Только https и только с адресом хоста, без пробелов.
  static bool _isHttps(String v) {
    if (v.contains(RegExp(r'\s'))) return false;
    final u = Uri.tryParse(v);
    return u != null && u.scheme == 'https' && u.host.isNotEmpty;
  }

  /// Проверка значения поля [field] (ключ update_config).
  /// Возвращает очищенное значение ('' — поле очищено) или null, если
  /// значение не прошло проверку и должно быть проигнорировано.
  static String? sanitize(String field, Object? raw) {
    if (raw == null) return '';
    if (raw is! String) return null;
    final v = clean(raw);
    if (v.isEmpty) return '';
    switch (field) {
      case SellerFields.qrUrl:
        return v.length <= SellerLimits.qrUrlMax && _isHttps(v) ? v : null;
      case SellerFields.phone:
        return v.length <= SellerLimits.phoneMax ? v : null;
      case SellerFields.email:
        return v.length <= SellerLimits.emailMax && _email.hasMatch(v)
            ? v
            : null;
      case SellerFields.site:
        return v.length <= SellerLimits.siteMax && _isHttps(v) ? v : null;
      case SellerFields.legal:
        return v.length <= SellerLimits.legalMax ? v : null;
    }
    return null;
  }
}
