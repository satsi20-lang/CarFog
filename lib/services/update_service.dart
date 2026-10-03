import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../models/update_limits.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'heater_shutdown_service.dart';
import 'modbus_service.dart';
import 'privileged_installer.dart';
import 'sync_service.dart';
import 'update_script.dart';

class UpdateResult {
  final bool ok;
  final String result;
  // Запуск установочного скрипта — ПОСЛЕ отправки ack: pm install убьёт
  // процесс приложения через секунды, и ответ на команду не ушёл бы.
  final Future<void> Function()? afterAck;
  const UpdateResult(this.ok, this.result, {this.afterAck});
}

// Запись релиза с сервера (из Edge Function release-url).
class ReleaseTicket {
  final Uri url;
  final String sha256;
  final int sizeBytes;
  final int versionCode;
  final String versionName;
  const ReleaseTicket({
    required this.url,
    required this.sha256,
    required this.sizeBytes,
    required this.versionCode,
    required this.versionName,
  });
}

// Сведения об APK, прочитанные из самого файла (PackageManager).
class ApkInfo {
  final String? packageName;
  final int? versionCode;
  final String? versionName;
  final bool signatureMatches;
  const ApkInfo({
    this.packageName,
    this.versionCode,
    this.versionName,
    this.signatureMatches = false,
  });
}

class AppInfo {
  final String packageName;
  final int versionCode;
  final String versionName;
  const AppInfo(this.packageName, this.versionCode, this.versionName);
}

class DownloadException implements Exception {
  final String code;
  const DownloadException(this.code);
  @override
  String toString() => 'DownloadException($code)';
}

// Условие сигнала здоровья новой версии (чистая функция — проверяется
// тестами): шина читается, аппарат в покое и (если облако включено) один
// опрос облака прошёл после запуска.
class HealthGate {
  HealthGate._();

  static bool ready({
    required bool busHealthy,
    required bool idle,
    required bool cloudEnabled,
    required bool cloudPolled,
  }) => busHealthy && idle && (!cloudEnabled || cloudPolled);
}

// Удалённое обновление приложения (R2): скачивание, проверка, запуск
// корневого скрипта установки, наблюдение за результатом, откат.
//
// Доверие к сборке держится на трёх вещах, не на одной: SHA-256 и размер из
// записи релиза на сервере (канал с проверкой токена), подпись (совпадение с
// установленным приложением, проверяется до установки) и versionCode строго
// больше текущего. Откат на более старую сборку — только командой rollback_app,
// не через update_app.
class UpdateService {
  UpdateService._();

  static const _channel = MethodChannel('com.carfog.dryfog/system');

  // Идёт обновление/откат: оплата заблокирована (без записи в постоянный
  // признак вывода из обслуживания). Снимается при неудаче или после
  // результата; при успехе процесс всё равно будет заменён.
  static bool inProgress = false;

  // ---- подменяемые в тестах зависимости ----
  static PrivilegedInstaller installer = RootInstaller();
  static Future<Directory?> Function() dirProvider = _defaultDir;
  static Future<ReleaseTicket> Function(AppConfig cfg, String releaseId) ticketFetcher =
      _fetchTicket;
  static Future<void> Function(Uri url, File dest, int maxBytes) downloader = _download;
  static Future<ApkInfo?> Function(String path) apkVerifier = _nativeVerify;
  static Future<AppInfo?> Function() appInfoProvider = _nativeAppInfo;
  static Future<int?> Function() diskFreeProvider = _nativeDiskFree;
  static String mainActivity = 'com.example.dry_fog_app.MainActivity';
  static String aliasClass = 'com.example.dry_fog_app.KioskHomeAlias';

  static Timer? _watchTimer;

  // «ADB по сети» (persist.adb.tcp.port == 5555): читается при старте и после
  // переключения тумблера; в отчёт идёт закэшированное значение — su на
  // каждый опрос облака не дёргается. null — не определено (нет root).
  static bool? adbNetwork;

