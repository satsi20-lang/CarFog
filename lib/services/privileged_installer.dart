import 'dart:io';

import '../models/adb_exposure.dart';
import 'update_script.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Параметры запуска установочного скрипта.
class InstallRequest {
  // 'install' — поставить новую версию (с резервной копией текущей и откатом
  // при отсутствии сигнала здоровья); 'rollback' — вернуть резервную.
  final String mode;
  final String packageName;
  final String scriptPath; // куда записать скрипт (в каталоге приложения)
  final String apkPath; // новый APK (для install)
  final String backupPath;
  final int targetVersionCode;
  final String healthPath;
  final String logPath;
  final String aliasClass;
  final String mainActivity;
  final bool kioskEnabled;
  final int healthTimeoutS;

  const InstallRequest({
    required this.mode,
    required this.packageName,
    required this.scriptPath,
    required this.apkPath,
    required this.backupPath,
    required this.targetVersionCode,
    required this.healthPath,
    required this.logPath,
    required this.aliasClass,
    required this.mainActivity,
    required this.kioskEnabled,
    required this.healthTimeoutS,
  });
}

// Все привилегированные действия — за одним интерфейсом. Вызывающий код про
// root не знает: сегодня RootInstaller, позже, при необходимости,
// DeviceOwnerInstaller (пока заглушка).
abstract class PrivilegedInstaller {
  // Имя реализации (для журнала и отчёта).
  String get kind;

  // Привилегии доступны (для root: su ответил uid=0 за timeout).
  Future<bool> isAvailable(Duration timeout);

  // Запуск установки/отката в отдельном процессе, переживающем смерть
  // приложения. true — скрипт ЗАПУЩЕН (его результат — в протоколе).
  Future<bool> startScript(InstallRequest request, String scriptText);

  // Новое приложение после обновления, если скрипт не дошёл до конца: вернуть
  // владельца каталога update, контекст и роль домашнего экрана. true — ок.
  Future<bool> repairAfterUpdate({
    required String dir,
    required String packageName,
    required String aliasClass,
    required bool kiosk,
  });

  // Сетевой adb (models/adb_exposure.dart): фактическое состояние (null —
  // нет привилегий), открыть/закрыть 5555 до перезагрузки, выключить
  // беспроводную отладку. true — команда выполнилась (итог проверяет
  // вызывающий повторным чтением).
  Future<AdbExposure?> readAdbExposure();
  Future<bool> setAdbNetwork(bool enabled);
  Future<bool> disableAdbWifi();
}

// Реализация через root (su 0 …) на стороне Kotlin (RootShell).
class RootInstaller implements PrivilegedInstaller {
  static const _channel = MethodChannel('com.carfog.dryfog/system');

  @override
  String get kind => 'root';

  @override
  Future<bool> isAvailable(Duration timeout) async {
    try {
      return await _channel.invokeMethod<bool>('rootAvailable', {
            'timeoutMs': timeout.inMilliseconds,
          }) ??
          false;
    } catch (e) {
      debugPrint('RootInstaller.isAvailable error: ${e.runtimeType}');
      return false;
    }
  }

  @override
  Future<bool> startScript(InstallRequest r, String scriptText) async {
    try {
      // Текст скрипта задаёт Dart (он проверяется тестами), файл пишется в
      // каталог приложения, запускает его root в отдельном процессе.
      await File(r.scriptPath).writeAsString(scriptText);
      final ok = await _channel.invokeMethod<bool>('runRootScript', {
        'script': r.scriptPath,
        'args': [
          r.mode,
          r.packageName,
          r.apkPath,
          r.backupPath,
          r.targetVersionCode.toString(),
          r.healthPath,
          r.logPath,
          r.aliasClass,
          r.mainActivity,
          r.kioskEnabled ? '1' : '0',
          r.healthTimeoutS.toString(),
        ],
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('RootInstaller.startScript error: ${e.runtimeType}');
      return false;
    }
  }

  Future<Map<String, dynamic>?> _exec(String cmd, {int timeoutMs = 10000}) async {
    try {
      final r = await _channel.invokeMethod<Map>('rootExec', {
        'command': cmd,
        'timeoutMs': timeoutMs,
      });
      return r?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> repairAfterUpdate({
    required String dir,
    required String packageName,
    required String aliasClass,
    required bool kiosk,
  }) async {
    final r = await _exec(
      buildRepairCommand(
        dir: dir,
        packageName: packageName,
        aliasClass: aliasClass,
        kiosk: kiosk,
      ),
      timeoutMs: 20000,
    );
    return r != null && r['exit'] == 0;
  }

  @override
  Future<bool> setAdbNetwork(bool enabled) async {
    final r = await _exec(enabled ? adbOpenCommand : adbCloseCommand);
    return r != null && r['exit'] == 0;
  }

  @override
  Future<bool> disableAdbWifi() async {
    final r = await _exec(adbWifiOffCommand);
    return r != null && r['exit'] == 0;
  }

  @override
  Future<AdbExposure?> readAdbExposure() async {
    final r = await _exec(adbProbeCommand);
    if (r == null || r['exit'] != 0) return null;
    return AdbExposure.parse(r['out'] as String? ?? '');
  }
}

// Заглушка: Device Owner как запасной путь. Пока не реализуется — любая
// попытка отвечает отказом not_supported.
class DeviceOwnerInstaller implements PrivilegedInstaller {
  @override
  String get kind => 'device_owner';

  @override
  Future<bool> isAvailable(Duration timeout) async => false;

  @override
  Future<bool> startScript(InstallRequest request, String scriptText) async =>
      false;

  @override
  Future<bool> repairAfterUpdate({
    required String dir,
    required String packageName,
    required String aliasClass,
    required bool kiosk,
  }) async => false;

  @override
  Future<bool> setAdbNetwork(bool enabled) async => false;

  @override
  Future<bool> disableAdbWifi() async => false;

  @override
  Future<AdbExposure?> readAdbExposure() async => null;
}
