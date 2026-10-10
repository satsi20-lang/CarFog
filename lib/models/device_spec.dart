import 'hardware_profile.dart';

// Спецификация аппарата: число насосов (= число ароматов) и набор языков.
// Контракт единый для базы (миграция R5), генератора (tool/provision_devices.py),
// заводского файла (ключ "spec") и приложения. В этой части спецификация только
// ХРАНИТСЯ и читается; экраны и карта каналов её пока не используют.
class DeviceSpec {
  final int pumps;
  final List<String> langs;
  final String defaultLang;
  final String hardwareProfile;

  const DeviceSpec({
    this.pumps = defaultPumps,
    this.langs = defaultLangs,
    this.defaultLang = 'et',
    this.hardwareProfile = HardwareProfile.id,
  });

  static const int minPumps = 4;
  // Решение владельца 10.10.2026: пока максимум 8 насосов (в базе check остаётся
  // 4…10; верхняя граница 8 держится в приложении, генераторе и панели).
  static const int maxPumps = 8;
  static const int defaultPumps = 4;
  static const int maxLangs = 24;
  static const List<String> defaultLangs = ['et', 'en', 'ru'];

  // Каталог допустимых кодов (нижний регистр).
  static const List<String> catalog = [
    'bg',
    'cs',
    'da',
    'de',
    'el',
    'en',
    'es',
    'et',
    'fi',
    'fr',
    'ga',
    'hr',
    'hu',
    'it',
    'lt',
    'lv',
    'mt',
    'nl',
    'pl',
    'pt',
    'ro',
    'ru',
    'sk',
    'sl',
    'sv',
    'uk',
    'no',
  ];

  // Языки, для которых в приложении есть перевод (остальные из spec
  // сохраняются, но пока не показываются).
  static const List<String> implemented = ['et', 'en', 'ru'];

  // Запасной язык, если пересечение langs и implemented пусто.
  static const String fallbackLang = 'en';

  // Число активных насосов/ароматов из значения specPumps: при любой ошибке
  // (не целое, вне 4…8) — значение по умолчанию 4.
  static int activeFor(Object? pumps) =>
      pumps is int && pumps >= minPumps && pumps <= maxPumps ? pumps : defaultPumps;

  // Проверка по контракту; null — всё верно, иначе короткий код причины.
  static String? validate({
    required Object? pumps,
    required Object? langs,
    required Object? defaultLang,
  }) {
    if (pumps is! int || pumps < minPumps || pumps > maxPumps) return 'pumps';
    if (langs is! List || langs.isEmpty || langs.length > maxLangs) {
      return 'langs';
    }
    final seen = <String>{};
    for (final l in langs) {
      if (l is! String || !catalog.contains(l) || !seen.add(l)) return 'langs';
    }
    if (defaultLang is! String || !langs.contains(defaultLang)) {
      return 'default_lang';
    }
    return null;
  }

  // Разбор JSON-объекта spec (файл, облако). null — неверно. Недостающие
  // поля берутся по умолчанию (pumps 4, langs et/en/ru, default — первый).
  static DeviceSpec? tryParse(Object? json) {
    if (json is! Map) return null;
    final pumps = json.containsKey('pumps') ? json['pumps'] : defaultPumps;
    final langs = json.containsKey('langs') ? json['langs'] : defaultLangs;
    final def = json.containsKey('default_lang')
        ? json['default_lang']
        : (langs is List && langs.isNotEmpty ? langs.first : null);
    if (validate(pumps: pumps, langs: langs, defaultLang: def) != null) {
      return null;
    }
    final prof = json['hardware_profile'];
    return DeviceSpec(
      pumps: pumps as int,
      langs: List<String>.unmodifiable((langs as List).cast<String>()),
      defaultLang: def as String,
      hardwareProfile:
          prof is String && prof.trim().isNotEmpty && prof.length <= 64
          ? prof
          : HardwareProfile.id,
    );
  }

  Map<String, dynamic> toJson() => {
    'pumps': pumps,
    'langs': langs,
    'default_lang': defaultLang,
    'hardware_profile': hardwareProfile,
  };

  // Языки, которые можно показать: пересечение langs и implemented в порядке
  // langs; пусто → [en].
  List<String> get displayLangs {
    final shown = langs.where(implemented.contains).toList();
    return shown.isEmpty ? const [fallbackLang] : shown;
  }

  // Коды из spec без перевода (для одной строки-предупреждения в журнал).
  List<String> get unsupportedLangs =>
      langs.where((l) => !implemented.contains(l)).toList();

  // Язык по умолчанию для показа: defaultLang, если он показываем, иначе
  // первый показываемый.
  String get displayDefaultLang =>
      displayLangs.contains(defaultLang) ? defaultLang : displayLangs.first;

  @override
  bool operator ==(Object other) =>
      other is DeviceSpec &&
      other.pumps == pumps &&
      other.defaultLang == defaultLang &&
      other.hardwareProfile == hardwareProfile &&
      other.langs.length == langs.length &&
      Iterable<int>.generate(
        langs.length,
      ).every((i) => other.langs[i] == langs[i]);

  @override
  int get hashCode =>
      Object.hash(pumps, defaultLang, hardwareProfile, Object.hashAll(langs));
}