  static Future<void> refreshAdbNetwork() async {
    adbNetwork = await installer.readAdbNetwork();
  }

  static Future<bool> setAdbNetwork(bool enabled) async {
    final ok = await installer.setAdbNetwork(enabled);
    if (ok) {
      adbNetwork = enabled;
      await CloudService.report(
        CloudEventType.debugModeChanged,
        data: {'code': 'adb_network', 'enabled': enabled},
      );
    }
    return ok;
  }

  // ============================================================ update_app

  static Future<UpdateResult> startUpdate(AppNotifier n, String releaseId) async {
    if (inProgress) return const UpdateResult(false, 'update_in_progress');
    inProgress = true;
    n.setMaintenance(true);
    final dir = await dirProvider();
    try {
      if (dir == null) return _fail(n, 'no_storage');
      await dir.create(recursive: true);

      // 1. привилегии
      if (!await installer.isAvailable(UpdateLimits.rootCheckTimeout)) {
        return _fail(n, 'no_root');
      }

      // 2. выходы выключены и ТЭН подтверждённо выключен
      await ModbusService.safeAllOff();
      if (!await HeaterShutdownService.ensureOff('update_app', notifier: n)) {
        return _fail(n, 'heater_off_unconfirmed');
      }

      // 3. запись релиза и подписанная ссылка
      ReleaseTicket ticket;
      try {
        ticket = await ticketFetcher(n.config, releaseId);
      } on DownloadException catch (e) {
        return _fail(n, 'url_failed:${e.code}');
      }
      if (ticket.sizeBytes <= 0 || ticket.sizeBytes > UpdateLimits.maxApkBytes) {
        return _fail(n, 'bad_release');
      }

      // 4. место на диске: не меньше 3 размеров APK
      final free = await diskFreeProvider();
      if (free == null || free < ticket.sizeBytes * UpdateLimits.diskSpaceFactor) {
        return _fail(n, 'no_space');
      }

      final current = await appInfoProvider();
      if (current == null) return _fail(n, 'no_app_info');
      if (ticket.versionCode <= current.versionCode) {
        return _fail(n, 'not_newer');
      }

      await _event(CloudEventType.updateStarted, {
        'action': 'update',
        'from_version': current.versionName,
        'from_code': current.versionCode,
        'to_version': ticket.versionName,
        'to_code': ticket.versionCode,
        'size_bytes': ticket.sizeBytes,
      });

      // 5. скачивание
      final part = File('${dir.path}/${UpdateLimits.partialApkName}');
      final apk = File('${dir.path}/${UpdateLimits.newApkName}');
      await _deleteQuietly(part);
      await _deleteQuietly(apk);
      try {
        await downloader(ticket.url, part, ticket.sizeBytes);
      } catch (e) {
        await _deleteQuietly(part);
        AppLog.log('UpdateService', 'download_failed: ${e is DownloadException ? e.code : e.runtimeType}');
        return _fail(n, 'download_failed');
      }

      // 6. проверка файла: размер, SHA-256, пакет, versionCode, подпись
      final bad = await _verify(part, ticket, current);
      if (bad != null) {
        await _deleteQuietly(part);
        return _fail(n, bad);
      }
      await part.rename(apk.path);

      // Всё проверено. Запуск скрипта — после ack (см. UpdateResult).
      return UpdateResult(
        true,
        'update_started',
        afterAck: () => _launchInstall(n, dir, current, ticket, apk, releaseId),
      );
    } catch (e) {
      AppLog.log('UpdateService', 'startUpdate error: ${e.runtimeType}');
      return _fail(n, 'internal');
    }
  }

  // ========================================================== rollback_app

  static Future<bool> rollbackAvailable() async {
    final dir = await dirProvider();
    if (dir == null) return false;
    return File('${dir.path}/${UpdateLimits.backupApkName}').existsSync() &&
        File('${dir.path}/${UpdateLimits.backupInfoName}').existsSync();
  }

