import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/remote_limits.dart';

// Постоянный кольцевой журнал приложения (удалённая диагностика, R1).
//
// Раньше около 80 вызовов debugPrint уходили только в logcat и пропадали
// при перезапуске: после обрыва adb (а Android отключает отладку по Wi-Fi
// после перезагрузки) разбираться было не с чем. Теперь debugPrint и ошибки
// Flutter/Dart пишутся в файл в каталоге приложения.
//
// Устройство:
//  * два файла (app_log.txt — текущий, app_log.1.txt — предыдущий), ротация
//    по размеру AppLogLimits.maxFileBytes: старое переезжает в .1 и
//    затирает предыдущий .1;
//  * log() только кладёт строку в память — запись идёт асинхронно пачкой
//    раз в AppLogLimits.flushInterval (File.writeAsString асинхронный и
//    вне потока шины/UI; шина Modbus работает в нативных потоках и с
//    журналом не пересекается);
//  * секреты (PIN, токены, ключи) вырезаются в redact() ДО записи, как по
//    шаблонам, так и по точным значениям из настроек (setSecrets);
//  * файл нового запуска начинается с отметки: причина запуска (crash /
//    boot / normal) и версия приложения.
class AppLog {
  AppLog._();

  static const String fileName = 'app_log.txt';
  static const String prevFileName = 'app_log.1.txt';

  static Directory? _dir;
  static final List<String> _pending = [];
  static Timer? _timer;
  static bool _flushing = false;
  static Set<String> _secrets = {};
  static String? _startReason;
  static String? _version;

  static String? get startReason => _startReason;
  static bool get isReady => _dir != null;

  // Открыть журнал и записать отметку запуска. Вызывается один раз из
  // main() до runApp (и из тестов с временным каталогом).
  static Future<void> init({
    required Directory dir,
    required String reason,
    required String version,
  }) async {
    _dir = dir;
    _startReason = reason;
    _version = version;
    try {
      await dir.create(recursive: true);
    } catch (_) {}
    log(
      'log',
      '=== START reason=$reason version=$version '
      'at=${DateTime.now().toIso8601String()} ===',
    );
    await flush();
  }

