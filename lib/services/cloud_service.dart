import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================
// ТИПЫ СОБЫТИЙ
// ============================================================

class CloudEventType {
  static const appStarted = 'app_started';
  // Запуск после аварийного завершения (Шаг 32, задача 6) — отдельный тип,
  // а не app_started с полем в data, чтобы подсветка тревожным цветом в
  // локальном журнале и в веб-панели была простым фильтром по типу, без
  // разбора вложенных полей.
  static const appStartedAfterCrash = 'app_started_after_crash';
  static const serviceLoginOk = 'service_login_ok';
  static const unauthorizedAccess = 'unauthorized_access';
  static const masterCodeUsed = 'master_code_used';
  static const factoryReset = 'factory_reset';
  static const lowLiquid = 'low_liquid';
  static const sessionComplete = 'session_complete';
  static const hardwareError = 'hardware_error';
  static const energyReading = 'energy_reading';
  static const commandExecuted = 'command_executed';
  static const configChanged = 'config_changed';
}

// ============================================================
// СОБЫТИЕ
// ============================================================

class CloudEvent {
  final String type;
  final DateTime ts;
  final Map<String, dynamic> data;

  CloudEvent({
    required this.type,
    DateTime? ts,
    Map<String, dynamic>? data,
  })  : ts = ts ?? DateTime.now(),
        data = data ?? const {};

  Map<String, dynamic> toJson() => {
        'type': type,
        'ts': ts.toIso8601String(),
        'data': data,
      };

  factory CloudEvent.fromJson(Map<String, dynamic> j) => CloudEvent(
        type: j['type'] as String? ?? 'unknown',
        ts: DateTime.tryParse(j['ts'] as String? ?? '') ?? DateTime.now(),
        data: (j['data'] as Map<String, dynamic>?) ?? const {},
      );
}

// ============================================================
// КОМАНДА ИЗ ОБЛАКА
// ============================================================

class CloudCommand {
  final String id;
  final String action; // 'factory_reset' | 'set_pin' | 'unlock' | 'update_config'
  final Map<String, dynamic> params;

  CloudCommand({
    required this.id,
    required this.action,
    Map<String, dynamic>? params,
  }) : params = params ?? const {};

  factory CloudCommand.fromJson(Map<String, dynamic> j) => CloudCommand(
        id: j['id'] as String? ?? '',
        action: j['action'] as String? ?? '',
        params: (j['params'] as Map<String, dynamic>?) ?? const {},
      );
}

// ============================================================
// ТРАНСПОРТ — интерфейс. Реализация меняется без правки кода приложения.
// ============================================================

abstract class CloudTransport {
  Future<bool> send(String deviceId, List<CloudEvent> events);
  Future<List<CloudCommand>> fetchCommands(String deviceId);
  Future<bool> ackCommand(
    String deviceId,
    String commandId,
    bool ok,
    String? result,
  );
}

// Заглушка: пишет в отладочный лог, ничего никуда не отправляет.
// Используется, пока бэкенд не поднят.
class LocalLogTransport implements CloudTransport {
  @override
  Future<bool> send(String deviceId, List<CloudEvent> events) async {
    for (final e in events) {
      debugPrint('CLOUD[$deviceId] ${e.ts.toIso8601String()} '
          '${e.type} ${jsonEncode(e.data)}');
    }
    return true;
  }

  @override
  Future<List<CloudCommand>> fetchCommands(String deviceId) async => [];

  @override
  Future<bool> ackCommand(
    String deviceId,
    String commandId,
    bool ok,
    String? result,
  ) async {
    debugPrint('CLOUD[$deviceId] ack $commandId ok=$ok result=$result');
    return true;
  }
}

// ============================================================
// ТРАНСПОРТ SUPABASE
// ============================================================

class SupabaseTransport implements CloudTransport {
  final String baseUrl; // https://xxxx.supabase.co
  final String anonKey; // публичный ключ anon
  final String deviceToken; // секретный токен этого аппарата

  SupabaseTransport({
    required this.baseUrl,
    required this.anonKey,
    required this.deviceToken,
  });

  static const _timeout = Duration(seconds: 15);

  Uri _rpc(String fn) =>
      Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/rest/v1/rpc/$fn');

  Map<String, String> get _headers => {
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
        'Content-Type': 'application/json',
      };

  @override
  Future<bool> send(String deviceId, List<CloudEvent> events) async {
    if (events.isEmpty) return true;
    try {
      final resp = await http
          .post(
            _rpc('device_report'),
            headers: _headers,
            body: jsonEncode({
              'p_device': deviceId,
              'p_token': deviceToken,
              'p_events': events.map((e) => e.toJson()).toList(),
            }),
          )
          .timeout(_timeout);

      if (resp.statusCode != 200) {
        debugPrint('SupabaseTransport.send HTTP ${resp.statusCode}: ${resp.body}');
        return false;
      }

      final body = jsonDecode(resp.body);
      final ok = body is Map && body['ok'] == true;
      if (!ok) debugPrint('SupabaseTransport.send отказ: ${resp.body}');
      return ok;
    } catch (e) {
      debugPrint('SupabaseTransport.send error: $e');
      return false;
    }
  }

