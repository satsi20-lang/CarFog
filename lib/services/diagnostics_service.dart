import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/app_state.dart';
import '../models/bus_map.dart';
import '../models/remote_limits.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'heater_safety_monitor.dart';
import 'heater_trial_service.dart';
import 'modbus_service.dart';
import 'output_watchdog_service.dart';

// Итог последней попытки отправки пакета (для сервисного меню).
class DiagnosticsStatus {
  final String bundleId;
  final DateTime at;
  final int sizeBytes;
  final int parts;
  // true — все части приняты сервером; false — пакет ждёт повторной отправки.
  final bool sent;
  final String? error;

  const DiagnosticsStatus({
    required this.bundleId,
    required this.at,
    required this.sizeBytes,
    required this.parts,
    required this.sent,
    this.error,
  });
}

// Пакет диагностики (R1): один JSON со снимком состояния аппарата, хвостами
// истории событий и журнала. Собирается по команде collect_diagnostics и
// кнопкой в сервисном меню, отправляется на сервер по частям
// (DiagnosticsLimits.chunkChars).
//
// Принципы:
//  * шина во время приёма денег и цикла НЕ трогается (в занятых
//    состояниях чтения пропускаются) — диагностика не должна мешать
//    работе;
//  * секреты в пакет не попадают двояко: конфигурация собирается по
//    белому списку полей (без PIN/токена/ключа), а готовый JSON ещё раз
//    прогоняется через AppLog.redact;
//  * нет связи — пакет сохраняется на диск и уходит позже (retryPending),
//    а в статусе значится НЕотправленным, не теряется молча.
class DiagnosticsService {
  DiagnosticsService._();

  static const _channel = MethodChannel('com.carfog.dryfog/system');
  static const pendingFileName = 'diag_pending.json';

  static DiagnosticsStatus? last;
  static Directory? _dirOverride;

  @visibleForTesting
  static void setDirForTest(Directory? d) => _dirOverride = d;

  static bool _busyState(AppState s) {
    switch (s) {
      case AppState.payment:
      case AppState.preparing:
      case AppState.compressorStartup:
      case AppState.treating:
      case AppState.shutdown:
        return true;
      default:
        return false;
    }
  }

  // ---------------------------------------------------------------- сбор

  static Future<Map<String, dynamic>> collect(AppNotifier n) async {
    final now = DateTime.now();
    final cfg = n.config;

    Map<String, dynamic> device = const {};
    try {
      final r = await _channel.invokeMethod<Map>('getDeviceInfo');
      device = r?.map((k, v) => MapEntry(k.toString(), v)) ?? const {};
    } catch (e) {
      device = {'error': e.toString()};
    }

    final oos = n.outOfService;
    final busy = _busyState(n.state);
    final reads = <String, dynamic>{};
    if (busy) {
      reads['skipped'] = 'busy_state:${n.state.name}';
    } else {
      // Живые чтения только в состояниях покоя; каждое в своём try —
      // сбой одного не лишает остальных.
      if (cfg.thermoInstalled) {
        reads['temperature_c'] = await _safe(() => ModbusService.readTemperature());
      }
      if (cfg.energyMeterInstalled) {
        final e = await _safe(() => ModbusService.readEnergy());
        reads['energy'] = e;
      }
      reads['coils'] = await _safe(() => ModbusService.readCoils());
    }
    reads['levels_cached'] = n.levels;

    final events = (await CloudService.history())
        .reversed
        .take(DiagnosticsLimits.eventsTail)
        .toList()
        .reversed
        .map((e) => e.toJson())
        .toList();

    final bundle = <String, dynamic>{
      'bundle_version': 1,
      'collected_at': now.toIso8601String(),
      'device_id': cfg.deviceId,
      'app': {
        'version': CloudService.appVersion,
        'start_reason': AppLog.startReason,
        'log_ready': AppLog.isReady,
      },
      'device': device,
      'state': {
        'app_state': n.state.name,
        'error_code': n.errorCode,
        'out_of_service': oos == null
            ? null
            : {
                'code': oos.code,
                'since': oos.since.toIso8601String(),
                'details': oos.details,
              },
        'config_blocked_devices': n.missingRequiredDevices,
        'payment_blocked': n.isPaymentBlocked,
        'bus_healthy': n.busHealthy,
        'bus_busy_port': n.busBusyPort,
        'bus_busy_pid': n.busBusyPid,
      },
      // Белый список полей: PIN, токен и ключ облака сюда не входят вовсе.
      'config': {
        ...cfg.reportedSnapshot(),
        'price_cents': cfg.treatmentPriceCents,
        'terminal_enabled': cfg.paymentTerminalEnabled,
        'terminal_channel': cfg.paymentTerminalChannel,
        'terminal_mode': cfg.paymentTerminalMode,
        'terminal_guard_ms': cfg.paymentTerminalGuardMs,
        'watchdog_enabled': cfg.outputWatchdogEnabled,
        'dio_installed': cfg.dioInstalled,
        'thermo_installed': cfg.thermoInstalled,
        'energy_meter_installed': cfg.energyMeterInstalled,
        'coin_acceptor_installed': cfg.coinAcceptorInstalled,
        'cloud_enabled': cfg.cloudEnabled,
        'idle_tariff_per_kwh': cfg.idlePowerTariffPerKwh,
      },
      'debug_modes': await _safe(() => ModbusService.activeDebugModes()),
      'reads': reads,
      'watchdog': OutputWatchdogService.status(),
      'detectors': {
        'last_fault': HeaterSafetyMonitor.lastFault,
        'thresholds': {
          'overheat_abort_c': HeaterThresholds.overheatAbortC,
          'bad_read_confirm': HeaterThresholds.sensorBadReadConfirmCount,
          'stale_window_s': HeaterThresholds.sensorStaleWindow.inSeconds,
          'no_rise_window_s': HeaterThresholds.noRiseWindow.inSeconds,
          'no_rise_min_c': HeaterThresholds.noRiseMinC,
          'energy_budget_wh': HeaterThresholds.preheatEnergyBudgetWh,
          'preheat_timeout_s': HeaterThresholds.preheatTimeout.inSeconds,
          'max_rate_c_per_s': HeaterThresholds.sensorMaxRateCPerS,
        },
      },
      'trial': HeaterTrialService.status(),
      'network': {
        'type': device['net_type'],
        'validated': device['net_validated'],
        'signal': device['net_signal'],
        'wifi_rssi_dbm': device['wifi_rssi_dbm'],
        'queue_pending': await CloudService.pendingCount(),
        'last_successful_send_at':
            CloudService.lastSuccessfulSendAt?.toIso8601String(),
        'cloud_enabled': CloudService.isCloudEnabled,
      },
      'events_tail': events,
      'log_tail': await AppLog.tail(DiagnosticsLimits.logTailLines),
    };
    return bundle;
  }

