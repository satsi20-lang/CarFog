import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  static const liquidRestored = 'liquid_restored';
  static const sessionComplete = 'session_complete';
  static const hardwareError = 'hardware_error';
  static const energyReading = 'energy_reading';
  static const commandExecuted = 'command_executed';
  static const configChanged = 'config_changed';
  // Платёжный терминал сработал вне экрана оплаты (задача "терминал",
  // задача 5) — сухой контакт живёт своей жизнью, клиент мог приложить
  // карту в неподходящий момент. Деньги спишутся, услуга не будет
  // оказана — обязательно долетает до оператора.
  static const unexpectedPayment = 'unexpected_payment';
  // Любой отладочный переключатель сервисного меню, подделывающий
  // поведение аппарата (задача "контроль цикла по электросчётчику" —
  // страховка на переключатель имитации отказа монетоприёмника, но
  // правило общее для всех будущих отладочных режимов): аппарат,
  // принимающий деньги, не должен уметь спрятать, что он в отладочном
  // режиме. data несёт код конкретного переключателя и, если включение,
  // когда он автоматически снимется сам (см. код в service_menu.dart).
  static const debugModeChanged = 'debug_mode_changed';

  // Аппарат выведен из обслуживания (задача "вывод аппарата из
  // обслуживания"): код причины и подробности отказа. Уходит ПОСЛЕ
  // подтверждённой записи признака на диск — сначала запись, потом всё
  // остальное. Если облака нет — обычная очередь донесёт при появлении
  // связи.
  static const outOfService = 'out_of_service';
  // Признак восстановлен при старте приложения (в том числе fail-closed
  // 'state_unreadable') — оператор должен узнать об этом раньше клиентов.
  static const outOfServiceRestored = 'out_of_service_restored';
  // Снят вручную на месте из сервисного меню, после успешного пробного
  // цикла. Удалённого снятия нет и не будет.
  static const outOfServiceCleared = 'out_of_service_cleared';
  // Пробный цикл из сервисного меню (результат: passed true/false).
  static const outOfServiceTrial = 'out_of_service_trial';
  // Внесённая сумма пропала из-за отмены/таймаута оплаты (деньги не
  // возвращаются монетоприёмником — оператору нужен след).
  static const paymentAbandoned = 'payment_abandoned';
  // Клиент заплатил дважды (монета и карта, либо второй платёж после
  // защёлки перехода к прогреву) — оператор должен знать, чтобы вернуть
  // лишнее.
  static const duplicatePayment = 'duplicate_payment';
  // Удалённое обновление приложения (R2).
  static const updateStarted = 'update_started';
  static const updateInstalled = 'update_installed';
  static const updateFailed = 'update_failed';
  static const updateRolledBack = 'update_rolled_back';
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
  final String action; // см. белый список в remote_commands.dart
  final Map<String, dynamic> params;
  // Время создания команды НА СЕРВЕРЕ (поле created_at в ответе
  // device_poll) — по нему отсекаются просроченные команды. null — сервер
  // поле не отдал: срок проверить нечем (см. supabase/migrations).
  final DateTime? createdAt;

  CloudCommand({
    required this.id,
    required this.action,
    Map<String, dynamic>? params,
    this.createdAt,
  }) : params = params ?? const {};

  factory CloudCommand.fromJson(Map<String, dynamic> j) => CloudCommand(
        id: j['id'] as String? ?? '',
        action: j['action'] as String? ?? '',
        params: (j['params'] as Map<String, dynamic>?) ?? const {},
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '')?.toLocal(),
      );
}

// ============================================================
// РЕЗУЛЬТАТ ОПРОСА (Шаг 34)
// ============================================================

// configReported — true, только если слепок настроек был передан этим
// вызовом И сервер его принял. SyncService по этому флагу решает, можно
// ли считать слепок отправленным (и не слать его снова, пока настройки
// не изменятся) — если запрос не удался, флаг остаётся false, и попытка
// естественным образом повторится на следующем опросе.
class CloudPollResult {
  final List<CloudCommand> commands;
  final bool configReported;
  // Время СЕРВЕРА на момент ответа (поле server_time device_poll). Срок
  // действия команд считается как server_time − created_at, а не по часам
  // планшета: у планшета время может уйти. null — сервер поле не отдал.
  final DateTime? serverTime;
  // Сервер ответил штатно (HTTP 200 и ok:true). Нужно сигналу здоровья
  // обновления: «один опрос облака прошёл».
  final bool ok;

  CloudPollResult({
    required this.commands,
    this.configReported = false,
    this.serverTime,
    this.ok = false,
  });
}

// ============================================================
// ТРАНСПОРТ — интерфейс. Реализация меняется без правки кода приложения.
// ============================================================

// Итог загрузки части пакета диагностики. error — причина отказа сервера
// ('quota', 'auth', 'bad_request', 'http_NNN', 'network'); null при успехе.
class DiagUploadResult {
  final bool ok;
  final String? error;
  const DiagUploadResult.ok() : ok = true, error = null;
  const DiagUploadResult.fail(this.error) : ok = false;