  // Перехват debugPrint и ошибок Flutter/Dart. Оригинальное поведение
  // (вывод в logcat, красный экран в отладке) сохраняется.
  static void install() {
    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) log(_tagOf(message), message);
      originalPrint(message, wrapWidth: wrapWidth);
    };

    final originalFlutterError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      log(
        'FlutterError',
        '${details.exceptionAsString()}\n${_stackHead(details.stack)}',
      );
      if (originalFlutterError != null) {
        originalFlutterError(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    final originalDispatcherError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      log('UncaughtError', '$error\n${_stackHead(stack)}');
      // false — не помечать ошибку обработанной: поведение как до журнала.
      return originalDispatcherError?.call(error, stack) ?? false;
    };
  }

  // "SyncService: опрос..." → метка SyncService; иначе 'app'.
  static String _tagOf(String message) {
    final i = message.indexOf(':');
    if (i > 0 && i <= 40 && !message.substring(0, i).contains(' ')) {
      return message.substring(0, i);
    }
    return 'app';
  }

  static String _stackHead(StackTrace? s) {
    if (s == null) return '';
    return s.toString().split('\n').take(20).join('\n');
  }

  // Точные значения секретов из настроек (PIN, токен облака, ключ).
  // Короче 3 символов не маскируются (иначе вырезались бы случайные цифры).
  static void setSecrets(Iterable<String?> values) {
    _secrets = values
        .whereType<String>()
        .map((v) => v.trim())
        .where((v) => v.length >= 3)
        .toSet();
  }

  static final RegExp _kv = RegExp(
    r'''("?(?:pin|service_?pin|token|cloud_?token|p_token|anon_?key|cloud_?anon_?key|apikey|authorization|password|secret)"?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,}\]]+)''',
    caseSensitive: false,
  );
  static final RegExp _jwt = RegExp(
    r'eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]*',
  );
  static final RegExp _bearer = RegExp(r'Bearer\s+[A-Za-z0-9._\-]+');

  // Вырезает секреты из произвольного текста (журнал, значения пакета).
  // Подстановка '***' БЕЗ кавычек: результат безопасен внутри уже
  // заквоченной строки. Порядок важен: сначала Bearer и JWT (иначе
  // "Authorization: Bearer xxx" съело бы только слово Bearer).
  static String redact(String text) {
    var out = text
        .replaceAll(_bearer, 'Bearer ***')
        .replaceAll(_jwt, '***')
        .replaceAllMapped(_kv, (m) => '${m[1]}***');
    for (final secret in _secrets) {
      out = out.replaceAll(secret, '***');
    }
    return out;
  }

  // Рекурсивно вырезает секреты из ЗНАЧЕНИЙ-строк дерева Map/List. Нельзя
  // чистить готовый JSON-текст: подстановка внутри уже заквоченной строки
  // сломала бы его (поймано тестом пакета диагностики).
  static Object? redactTree(Object? node) {
    if (node is String) return redact(node);
    if (node is Map) {
      return node.map((k, v) => MapEntry(k, redactTree(v)));
    }
    if (node is List) return node.map(redactTree).toList();
    return node;
  }

  // Добавить строку (не блокирует, не пишет на диск сама).
  static void log(String tag, String message) {
    final now = DateTime.now().toIso8601String();
    final safe = redact(message);
    for (final raw in safe.split('\n')) {
      var line = raw;
      if (line.length > AppLogLimits.maxLineChars) {
        line = '${line.substring(0, AppLogLimits.maxLineChars)}…';
      }
      _pending.add('$now [$tag] $line');
    }
    // Предохранитель памяти: при зависшей записи старые строки теряются.
    final extra = _pending.length - AppLogLimits.maxPendingLines;
    if (extra > 0) _pending.removeRange(0, extra);
    _timer ??= Timer(AppLogLimits.flushInterval, () {
      _timer = null;
      unawaited(flush());
    });
  }

  // Сбросить накопленное на диск (с ротацией). Безопасно вызывать часто.
  static Future<void> flush() async {
    final dir = _dir;
    if (dir == null || _pending.isEmpty || _flushing) return;
    _flushing = true;
    final batch = List<String>.from(_pending);
    _pending.clear();
    try {
      final file = File('${dir.path}/$fileName');
      if (await file.exists() &&
          await file.length() >= AppLogLimits.maxFileBytes) {
        final prev = File('${dir.path}/$prevFileName');
        if (await prev.exists()) await prev.delete();
        await file.rename(prev.path);
      }
      await File('${dir.path}/$fileName').writeAsString(
        '${batch.join('\n')}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (e) {
      // Диск недоступен: строки возвращаются в начало очереди (в пределах
      // предохранителя), журнал не должен ронять приложение.
      _pending.insertAll(0, batch);
      final extra = _pending.length - AppLogLimits.maxPendingLines;
      if (extra > 0) _pending.removeRange(0, extra);
    } finally {
      _flushing = false;
    }
  }

  // Последние n строк (сначала предыдущий файл, затем текущий).
  static Future<List<String>> tail(int n) async {
    final dir = _dir;
    if (dir == null) return const [];
    await flush();
    final lines = <String>[];
    for (final name in [prevFileName, fileName]) {
      try {
        final f = File('${dir.path}/$name');
        if (await f.exists()) {
          lines.addAll((await f.readAsString()).split('\n')..removeWhere((l) => l.isEmpty));
        }
      } catch (_) {}
    }
    return lines.length <= n ? lines : lines.sublist(lines.length - n);
  }

  // Только для тестов: сбросить состояние.
  @visibleForTesting
  static void resetForTest() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _dir = null;
    _secrets = {};
    _startReason = null;
    _version = null;
    _flushing = false;
  }

  static String? get version => _version;
}