  static Future<Object?> _safe(Future<Object?> Function() f) async {
    try {
      return await f();
    } catch (e) {
      return 'error: $e';
    }
  }

  // JSON-текст пакета с вырезанными секретами (чистятся значения до
  // кодирования — готовый JSON чистить нельзя, он бы сломался).
  static String encode(Map<String, dynamic> bundle) =>
      jsonEncode(AppLog.redactTree(bundle));

  // ----------------------------------------------------------- отправка

  static List<String> split(String text) {
    final size = DiagnosticsLimits.chunkChars;
    if (text.length <= size) return [text];
    return [
      for (var i = 0; i < text.length; i += size)
        text.substring(i, i + size > text.length ? text.length : i + size),
    ];
  }

  // Собрать и отправить. Возвращает статус; неотправленный пакет остаётся
  // на диске для retryPending().
  static Future<DiagnosticsStatus> collectAndSend(
    AppNotifier n, {
    String trigger = 'manual',
  }) async {
    final bundle = await collect(n);
    bundle['trigger'] = trigger;
    final text = encode(bundle);
    final id = 'diag-${DateTime.now().millisecondsSinceEpoch}';
    final status = await _upload(id, text);
    if (!status.sent) await _savePending(id, text);
    last = status;
    AppLog.log('Diagnostics',
        'bundle $id ${status.sizeBytes} B parts=${status.parts} sent=${status.sent} ${status.error ?? ''}');
    return status;
  }

  static Future<DiagnosticsStatus> _upload(String id, String text) async {
    final parts = split(text);
    final size = utf8.encode(text).length;
    String? error;
    var sent = true;
    for (var i = 0; i < parts.length; i++) {
      final ok = await CloudService.transport.uploadDiagnostics(
        CloudService.deviceId,
        id,
        i + 1,
        parts.length,
        parts[i],
      );
      if (!ok) {
        sent = false;
        error = 'часть ${i + 1}/${parts.length} не принята';
        break;
      }
    }
    return DiagnosticsStatus(
      bundleId: id,
      at: DateTime.now(),
      sizeBytes: size,
      parts: parts.length,
      sent: sent,
      error: error,
    );
  }

  // Повторная отправка отложенного пакета (вызывается из тика синхронизации
  // при включённом облаке).
  static Future<void> retryPending() async {
    final f = await _pendingFile();
    if (f == null || !await f.exists()) return;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final id = j['id'] as String;
      final text = j['text'] as String;
      final status = await _upload(id, text);
      last = status;
      if (status.sent) await f.delete();
    } catch (e) {
      AppLog.log('Diagnostics', 'retryPending error: $e');
    }
  }

  static Future<bool> hasPending() async {
    final f = await _pendingFile();
    return f != null && await f.exists();
  }

  static Future<File?> _pendingFile() async {
    final dir = _dirOverride ?? await _appDir();
    return dir == null ? null : File('${dir.path}/$pendingFileName');
  }

  static Future<void> _savePending(String id, String text) async {
    try {
      final f = await _pendingFile();
      if (f == null) return;
      await f.writeAsString(jsonEncode({'id': id, 'text': text}));
    } catch (e) {
      AppLog.log('Diagnostics', 'не удалось сохранить отложенный пакет: $e');
    }
  }

  static Future<Directory?> _appDir() async {
    try {
      final p = await _channel.invokeMethod<String>('getFilesDir');
      return p == null ? null : Directory(p);
    } catch (_) {
      return null;
    }
  }
}