  static Future<UpdateResult> startRollback(AppNotifier n) async {
    if (inProgress) return const UpdateResult(false, 'update_in_progress');
    inProgress = true;
    n.setMaintenance(true);
    final dir = await dirProvider();
    try {
      if (dir == null) return _fail(n, 'no_storage', action: 'rollback');
      if (!await rollbackAvailable()) {
        return _fail(n, 'no_backup', action: 'rollback');
      }
      if (!await installer.isAvailable(UpdateLimits.rootCheckTimeout)) {
        return _fail(n, 'no_root', action: 'rollback');
      }
      await ModbusService.safeAllOff();
      if (!await HeaterShutdownService.ensureOff('rollback_app', notifier: n)) {
        return _fail(n, 'heater_off_unconfirmed', action: 'rollback');
      }
      final current = await appInfoProvider();
      if (current == null) return _fail(n, 'no_app_info', action: 'rollback');
      final backup = jsonDecode(
        await File('${dir.path}/${UpdateLimits.backupInfoName}').readAsString(),
      ) as Map<String, dynamic>;
      final toCode = (backup['version_code'] as num).toInt();
      await _event(CloudEventType.updateStarted, {
        'action': 'rollback',
        'from_version': current.versionName,
        'from_code': current.versionCode,
        'to_version': backup['version_name'],
        'to_code': toCode,
      });
      return UpdateResult(
        true,
        'rollback_started',
        afterAck: () => _launchRollback(n, dir, current, backup, toCode),
      );
    } catch (e) {
      AppLog.log('UpdateService', 'startRollback error: ${e.runtimeType}');
      return _fail(n, 'internal', action: 'rollback');
    }
  }

  // Запись об обновлении (для старта новой версии) и запуск скрипта —
  // после отправки ack.
  static Future<void> _launchInstall(
    AppNotifier n,
    Directory dir,
    AppInfo current,
    ReleaseTicket ticket,
    File apk,
    String releaseId,
  ) async {
    await _writeJson(dir, UpdateLimits.backupInfoName, {
      'version_code': current.versionCode,
      'version_name': current.versionName,
    });
    await _writeJson(dir, UpdateLimits.pendingName, {
      'mode': 'install',
      'from_code': current.versionCode,
      'from_name': current.versionName,
      'to_code': ticket.versionCode,
      'to_name': ticket.versionName,
      'release_id': releaseId,
      'started_at': DateTime.now().toIso8601String(),
    });
    await _deleteQuietly(File('${dir.path}/${UpdateLimits.protocolName}'));
    final started = await installer.startScript(
      _request(dir, current, 'install', apk.path, ticket.versionCode, n.config.kioskModeEnabled),
      updateScriptText,
    );
    if (!started) {
      await _deleteQuietly(File('${dir.path}/${UpdateLimits.pendingName}'));
      await _deleteQuietly(apk);
      await _fail(n, 'install_start_failed');
      return;
    }
    _watchProtocol(n, dir);
  }

  static Future<void> _launchRollback(
    AppNotifier n,
    Directory dir,
    AppInfo current,
    Map<String, dynamic> backup,
    int toCode,
  ) async {
    await _writeJson(dir, UpdateLimits.pendingName, {
      'mode': 'rollback',
      'from_code': current.versionCode,
      'from_name': current.versionName,
      'to_code': toCode,
      'to_name': backup['version_name'],
      'started_at': DateTime.now().toIso8601String(),
    });
    await _deleteQuietly(File('${dir.path}/${UpdateLimits.protocolName}'));
    final started = await installer.startScript(
      _request(dir, current, 'rollback', '', toCode, n.config.kioskModeEnabled),
      updateScriptText,
    );
    if (!started) {
      await _deleteQuietly(File('${dir.path}/${UpdateLimits.pendingName}'));
      await _fail(n, 'install_start_failed', action: 'rollback');
      return;
    }
    _watchProtocol(n, dir);
  }

