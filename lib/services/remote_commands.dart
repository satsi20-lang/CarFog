import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/app_state.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'config_service.dart';
import 'diagnostics_service.dart';
import 'remote_command_guard.dart';
import 'security_service.dart';
import 'system_service.dart';

// Итог обработки удалённой команды. afterAck — действие, которое можно
// выполнить ТОЛЬКО после отправки ответа (перезапуск приложения).
class CommandOutcome {
  final bool ok;
  final String result;
  final Future<void> Function()? afterAck;

  const CommandOutcome(this.ok, this.result, {this.afterAck});
}

// Исполнитель удалённых команд (R1). БЕЛЫЙ СПИСОК: любое действие вне
// списка — отказ с записью в журнал, без исключения.
//
// Правила для всех команд (R1, п.3):
//  1. Команда не может включить выходы, поменять пороги безопасности,
//     снять вывод из обслуживания; PIN и конфигурацию меняют только уже
//     существовавшие set_pin / update_config / factory_reset (не
//     расширены).
//  2. Неизвестная команда → ack с отказом + журнал.
//  3. Просроченная → 'expired'; повторная доставка → 'duplicate'
//     (CommandGuard).
//  4. collect_diagnostics и restart_app ограничены по частоте ('rate_limited').
//  5. restart_app — только в покое, иначе 'busy' (не откладывается).
class RemoteCommands {
  RemoteCommands._();

  static const Set<String> whitelist = {
    'ping',
    'unlock',
    'set_pin',
    'update_config',
    'factory_reset',
    'reset_session',
    'collect_diagnostics',
    'restart_app',
  };

  // Явный отказ для команд, которые удалённо выполнять нельзя.
  static const Set<String> forbidden = {
    'clear_out_of_service',
    'reset_out_of_service',
    'resume_service',
  };

  // Состояния покоя, в которых допустим restart_app.
  static bool isIdle(AppState s) =>
      s == AppState.standby ||
      s == AppState.outOfService ||
      s == AppState.selectLanguage;

  // Подмена в тестах: что делать после ack для restart_app.
  @visibleForTesting
  static Future<void> Function() restartHook = SystemService.restartApp;

  static Future<CommandOutcome> handle(
    CloudCommand command,
    AppNotifier notifier, {
    DateTime? now,
    DateTime? serverTime,
  }) async {
    final refusal = await CommandGuard.preCheck(
      command,
      now: now,
      serverTime: serverTime,
    );
    if (refusal != null) {
      AppLog.log('RemoteCommands', 'отказ ${command.action}: $refusal');
      return CommandOutcome(false, refusal);
    }
    try {
      return await _run(command, notifier, now: now);
    } catch (e) {
      return CommandOutcome(false, 'ошибка выполнения: $e');
    }
  }

