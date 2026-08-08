import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================
// ТИПЫ СОБЫТИЙ
// ============================================================

class CloudEventType {
  static const appStarted = 'app_started';
  static const serviceLoginOk = 'service_login_ok';
  static const unauthorizedAccess = 'unauthorized_access';
  static const masterCodeUsed = 'master_code_used';
  static const factoryReset = 'factory_reset';
  static const lowLiquid = 'low_liquid';
  static const sessionComplete = 'session_complete';
  static const hardwareError = 'hardware_error';
  static const energyReading = 'energy_reading';
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
}

// Боевая реализация. Заполнить, когда бэкенд будет готов.
class HttpCloudTransport implements CloudTransport {
  final String baseUrl;
  final String apiKey;

  HttpCloudTransport({required this.baseUrl, required this.apiKey});

  @override
  Future<bool> send(String deviceId, List<CloudEvent> events) async {
    // TODO: POST $baseUrl/events с заголовком Authorization: Bearer $apiKey
    // Тело: {'device_id': deviceId, 'events': events.map((e) => e.toJson()).toList()}
    // Вернуть true только при коде 2xx — иначе события останутся в очереди.
    debugPrint('HttpCloudTransport.send не реализован');
    return false;
  }

  @override
  Future<List<CloudCommand>> fetchCommands(String deviceId) async {
    // TODO: GET $baseUrl/commands?device_id=$deviceId
    debugPrint('HttpCloudTransport.fetchCommands не реализован');
    return [];
  }
}

// ============================================================
// СЕРВИС — единая точка входа для всего приложения
// ============================================================

class CloudService {
  static CloudTransport transport = LocalLogTransport();
  static String deviceId = 'CARFOG-001';

  static const _queueKey = 'cloud_event_queue';
  static const _maxQueue = 500;

  // Записать событие в очередь и попытаться отправить.
  static Future<void> report(
    String type, {
    Map<String, dynamic>? data,
  }) async {
    final event = CloudEvent(type: type, data: data);
    await _enqueue(event);
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
