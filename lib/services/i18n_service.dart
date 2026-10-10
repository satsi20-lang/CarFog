import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'app_log_service.dart';

// Переводы клиентских экранов (часть 3a спецификации аппарата). Тексты лежат
// в assets/i18n/<код>.json (плоский словарь «ключ → строка», ключ с префиксом
// экрана), список языков с родными названиями и статусом — в
// assets/i18n/manifest.json. Подробно — docs/i18n.md.
//
// Правила:
//   * запасная цепочка СТРОГО: запрошенный язык → en → сам ключ;
//   * ни отсутствующий ключ, ни повреждённый файл не дают исключения —
//     экран всегда показывает какой-то текст;
//   * на боевом аппарате показываются только языки со статусом released и
//     загруженным файлом; draft — только при включённом в сервисном меню
//     тумблере «показывать черновые переводы» (не сохраняется).
//
// Служебные экраны техника (service_menu, service_pin, bus_port_section) сюда
// не относятся: их тексты остаются таблицами в коде на ru/en/et.

// Строка manifest.json об одном языке.
class LangInfo {
  final String code;
  final String name;
  final String status;
  final int version;

  const LangInfo({
    required this.code,
    required this.name,
    required this.status,
    required this.version,
  });

  static const String released = 'released';
  static const String draft = 'draft';

  bool get isReleased => status == released;
}

class I18n {
  I18n._();

  static const String fallbackLang = 'en';
  static const String assetDir = 'assets/i18n';
  static const String manifestAsset = '$assetDir/manifest.json';

  // Порядок кодов — порядок в manifest.
  static Map<String, LangInfo> _manifest = {};
  static Map<String, Map<String, String>> _dicts = {};
  static bool _showDrafts = false;

  // Ключи, которых нет даже в en (показан сам ключ). В отладке и тестах это
  // ошибка: тесты проверяют, что множество пусто.
  static final Set<String> missingKeys = {};

  // Загрузка при старте (до runApp). Любая ошибка — строка в журнал и
  // продолжение без этого файла.
  static Future<void> load({AssetBundle? bundle}) async {
    final b = bundle ?? rootBundle;
    String? manifest;
    try {
      manifest = await b.loadString(manifestAsset, cache: false);
    } catch (e) {
      AppLog.log('I18n', 'manifest.json не прочитан: $e');
    }
    final codes = _parseManifest(manifest).keys;
    final files = <String, String?>{};
    for (final code in codes) {
      try {
        files[code] = await b.loadString('$assetDir/$code.json', cache: false);
      } catch (_) {
        // Файла нет (язык ещё не переведён) — штатно для draft.
        files[code] = null;
      }
    }
    loadFromStrings(manifest: manifest, files: files);
  }

  // Разбор уже прочитанного содержимого (отдельно — для тестов). Повреждённые
  // части отбрасываются, остальное работает.
  static void loadFromStrings({
    required String? manifest,
    required Map<String, String?> files,
  }) {
    _manifest = _parseManifest(manifest);
    final dicts = <String, Map<String, String>>{};
    for (final e in files.entries) {
      final raw = e.value;
      if (raw == null) continue;
      final dict = _parseDict(e.key, raw);
      if (dict != null && dict.isNotEmpty) dicts[e.key] = dict;
    }
    _dicts = dicts;
    missingKeys.clear();
    final noFile = _manifest.values
        .where((l) => l.isReleased && !_dicts.containsKey(l.code))
        .map((l) => l.code)
        .toList();
    if (noFile.isNotEmpty) {
      AppLog.log(
        'I18n',
        'released без файла перевода, не показываются: ${noFile.join(',')}',
      );
    }
  }

  static Map<String, LangInfo> _parseManifest(String? raw) {
    if (raw == null) return {};
    try {
      final j = jsonDecode(raw);
      final langs = j is Map ? j['languages'] : null;
      if (langs is! Map) {
        AppLog.log('I18n', 'manifest.json: нет объекта languages');
        return {};
      }
      final out = <String, LangInfo>{};
      for (final e in langs.entries) {
        final code = e.key;
        final v = e.value;
        if (code is! String || v is! Map) continue;
        final name = v['name'];
        final status = v['status'];
        final version = v['version'];
        out[code] = LangInfo(
          code: code,
          name: name is String && name.trim().isNotEmpty
              ? name
              : code.toUpperCase(),
          status: status == LangInfo.released
              ? LangInfo.released
              : LangInfo.draft,
          version: version is int ? version : 0,
        );
      }
      return out;
    } catch (e) {
      AppLog.log('I18n', 'manifest.json повреждён: $e');
      return {};
    }
  }

  static Map<String, String>? _parseDict(String code, String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map) {
        AppLog.log('I18n', '$code.json: не словарь, пропущен');
        return null;
      }
      final out = <String, String>{};
      for (final e in j.entries) {
        if (e.key is String && e.value is String) {
          out[e.key as String] = e.value as String;
        }
      }
      return out;
    } catch (e) {
      AppLog.log('I18n', '$code.json повреждён, пропущен: $e');
      return null;
    }
  }

  // Черновые переводы на экране (проверка носителем языка на аппарате).
  // Только в памяти: после перезапуска снова выключено.
  static bool get showDrafts => _showDrafts;
  static set showDrafts(bool value) {
    if (_showDrafts == value) return;
    _showDrafts = value;
    AppLog.log('I18n', 'показ черновых переводов: ${value ? 'вкл' : 'выкл'}');
  }

  // Языки, которые можно показать клиенту, в порядке manifest: released с
  // файлом, а при включённом тумблере — и draft с файлом.
  static List<String> get availableLangs => [
    for (final l in _manifest.values)
      if (_dicts.containsKey(l.code) && (l.isReleased || _showDrafts)) l.code,
  ];

  static List<String> get releasedLangs => [
    for (final l in _manifest.values)
      if (l.isReleased && _dicts.containsKey(l.code)) l.code,
  ];

  static List<String> get manifestLangs => _manifest.keys.toList();

  static LangInfo? info(String code) => _manifest[code];

  static bool hasFile(String code) => _dicts.containsKey(code);

  // Ключи файла языка (для проверок); пусто, если файла нет.
  static Map<String, String> dictOf(String code) =>
      Map.unmodifiable(_dicts[code] ?? const {});

  // Родное название языка для кнопок; без строки в manifest — код.
  static String nativeName(String code) =>
      _manifest[code]?.name ?? code.toUpperCase();

  // Строка по ключу: язык → en → ключ. Пустая строка считается отсутствующей.
  // Параметры {имя} подставляются; неизвестные остаются как есть.
  static String tr(
    String lang,
    String key, {
    Map<String, Object?> params = const {},
  }) {
    var s = _dicts[lang]?[key];
    if (s == null || s.isEmpty) s = _dicts[fallbackLang]?[key];
    if (s == null || s.isEmpty) {
      if (missingKeys.add(key)) {
        debugPrint('I18n: нет ключа "$key" ни в $lang, ни в en');
      }
      return key;
    }
    if (params.isEmpty) return s;
    return s.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) {
      final name = m.group(1)!;
      return params.containsKey(name) ? '${params[name]}' : m.group(0)!;
    });
  }

  // Имена параметров {…} в строке (для проверки переводов).
  static Set<String> paramsOf(String s) =>
      RegExp(r'\{(\w+)\}').allMatches(s).map((m) => m.group(1)!).toSet();

  @visibleForTesting
  static void reset() {
    _manifest = {};
    _dicts = {};
    _showDrafts = false;
    missingKeys.clear();
  }
}
