import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'config_service.dart';

// Заводская запись облачных данных (адрес облака, публичный ключ, токен, номер
// аппарата). Файл device_config.json кладётся на планшет при подготовке и
// ОСТАЁТСЯ на нём всю пуско-наладку; приложение сверяет его с запомненным при
// каждом старте (и при возврате на передний план) и при необходимости
// применяет заново. Поэтому стирание настроек приложения (pm clear,
// переустановка) лечится само. В конце наладки техник нажимает «Завершить
// пуско-наладку» — файл удаляется, и токен перестаёт лежать в общей памяти.
//
// Токен и ключ НИГДЕ не пишутся в журнал и события (AppLog.setSecrets их
// маскирует; здесь значения вообще не логируются).

// Формат файла (JSON, UTF-8):
// {"format":1,"config_id":"<строка>","device_id":"CARFOG-123",
//  "cloud_url":"https://...","anon_key":"sb_publishable_...","token":"..."}
class FactoryConfig {
  final String configId;
  final String deviceId;
  final String cloudUrl;
  final String anonKey;
  final String token;
  const FactoryConfig({
    required this.configId,
    required this.deviceId,
    required this.cloudUrl,
    required this.anonKey,
    required this.token,
  });
}

// Причина отказа разбора — короткий код БЕЗ значений полей.
enum FactoryConfigError {
  badJson,
  badFormat,
  missingField,
  badDeviceId,
  notHttps,
  tooLong,
}

class FactoryConfigParse {
  final FactoryConfig? config;
  final FactoryConfigError? error;
  const FactoryConfigParse.ok(FactoryConfig this.config) : error = null;
  const FactoryConfigParse.fail(FactoryConfigError this.error) : config = null;
  bool get ok => config != null;
}

final RegExp _deviceIdRe = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

FactoryConfigParse parseFactoryConfig(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const FactoryConfigParse.fail(FactoryConfigError.badJson);
  }
  if (decoded is! Map) return const FactoryConfigParse.fail(FactoryConfigError.badJson);
  final Map j = decoded;
  if (j['format'] != 1) return const FactoryConfigParse.fail(FactoryConfigError.badFormat);

  String? field(String k) {
    final v = j[k];
    if (v is! String) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  final configId = field('config_id');
  final deviceId = field('device_id');
  final url = field('cloud_url');
  final key = field('anon_key');
  final token = field('token');
  if (configId == null || deviceId == null || url == null || key == null || token == null) {
    return const FactoryConfigParse.fail(FactoryConfigError.missingField);
  }
  if (configId.length > 128 || url.length > 512 || key.length > 1024 || token.length > 1024) {
    return const FactoryConfigParse.fail(FactoryConfigError.tooLong);
  }
  if (!_deviceIdRe.hasMatch(deviceId)) {
    return const FactoryConfigParse.fail(FactoryConfigError.badDeviceId);
  }
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    return const FactoryConfigParse.fail(FactoryConfigError.notHttps);
  }
  // Лишние поля игнорируются.
  return FactoryConfigParse.ok(FactoryConfig(
    configId: configId,
    deviceId: deviceId,
    cloudUrl: url,
    anonKey: key,
    token: token,
  ));
}

// ---------------------------------------------------------------------------
// Доступ к файлу (скрыт за интерфейсом — тесты идут без устройства)
// ---------------------------------------------------------------------------

enum FileReadStatus { absent, ok, unreadable }

class FileReadResult {
  final FileReadStatus status;
  final String? text;
  const FileReadResult(this.status, [this.text]);
}

enum FileDeleteStatus { deleted, absent, failed }

class FileDeleteResult {
  final FileDeleteStatus status;
  final String? reason; // короткий код причины при failed
  const FileDeleteResult(this.status, [this.reason]);
}

abstract class FactoryConfigStore {
  Future<FileReadResult> read();
  Future<FileDeleteResult> delete();
}