  // ============================================================ при старте

  // Вызывается при запуске приложения: если шло обновление/откат — доводит
  // дело до конца (сигнал здоровья, события, запись результата).
  static Future<void> onStartup(AppNotifier n) async {
    final dir = await dirProvider();
    if (dir == null) return;
    final pendingFile = File('${dir.path}/${UpdateLimits.pendingName}');
    if (!pendingFile.existsSync()) return;
    Map<String, dynamic> pending;
    try {
      pending = jsonDecode(await pendingFile.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      await _deleteQuietly(pendingFile);
      return;
    }
    final current = await appInfoProvider();
    if (current == null) return;
    final toCode = (pending['to_code'] as num).toInt();
    final fromCode = (pending['from_code'] as num).toInt();
    final mode = pending['mode'] as String? ?? 'install';
    final startedAt = DateTime.tryParse(pending['started_at'] as String? ?? '');
    final summary = await _readProtocol(dir);

    if (current.versionCode == toCode) {
      // Работает НОВАЯ версия (после установки или ручного отката): ждём
      // условий здоровья и подтверждаем скрипту.
      AppLog.log('UpdateService', 'запущена целевая версия ${current.versionName}($toCode), mode=$mode');
      _healthLoop(n, dir, pending, current, summary, startedAt);
      return;
    }
    if (current.versionCode == fromCode) {
      // Работает ПРЕЖНЯЯ версия: установка не удалась или откат сработал.
      final age = startedAt == null ? Duration.zero : DateTime.now().difference(startedAt);
      if (summary.outcome == UpdateOutcome.inProgress &&
          age < UpdateLimits.protocolWatchMax) {
        // скрипт ещё может работать — продолжаем наблюдать
        inProgress = true;
        n.setMaintenance(true);
        _watchProtocol(n, dir);
        return;
      }
      await _finishWithoutInstall(n, dir, pending, current, summary);
      return;
    }
    // Версия ни целевая, ни прежняя — запись устарела.
    await _record('stale_pending', current.versionName, pending['to_name'] as String?);
    await _deleteQuietly(pendingFile);
  }

  // ============================================================== состояние

  static Future<Map<String, dynamic>> status() async {
    final info = await appInfoProvider();
    final dir = await dirProvider();
    Map<String, dynamic>? backup;
    if (dir != null && await rollbackAvailable()) {
      try {
        backup = jsonDecode(
          await File('${dir.path}/${UpdateLimits.backupInfoName}').readAsString(),
        ) as Map<String, dynamic>;
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    Map<String, dynamic>? last;
    final raw = prefs.getString(_kLast);
    if (raw != null) {
      try {
        last = jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {}
    }
    return {
      'version_name': info?.versionName,
      'version_code': info?.versionCode,
      'backup_name': backup?['version_name'],
      'backup_code': backup?['version_code'],
      'rollback_available': backup != null,
      'last': last,
    };
  }

  // ============================================================== внутреннее

  static const _kLast = 'update_last_result';

  static InstallRequest _request(
    Directory dir,
    AppInfo current,
    String mode,
    String apkPath,
    int targetCode,
    bool kiosk,
  ) => InstallRequest(
    mode: mode,
    packageName: current.packageName,
    scriptPath: '${dir.path}/${UpdateLimits.scriptName}',
    apkPath: apkPath,
    backupPath: '${dir.path}/${UpdateLimits.backupApkName}',
    targetVersionCode: targetCode,
    healthPath: '${dir.path}/${UpdateLimits.healthName}',
    logPath: '${dir.path}/${UpdateLimits.protocolName}',
    aliasClass: aliasClass,
    mainActivity: mainActivity,
    kioskEnabled: kiosk,
    healthTimeoutS: UpdateLimits.healthTimeout.inSeconds,
  );

  static Future<UpdateResult> _fail(
    AppNotifier n,
    String reason, {
    String action = 'update',
  }) async {
    inProgress = false;
    n.setMaintenance(false);
    await _event(CloudEventType.updateFailed, {'action': action, 'reason': reason});
    await _record(reason, null, null, failed: true);
    return UpdateResult(false, reason);
  }

  // null — файл годен; иначе причина отказа.
  static Future<String?> _verify(File f, ReleaseTicket t, AppInfo current) async {
    final size = await f.length();
    if (size != t.sizeBytes) return 'size_mismatch';
    final digest = await sha256.bind(f.openRead()).first;
    if (digest.toString() != t.sha256.toLowerCase()) return 'sha_mismatch';
    final info = await apkVerifier(f.path);
    if (info == null || info.packageName != current.packageName) {
      return 'bad_package';
    }
    if (info.versionCode != t.versionCode) return 'bad_package';
    if (!info.signatureMatches) return 'bad_signature';
    if (info.versionCode! <= current.versionCode) return 'not_newer';
    return null;
  }

  static void _watchProtocol(AppNotifier n, Directory dir) {
    _watchTimer?.cancel();
    final started = DateTime.now();
    _watchTimer = Timer.periodic(UpdateLimits.protocolPollInterval, (t) async {
      final summary = await _readProtocol(dir);
      final expired = DateTime.now().difference(started) > UpdateLimits.protocolWatchMax;
      if (summary.outcome == UpdateOutcome.failed ||
          summary.outcome == UpdateOutcome.rollbackFailed ||
          expired) {
        t.cancel();
        final pendingFile = File('${dir.path}/${UpdateLimits.pendingName}');
        Map<String, dynamic> pending = {};
        try {
          pending = jsonDecode(await pendingFile.readAsString()) as Map<String, dynamic>;
        } catch (_) {}
        final current = await appInfoProvider();
        await _finishWithoutInstall(
          n,
          dir,
          pending,
          current ?? const AppInfo('', 0, ''),
          summary,
          timedOut: expired && summary.outcome == UpdateOutcome.inProgress,
        );
      }
    });
  }

  // Прежняя версия осталась: установка не удалась или откат уже сработал.
  static Future<void> _finishWithoutInstall(
    AppNotifier n,
    Directory dir,
    Map<String, dynamic> pending,
    AppInfo current,
    ProtocolSummary summary, {
    bool timedOut = false,
  }) async {
    final mode = pending['mode'] as String? ?? 'install';
    final data = {
      'action': mode,
      'from_version': pending['from_name'],
      'to_version': pending['to_name'],
      'protocol': summary.events,
    };
    if (summary.outcome == UpdateOutcome.rolledBack) {
      await _event(CloudEventType.updateRolledBack, {...data, 'automatic': mode == 'install'});
      await _record('rolled_back', pending['from_name'] as String?, pending['to_name'] as String?);
    } else {
      final reason = timedOut
          ? 'script_no_result'
          : (summary.detail ?? (summary.events.isEmpty ? 'no_protocol' : 'failed'));
      await _event(CloudEventType.updateFailed, {...data, 'reason': reason});
      await _record(reason, pending['from_name'] as String?, pending['to_name'] as String?, failed: true);
    }
    await _deleteQuietly(File('${dir.path}/${UpdateLimits.pendingName}'));
    inProgress = false;
    n.setMaintenance(false);
  }

  // Новая версия запущена: ждём условий здоровья, пишем сигнал, отчитываемся.
  static void _healthLoop(
    AppNotifier n,
    Directory dir,
    Map<String, dynamic> pending,
    AppInfo current,
    ProtocolSummary summary,
    DateTime? startedAt,
  ) {
    inProgress = true; // оплата заблокирована до подтверждения здоровья
    n.setMaintenance(true);
    final bootAt = DateTime.now();
    Timer.periodic(const Duration(seconds: 3), (t) async {
      final polled = SyncService.lastPollOkAt != null &&
          SyncService.lastPollOkAt!.isAfter(bootAt);
      final ok = HealthGate.ready(
        busHealthy: n.busHealthy,
        idle: _isIdle(n.state),
        cloudEnabled: CloudService.isCloudEnabled,
        cloudPolled: polled,
      );
      if (!ok) return;
      t.cancel();
      try {
        await File('${dir.path}/${UpdateLimits.healthName}')
            .writeAsString('ok ${current.versionCode}\n');
      } catch (e) {
        AppLog.log('UpdateService', 'не удалось записать сигнал здоровья: ${e.runtimeType}');
      }
      final mode = pending['mode'] as String? ?? 'install';
      final duration = startedAt == null
          ? null
          : DateTime.now().difference(startedAt).inSeconds;
      if (mode == 'rollback') {
        await _event(CloudEventType.updateRolledBack, {
          'action': 'rollback',
          'manual': true,
          'from_version': pending['from_name'],
          'to_version': pending['to_name'],
          'duration_s': ?duration,
        });
        await _record('rolled_back', pending['from_name'] as String?, pending['to_name'] as String?);
      } else {
        await _event(CloudEventType.updateInstalled, {
          'from_version': pending['from_name'],
          'from_code': pending['from_code'],
          'to_version': pending['to_name'],
          'to_code': pending['to_code'],
          'duration_s': ?duration,
        });
        await _record('installed', pending['from_name'] as String?, pending['to_name'] as String?);
      }
      await _deleteQuietly(File('${dir.path}/${UpdateLimits.pendingName}'));
      inProgress = false;
      n.setMaintenance(false);
    });
  }

  static bool _isIdle(AppState s) =>
      s == AppState.standby ||
      s == AppState.outOfService ||
      s == AppState.selectLanguage;

  static Future<ProtocolSummary> _readProtocol(Directory dir) async {
    try {
      final f = File('${dir.path}/${UpdateLimits.protocolName}');
      if (!f.existsSync()) return UpdateProtocol.parse('');
      return UpdateProtocol.parse(await f.readAsString());
    } catch (_) {
      return UpdateProtocol.parse('');
    }
  }

  static Future<void> _record(
    String result,
    String? from,
    String? to, {
    bool failed = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kLast,
        jsonEncode({
          'at': DateTime.now().toIso8601String(),
          'result': result,
          'ok': !failed,
          'from': from,
          'to': to,
        }),
      );
    } catch (_) {}
  }

  static Future<void> _event(String type, Map<String, dynamic> data) async {
    AppLog.log('UpdateService', '$type ${jsonEncode(data)}');
    await CloudService.report(type, data: data);
  }

  static Future<void> _writeJson(Directory dir, String name, Map<String, dynamic> j) =>
      File('${dir.path}/$name').writeAsString(jsonEncode(j));

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  // ---------------------------------------------------------- реализации

  static Future<Directory?> _defaultDir() async {
    try {
      final p = await _channel.invokeMethod<String>('getFilesDir');
      return p == null ? null : Directory('$p/${UpdateLimits.dirName}');
    } catch (_) {
      return null;
    }
  }

  static Future<AppInfo?> _nativeAppInfo() async {
    try {
      final m = await _channel.invokeMethod<Map>('getAppInfo');
      if (m == null || m['version_code'] == null) return null;
      return AppInfo(
        m['package'] as String,
        (m['version_code'] as num).toInt(),
        m['version_name'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  static Future<ApkInfo?> _nativeVerify(String path) async {
    try {
      final m = await _channel.invokeMethod<Map>('verifyApk', {'path': path});
      if (m == null || m['error'] != null) return null;
      return ApkInfo(
        packageName: m['package'] as String?,
        versionCode: (m['version_code'] as num?)?.toInt(),
        versionName: m['version_name'] as String?,
        signatureMatches: m['signature_matches'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<int?> _nativeDiskFree() async {
    try {
      final m = await _channel.invokeMethod<Map>('getDeviceInfo');
      return (m?['disk_free_bytes'] as num?)?.toInt();
    } catch (_) {
      return null;
    }
  }

  // Запрос подписанной ссылки у Edge Function release-url.
  static Future<ReleaseTicket> _fetchTicket(AppConfig cfg, String releaseId) async {
    final base = cfg.cloudUrl.replaceAll(RegExp(r'/+$'), '');
    final Uri endpoint = Uri.parse('$base/functions/v1/release-url');
    http.Response resp;
    try {
      resp = await http
          .post(
            endpoint,
            headers: {
              'apikey': cfg.cloudAnonKey,
              'Authorization': 'Bearer ${cfg.cloudAnonKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'device': cfg.deviceId,
              'token': cfg.cloudToken,
              'release': releaseId,
            }),
          )
          .timeout(UpdateLimits.urlRequestTimeout);
    } catch (_) {
      throw const DownloadException('network');
    }
    if (resp.statusCode != 200) {
      final code = switch (resp.statusCode) {
        401 => 'auth',
        404 => 'not_found',
        429 => 'rate_limited',
        _ => 'http_${resp.statusCode}',
      };
      throw DownloadException(code);
    }
    try {
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['ok'] != true) throw const DownloadException('bad_response');
      final url = Uri.parse(j['url'] as String);
      // Ссылка должна вести на тот же сервер, что и облако: подмена адреса
      // в ответе не должна уводить скачивание на чужой хост.
      if (url.scheme != 'https' || url.host != Uri.parse(base).host) {
        throw const DownloadException('bad_url');
      }
      return ReleaseTicket(
        url: url,
        sha256: (j['sha256'] as String).toLowerCase(),
        sizeBytes: (j['size_bytes'] as num).toInt(),
        versionCode: (j['version_code'] as num).toInt(),
        versionName: j['version_name'] as String,
      );
    } on DownloadException {
      rethrow;
    } catch (_) {
      throw const DownloadException('bad_response');
    }
  }

  // Скачивание с ограничением размера и таймаутами. Больше заявленного
  // размера не принимается; нет новых байт дольше downloadIdleTimeout — отказ.
  static Future<void> _download(Uri url, File dest, int maxBytes) async {
    final client = HttpClient()
      ..connectionTimeout = UpdateLimits.urlRequestTimeout;
    IOSink? sink;
    try {
      await (() async {
        final req = await client.getUrl(url);
        req.followRedirects = false;
        final resp = await req.close();
        if (resp.statusCode != 200) {
          throw DownloadException('http_${resp.statusCode}');
        }
        if (resp.contentLength > maxBytes) {
          throw const DownloadException('too_big');
        }
        sink = dest.openWrite();
        var got = 0;
        await for (final chunk in resp.timeout(UpdateLimits.downloadIdleTimeout)) {
          got += chunk.length;
          if (got > maxBytes) throw const DownloadException('too_big');
          sink!.add(chunk);
        }
        await sink!.flush();
      })().timeout(UpdateLimits.downloadTotalTimeout);
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  // Реализации по умолчанию — для тестов (подменяемые поля выше затираются).
  @visibleForTesting
  static Future<ReleaseTicket> ticketFetcherDefault(AppConfig cfg, String id) =>
      _fetchTicket(cfg, id);
  @visibleForTesting
  static Future<void> downloaderDefault(Uri url, File dest, int maxBytes) =>
      _download(url, dest, maxBytes);

  @visibleForTesting
  static void resetForTest() {
    _watchTimer?.cancel();
    _watchTimer = null;
    inProgress = false;
    installer = RootInstaller();
    dirProvider = _defaultDir;
    ticketFetcher = _fetchTicket;
    downloader = _download;
    apkVerifier = _nativeVerify;
    appInfoProvider = _nativeAppInfo;
    diskFreeProvider = _nativeDiskFree;
    adbNetwork = null;
  }
}