  @override
  Future<List<CloudCommand>> fetchCommands(String deviceId) async {
    try {
      final resp = await http
          .post(
            _rpc('device_poll'),
            headers: _headers,
            body: jsonEncode({
              'p_device': deviceId,
              'p_token': deviceToken,
              'p_version': CloudService.appVersion,
            }),
          )
          .timeout(_timeout);

      if (resp.statusCode != 200) {
        debugPrint('SupabaseTransport.fetchCommands HTTP ${resp.statusCode}');
        return [];
      }

      final body = jsonDecode(resp.body);
      if (body is! Map || body['ok'] != true) return [];

      final raw = body['commands'];
      if (raw is! List) return [];

      return raw
          .map((c) => CloudCommand.fromJson(c as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('SupabaseTransport.fetchCommands error: $e');
      return [];
    }
  }

  @override
  Future<bool> ackCommand(
    String deviceId,
    String commandId,
    bool ok,
    String? result,
  ) async {
    try {
      final resp = await http
          .post(
            _rpc('device_ack'),
            headers: _headers,
            body: jsonEncode({
              'p_device': deviceId,
              'p_token': deviceToken,
              'p_command': commandId,
              'p_ok': ok,
              'p_result': result,
            }),
          )
          .timeout(_timeout);

      if (resp.statusCode != 200) {
        debugPrint('SupabaseTransport.ackCommand HTTP ${resp.statusCode}');
        return false;
      }
      final body = jsonDecode(resp.body);
      return body is Map && body['ok'] == true;
    } catch (e) {
      debugPrint('SupabaseTransport.ackCommand error: $e');
      return false;
    }
  }
}

// ============================================================
// СЕРВИС — единая точка входа для всего приложения
// ============================================================

class CloudService {
  static CloudTransport transport = LocalLogTransport();
  static String deviceId = 'CARFOG-001';
  static bool isCloudEnabled = false;
  static const String appVersion = '1.0.0';

  static const _queueKey = 'cloud_event_queue';
  static const _maxQueue = 500;

  static const _historyKey = 'cloud_event_history';
  static const _maxHistory = 200;

  // Выбирает транспорт по настройкам. Если облако выключено или
  // не заполнено — работает локальный лог, приложение полностью
  // функционально без интернета.
  static void configure({
    required String deviceId,
    required bool enabled,
    required String url,
    required String anonKey,
    required String token,
  }) {
    CloudService.deviceId = deviceId;

    if (enabled && url.isNotEmpty && anonKey.isNotEmpty && token.isNotEmpty) {
      transport = SupabaseTransport(
        baseUrl: url,
        anonKey: anonKey,
        deviceToken: token,
      );
      isCloudEnabled = true;
      debugPrint('CloudService: транспорт Supabase, аппарат $deviceId');
    } else {
      transport = LocalLogTransport();
      isCloudEnabled = false;
      debugPrint('CloudService: облако выключено, только локальный журнал');
    }
  }

  // Записать событие в очередь на отправку и в историю, затем попытаться отправить.
  static Future<void> report(
    String type, {
    Map<String, dynamic>? data,
  }) async {
    final event = CloudEvent(type: type, data: data);
    await _enqueue(event);
    await _appendHistory(event);
    await flush();
  }

  // Попытаться отправить всё, что накопилось.
  // Нет связи — события остаются в очереди до следующего раза.
  static Future<void> flush() async {
    try {
      final queue = await events();
      if (queue.isEmpty) return;

      final ok = await transport.send(deviceId, queue);
      if (ok) await clearQueue();
    } catch (e) {
      debugPrint('CloudService.flush error: $e');
    }
  }

  // Прочитать очередь (для вкладки Журнал в сервисном меню).
  static Future<List<CloudEvent>> events() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_queueKey) ?? [];
      return raw
          .map((s) => CloudEvent.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('CloudService.events error: $e');
      return [];
    }
  }

  static Future<void> clearQueue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_queueKey);
  }

  // Полная история событий аппарата, новые в конце.
  // Не зависит от того, доставлены события в облако или нет.
  static Future<List<CloudEvent>> history() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_historyKey) ?? [];
      return raw
          .map((s) => CloudEvent.fromJson(jsonDecode(s) as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('CloudService.history error: $e');
      return [];
    }
  }

  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_historyKey);
  }

  // Сколько событий ждёт отправки в облако.
  static Future<int> pendingCount() async => (await events()).length;

  static Future<void> _appendHistory(CloudEvent event) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_historyKey) ?? [];
      raw.add(jsonEncode(event.toJson()));

      while (raw.length > _maxHistory) {
        raw.removeAt(0);
      }

      await prefs.setStringList(_historyKey, raw);
    } catch (e) {
      debugPrint('CloudService._appendHistory error: $e');
    }
  }

  static Future<void> _enqueue(CloudEvent event) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_queueKey) ?? [];
      raw.add(jsonEncode(event.toJson()));

      // Не даём очереди расти бесконечно, если связи долго нет
      while (raw.length > _maxQueue) {
        raw.removeAt(0);
      }

      await prefs.setStringList(_queueKey, raw);
    } catch (e) {
      debugPrint('CloudService._enqueue error: $e');
    }
  }
}