// Общий каталог /sdcard/CarFog: НЕ закрытый каталог приложения и НЕ
// app-specific каталог внешней памяти (оба стираются при pm clear и
// переустановке). Файлы в общей памяти, созданные adb push, переживают
// pm clear и удаление приложения. Приложению нужен доступ ко всем файлам
// (MANAGE_EXTERNAL_STORAGE; уже есть в манифесте), на заводе он выдаётся:
//   adb shell appops set ee.carfog.dryfog MANAGE_EXTERNAL_STORAGE allow
// Если разрешения нет (или файл принадлежит другому пользователю и недоступен),
// чтение и удаление повторяются через root (su), как остальные привилегированные
// операции приложения.
class SharedStorageConfigStore implements FactoryConfigStore {
  static const String defaultPath = '/storage/emulated/0/CarFog/device_config.json';
  final String path;
  SharedStorageConfigStore({this.path = defaultPath});
  static const MethodChannel _channel = MethodChannel('com.carfog.dryfog/system');

  static String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

  Future<Map<dynamic, dynamic>?> _root(String cmd) async {
    try {
      return await _channel.invokeMethod<Map>('rootExec', {'command': cmd, 'timeoutMs': 8000});
    } catch (_) {
      return null;
    }
  }

  @override
  Future<FileReadResult> read() async {
    try {
      final f = File(path);
      if (await f.exists()) {
        return FileReadResult(FileReadStatus.ok, await f.readAsString());
      }
    } on FileSystemException {
      // нет прав — пробуем root ниже
    } catch (_) {}
    final r = await _root('[ -f ${_q(path)} ] && cat ${_q(path)}');
    if (r == null) {
      // su недоступен: различить «нет файла» и «нет прав» нельзя; прямой
      // доступ уже сказал, что файла не видно
      return const FileReadResult(FileReadStatus.absent);
    }
    if (r['exit'] == 0) return FileReadResult(FileReadStatus.ok, r['out'] as String? ?? '');
    return const FileReadResult(FileReadStatus.absent);
  }

  @override
  Future<FileDeleteResult> delete() async {
    String? reason;
    try {
      final f = File(path);
      if (await f.exists()) {
        await f.delete();
        if (!await f.exists()) return const FileDeleteResult(FileDeleteStatus.deleted);
        reason = 'still_exists';
      } else {
        // не видно напрямую — проверим через root (мог быть без прав на чтение)
        final r = await _root('[ -f ${_q(path)} ] && echo yes || echo no');
        if (r == null || (r['out'] as String? ?? '').trim() != 'yes') {
          return const FileDeleteResult(FileDeleteStatus.absent);
        }
      }
    } on FileSystemException catch (e) {
      reason = (e.osError?.errorCode == 13 || e.osError?.errorCode == 1) ? 'permission' : 'io';
    } catch (_) {
      reason = 'io';
    }
    final r = await _root('rm -f ${_q(path)}; [ -e ${_q(path)} ] && echo yes || echo no');
    if (r != null && (r['out'] as String? ?? '').trim().endsWith('no')) {
      return const FileDeleteResult(FileDeleteStatus.deleted);
    }
    return FileDeleteResult(FileDeleteStatus.failed, reason ?? 'no_root');
  }
}

// ---------------------------------------------------------------------------
// Правило применения
// ---------------------------------------------------------------------------

enum FactoryApplyStatus { noFile, unreadable, invalid, upToDate, applied }

class FactoryApplyResult {
  final FactoryApplyStatus status;
  final AppConfig config;
  final String? configId; // применённый (для applied) или файловый
  final FactoryConfigError? error;
  const FactoryApplyResult(this.status, this.config, {this.configId, this.error});
  bool get changed => status == FactoryApplyStatus.applied;
}

class FactoryConfigService {
  FactoryConfigService._();

  // Подменяется в тестах.
  static FactoryConfigStore store = SharedStorageConfigStore();

  // Последний применённый config_id. Хранится отдельным ключом
  // SharedPreferences, поэтому заводской сброс (ConfigService.reset стирает
  // только ключ настроек) его не трогает.
  static const String prefsKey = 'factory_config_applied_id';