  // Отказ сервера, который сам не пройдёт при повторе (квота, токен,
  // неверная форма): повторять в цикле бессмысленно.
  bool get permanent =>
      error == 'quota' || error == 'auth' || error == 'bad_request';
}

abstract class CloudTransport {
  Future<bool> send(String deviceId, List<CloudEvent> events);

  // config — слепок фактических настроек аппарата (Шаг 34, задача 2),
  // прикладывается к этому же опросу. null — если в этот раз отправлять
  // нечего (решает вызывающий код, транспорт сам это не решает).
  Future<CloudPollResult> fetchCommands(
    String deviceId, {
    Map<String, dynamic>? config,
  });

  Future<bool> ackCommand(
    String deviceId,
    String commandId,
    bool ok,
    String? result,
  );

  // Загрузка пакета диагностики по частям (R1): part 1..parts, data — кусок
  // JSON-текста. true — сервер принял именно эту часть.
  Future<DiagUploadResult> uploadDiagnostics(
    String deviceId,
    String bundleId,
    int part,
    int parts,
    String data,
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
  Future<CloudPollResult> fetchCommands(
    String deviceId, {
    Map<String, dynamic>? config,
  }) async {
    // Заглушка без реального сервера — просто печатаем слепок в лог,
    // чтобы состав полей можно было проверить глазами без облака
    // (Шаг 34, задача 2.3).
    if (config != null) {
      debugPrint('CLOUD[$deviceId] reported_config: ${jsonEncode(config)}');
    }
    return CloudPollResult(commands: [], configReported: config != null);
  }

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

  // Облако выключено: пакет диагностики никуда не уходит. false — чтобы
  // он честно значился как НЕОТПРАВЛЕННЫЙ (и не терялся: DiagnosticsService
  // оставляет его на диске для повторной отправки).
  @override
  Future<DiagUploadResult> uploadDiagnostics(
    String deviceId,
    String bundleId,
    int part,
    int parts,
    String data,
  ) async {
    debugPrint('CLOUD[$deviceId] diagnostics $bundleId $part/$parts (облако выключено)');
    return const DiagUploadResult.fail('cloud_disabled');
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
  Future<CloudPollResult> fetchCommands(
    String deviceId, {
    Map<String, dynamic>? config,
  }) async {
    try {
      final resp = await http
          .post(
            _rpc('device_poll'),
            headers: _headers,
            body: jsonEncode({
              'p_device': deviceId,
              'p_token': deviceToken,
              'p_version': CloudService.appVersion,
              // Слепок настроек (Шаг 34, задача 2) — рядом с версией
              // приложения, тем же опросом. null, если в этот раз
              // отправлять нечего (device_poll на сервере просто
              // не тронет reported_config, см. coalesce в SQL).
              'p_config': config,
            }),
          )
          .timeout(_timeout);

      if (resp.statusCode != 200) {
        debugPrint('SupabaseTransport.fetchCommands HTTP ${resp.statusCode}');
        return CloudPollResult(commands: []);
      }

      final body = jsonDecode(resp.body);
      if (body is! Map || body['ok'] != true) {
        return CloudPollResult(commands: []);
      }

      final raw = body['commands'];
      final commands = raw is List
          ? raw.map((c) => CloudCommand.fromJson(c as Map<String, dynamic>)).toList()
          : <CloudCommand>[];

      return CloudPollResult(
        commands: commands,
        configReported: config != null,
        serverTime: DateTime.tryParse(body['server_time'] as String? ?? ''),
        ok: true,
      );
    } catch (e) {
      debugPrint('SupabaseTransport.fetchCommands error: $e');
      return CloudPollResult(commands: []);
    }
  }

  @override
  Future<DiagUploadResult> uploadDiagnostics(
    String deviceId,
    String bundleId,
    int part,
    int parts,
    String data,
  ) async {
    try {
      final resp = await http
          .post(
            _rpc('device_diag_put'),
            headers: _headers,
            body: jsonEncode({
              'p_device': deviceId,
              'p_token': deviceToken,
              'p_bundle': bundleId,
              'p_part': part,
              'p_parts': parts,
              'p_data': data,
            }),
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) {
        // Тело ответа в журнал НЕ пишем: сервер мог бы вернуть в нём
        // эхо запроса (токен, ключ).
        debugPrint('SupabaseTransport.uploadDiagnostics HTTP ${resp.statusCode}');
        return DiagUploadResult.fail('http_${resp.statusCode}');
      }
      final body = jsonDecode(resp.body);
      if (body is Map && body['ok'] == true) return const DiagUploadResult.ok();
      // Причина отказа сервера ('quota', 'auth', 'bad_request') — короткий
      // код, берём только его (строку из ответа, ограниченную по длине и
      // алфавиту): произвольный текст ответа в журнал/историю не идёт.
      final raw = body is Map ? body['error'] : null;
      final code = raw is String && RegExp(r'^[a-z_]{1,32}$').hasMatch(raw)
          ? raw
          : 'rejected';
      debugPrint('SupabaseTransport.uploadDiagnostics отказ сервера: $code');
      return DiagUploadResult.fail(code);
    } catch (e) {
      debugPrint('SupabaseTransport.uploadDiagnostics error: ${e.runtimeType}');
      return const DiagUploadResult.fail('network');
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

  // Версия, которую аппарат сообщает облаку при каждом опросе (p_version в
  // device_poll → devices.app_version, а также ping и пакет диагностики).
  // Источник — установленный пакет (versionName+versionCode из нативного
  // getAppInfo), заполняется при старте (initVersion). Запасное значение
  // ниже используется только если нативный вызов не ответил (и в тестах) —
  // его больше не надо поднимать вручную.
  static const String fallbackVersion = 'unknown';
  static String appVersion = fallbackVersion;

  static const MethodChannel _versionChannel = MethodChannel('com.carfog.dryfog/system');

  // Формат: "<versionName>+<versionCode>", например "1.5.8+16".
  static String formatVersion(String? name, num? code) {
    if (name == null || name.isEmpty) return fallbackVersion;
    return code == null ? name : '$name+${code.toInt()}';
  }

  static Future<void> initVersion() async {
    try {
      final m = await _versionChannel.invokeMethod<Map>('getAppInfo');
      appVersion = formatVersion(
        m?['version_name'] as String?,
        m?['version_code'] as num?,
      );
    } catch (_) {
      appVersion = fallbackVersion;
    }
  }

  static const _queueKey = 'cloud_event_queue';
  static const _maxQueue = 500;

  static const _historyKey = 'cloud_event_history';
  // Шаг 33 добавил регулярные события (почасовые energy_reading — 24/сутки,
  // плюс каждая платная сессия) — на 200 записей журнал в сервисном меню
  // схлопывался бы за 2-3 дня, вытесняя важное. 500 держит примерно
  // полторы-две недели истории на аппарате обычной загрузки.
  static const _maxHistory = 500;

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
    // Отправка НЕ ждётся: она идёт по сети и при отказе занимала бы
    // вызывающий код (экран ошибки клиента) на несколько таймаутов подряд.
    // Событие уже сохранено в очереди и уйдёт само.
    unawaited(flush());
  }

  // Операции с очередью (добавить/удалить отправленное) идут строго по
  // одной: параллельные чтение-изменение-запись SharedPreferences теряли
  // или дублировали события (при старте "восстановлено" и "запущено"
  // уходят одновременно).
  static Future<void> _queueLock = Future.value();
  static Future<T> _serial<T>(Future<T> Function() action) {
    final result = _queueLock.then((_) => action());
    _queueLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  static bool _flushing = false;
  static bool _flushAgain = false;

  // Только для тестов: цепочка блокировки очереди, созданная в «фейковом»
  // времени одного виджет-теста, не завершается в следующем (оно ждало бы
  // вечно). Сброс между тестами.
  @visibleForTesting
  static void resetQueueForTest() {
    _queueLock = Future.value();
    _flushing = false;
    _flushAgain = false;
  }

  // Время последней УСПЕШНОЙ отправки событий (для пакета диагностики и
  // сервисного меню). null — с запуска ещё не было.
  static DateTime? lastSuccessfulSendAt;

  // Попытаться отправить всё, что накопилось.
  // Нет связи — события остаются в очереди до следующего раза.
  static Future<void> flush() async {
    // Одна отправка за раз; если во время неё пришли новые события —
    // сразу после неё уходит следующая порция.
    if (_flushing) {
      _flushAgain = true;
      return;
    }
    _flushing = true;
    try {
      do {
        _flushAgain = false;
        final queue = await events();
        if (queue.isEmpty) break;
        final ok = await transport.send(deviceId, queue);
        if (!ok) break;
        // Только при включённом облаке: локальный транспорт "принимает"
        // события, но никуда их не отправляет.
        if (isCloudEnabled) lastSuccessfulSendAt = DateTime.now();
        // Удаляются ровно отправленные: очередь только растёт с конца, так
        // что это первые queue.length записей. Всё добавленное за время
        // отправки остаётся.
        await _removeSent(queue.length);
      } while (_flushAgain);
    } catch (e) {
      debugPrint('CloudService.flush error: $e');
    } finally {
      _flushing = false;
    }
  }

  static Future<void> _removeSent(int count) => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList(_queueKey) ?? [];
    if (raw.length <= count) {
      await prefs.remove(_queueKey);
    } else {
      await prefs.setStringList(_queueKey, raw.sublist(count));
    }
  });

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

  static Future<void> clearQueue() => _serial(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_queueKey);
  });

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

  static Future<void> _enqueue(CloudEvent event) => _serial(() async {
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
  });
}