  static Future<CommandOutcome> _run(
    CloudCommand command,
    AppNotifier notifier, {
    DateTime? now,
  }) async {
    final action = command.action;

    if (forbidden.contains(action)) {
      // Снятие вывода из обслуживания — ТОЛЬКО на месте, из сервисного
      // меню после пробного цикла: отказ физический, дистанционно не
      // чинится, а удалённое снятие вернуло бы аппарат к сбору денег с тем
      // же дефектом.
      AppLog.log('RemoteCommands',
          'удалённое снятие вывода из обслуживания проигнорировано ($action)');
      return const CommandOutcome(
        false,
        'отклонено: вывод из обслуживания снимается только на месте, из '
        'сервисного меню, после пробного цикла',
      );
    }

    if (!whitelist.contains(action)) {
      AppLog.log('RemoteCommands', 'неизвестная команда: $action');
      return CommandOutcome(false, 'неизвестная команда: $action');
    }

    switch (action) {
      case 'ping':
        final oos = notifier.outOfService;
        return CommandOutcome(
          true,
          jsonEncode({
            'pong': true,
            'version': CloudService.appVersion,
            'state': notifier.state.name,
            'out_of_service': oos?.code,
            'bus_healthy': notifier.busHealthy,
            'config_blocked': notifier.missingRequiredDevices,
          }),
        );

      case 'unlock':
        await SecurityService.resetAttempts();
        return const CommandOutcome(true, 'блокировка снята');

      case 'set_pin':
        final pin = (command.params['pin'] ?? '').toString().trim();
        if (pin.length == 4 && int.tryParse(pin) != null) {
          await notifier.saveConfig(notifier.config.copyWith(servicePin: pin));
          await SecurityService.resetAttempts();
          return const CommandOutcome(true, 'PIN изменён');
        }
        return const CommandOutcome(false, 'PIN должен состоять из 4 цифр');

      case 'update_config':
        final updated = _applyConfig(notifier.config, command.params);
        await notifier.saveConfig(updated);
        return const CommandOutcome(true, 'настройки применены');

      case 'factory_reset':
        await _factoryReset(notifier);
        return const CommandOutcome(
          true,
          'сброшено к заводским, настройки облака сохранены',
        );

      case 'reset_session':
        notifier.resetSession();
        return const CommandOutcome(true, 'сессия сброшена');

      case 'collect_diagnostics':
        if (!await CommandGuard.allowRate(action, now: now)) {
          return const CommandOutcome(false, 'rate_limited');
        }
        final status = await DiagnosticsService.collectAndSend(
          notifier,
          trigger: 'command',
        );
        return CommandOutcome(
          status.sent,
          jsonEncode({
            'bundle_id': status.bundleId,
            'sent': status.sent,
            'parts': status.parts,
            'size_bytes': status.sizeBytes,
            if (status.error != null) 'error': status.error,
          }),
        );

      case 'restart_app':
        // Только в покое; во время оплаты/подготовки/обработки/завершения
        // (и в сервисном меню) — отказ 'busy', не откладывается.
        if (!isIdle(notifier.state)) {
          return CommandOutcome(false, 'busy:${notifier.state.name}');
        }
        if (!await CommandGuard.allowRate(action, now: now)) {
          return const CommandOutcome(false, 'rate_limited');
        }
        return CommandOutcome(
          true,
          'перезапуск через ~1.5 с после ответа',
          afterAck: () async {
            // Журнал сбрасывается на диск до завершения процесса.
            await AppLog.flush();
            await restartHook();
          },
        );
    }
    // Недостижимо (whitelist выше), но не оставляем без ответа.
    return CommandOutcome(false, 'неизвестная команда: $action');
  }

  // ---- применение настроек (перенесено из SyncService без изменений) ----

  static AppConfig _applyConfig(AppConfig current, Map<String, dynamic> params) {
    Map<String, List<String>>? names;
    final rawNames = params['flavorNames'];
    if (rawNames is Map) {
      names = rawNames.map(
        (k, v) => MapEntry(k.toString(), List<String>.from(v as List)),
      );
    }

    return current.copyWith(
      treatmentPriceCents: (params['treatmentPriceCents'] as num?)?.toInt(),
      treatmentDurationS: (params['treatmentDurationS'] as num?)?.toInt(),
      compressorPurgeS: (params['compressorPurgeS'] as num?)?.toInt(),
      pumpAfterHeaterS: (params['pumpAfterHeaterS'] as num?)?.toInt(),
      servicePin: params['servicePin'] as String?,
      flavorNames: names,
    );
  }

  // Сброс к заводским с сохранением подключения к облаку: без этого
  // аппарат после сброса потерял бы связь навсегда.
  static Future<void> _factoryReset(AppNotifier notifier) async {
    final keep = notifier.config;
    await ConfigService.reset();
    await SecurityService.resetAttempts();
    final fresh = AppConfig(
      deviceId: keep.deviceId,
      cloudUrl: keep.cloudUrl,
      cloudAnonKey: keep.cloudAnonKey,
      cloudToken: keep.cloudToken,
      cloudEnabled: keep.cloudEnabled,
    );
    await notifier.saveConfig(fresh);
  }
}