  static Future<String?> appliedId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(prefsKey);
    } catch (_) {
      return null;
    }
  }

  static bool _cloudEmpty(AppConfig c) =>
      c.cloudUrl.trim().isEmpty || c.cloudAnonKey.trim().isEmpty || c.cloudToken.trim().isEmpty;

  // Сверка файла с текущими настройками. Ничего не сохраняет: сохранение — у
  // вызывающего (на старте до runApp и в работающем приложении по-разному).
  static Future<FactoryApplyResult> evaluate(AppConfig current) async {
    final FileReadResult read;
    try {
      read = await store.read();
    } catch (_) {
      return FactoryApplyResult(FactoryApplyStatus.unreadable, current);
    }
    if (read.status == FileReadStatus.absent) {
      return FactoryApplyResult(FactoryApplyStatus.noFile, current);
    }
    if (read.status == FileReadStatus.unreadable || read.text == null) {
      AppLog.log('FactoryConfig', 'файл конфигурации не читается');
      return FactoryApplyResult(FactoryApplyStatus.unreadable, current);
    }
    final parsed = parseFactoryConfig(read.text!);
    if (!parsed.ok) {
      // Только код причины, без значений полей.
      AppLog.log('FactoryConfig', 'файл конфигурации отклонён: ${parsed.error!.name}');
      return FactoryApplyResult(FactoryApplyStatus.invalid, current, error: parsed.error);
    }
    final fc = parsed.config!;
    final last = await appliedId();
    if (fc.configId == last && !_cloudEmpty(current)) {
      return FactoryApplyResult(FactoryApplyStatus.upToDate, current, configId: fc.configId);
    }
    // Применить: ТОЛЬКО облачные поля, остальные настройки не трогаем.
    final updated = current.copyWith(
      deviceId: fc.deviceId,
      cloudUrl: fc.cloudUrl,
      cloudAnonKey: fc.anonKey,
      cloudToken: fc.token,
      cloudEnabled: true,
    );
    return FactoryApplyResult(FactoryApplyStatus.applied, updated, configId: fc.configId);
  }

  static Future<void> _rememberId(String id) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(prefsKey, id);
    } catch (_) {}
  }

  // Старт приложения (до runApp): возвращает настройки с применённым файлом.
  static Future<AppConfig> applyOnStartup(AppConfig current) async {
    final r = await evaluate(current);
    if (!r.changed) return current;
    // Секреты — в маску ДО любой записи в журнал.
    AppLog.setSecrets([r.config.servicePin, r.config.cloudToken, r.config.cloudAnonKey]);
    await ConfigService.save(r.config);
    await _rememberId(r.configId!);
    AppLog.log('FactoryConfig', 'применена заводская конфигурация config_id=${r.configId}');
    return r.config;
  }

  // Работающее приложение (возврат на передний план): применяет и
  // переконфигурирует облако.
  static Future<FactoryApplyStatus> applyIfNeeded(AppNotifier n) async {
    final r = await evaluate(n.config);
    if (!r.changed) return r.status;
    AppLog.setSecrets([r.config.servicePin, r.config.cloudToken, r.config.cloudAnonKey]);
    await n.saveConfig(r.config);
    await _rememberId(r.configId!);
    CloudService.configure(
      deviceId: r.config.deviceId,
      enabled: r.config.cloudEnabled,
      url: r.config.cloudUrl,
      anonKey: r.config.cloudAnonKey,
      token: r.config.cloudToken,
    );
    AppLog.log('FactoryConfig', 'применена заводская конфигурация config_id=${r.configId}');
    return r.status;
  }

  // «Завершить пуско-наладку»: удалить файл с общего каталога.
  static Future<FileDeleteResult> finishCommissioning() async {
    try {
      final r = await store.delete();
      AppLog.log('FactoryConfig', 'завершение пуско-наладки: ${r.status.name}${r.reason == null ? '' : ' (${r.reason})'}');
      return r;
    } catch (e) {
      return const FileDeleteResult(FileDeleteStatus.failed, 'io');
    }
  }

  // Состояние для экрана: без значений токена и ключа.
  static Future<({bool cloudConfigured, String deviceId, String? configId})> summary(AppConfig c) async {
    return (
      cloudConfigured: !_cloudEmpty(c) && c.cloudEnabled,
      deviceId: c.deviceId,
      configId: await appliedId(),
    );
  }
}
