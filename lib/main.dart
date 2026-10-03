import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'dart:io';
import 'models/app_state.dart';
import 'services/app_log_service.dart';
import 'screens/language_select.dart';
import 'screens/standby.dart';
import 'screens/select_flavor.dart';
import 'screens/payment.dart';
import 'screens/preparing.dart';
import 'screens/treating.dart';
import 'screens/finished.dart';
import 'screens/error.dart';
import 'screens/out_of_service.dart';
import 'screens/service/service_pin.dart';
import 'screens/service/service_menu.dart';
import 'services/cloud_service.dart';
import 'services/config_service.dart';
import 'services/level_service.dart';
import 'services/modbus_service.dart';
import 'services/out_of_service_service.dart';
import 'services/output_watchdog_service.dart';
import 'services/startup_service.dart';
import 'services/sync_service.dart';
import 'services/system_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Причина запуска читается ОДИН раз (нативная сторона сбрасывает признак
  // аварии) и используется и в отметке журнала, и в событии app_started.
  SystemService.init();
  final startReason = await SystemService.consumeStartReason();
  // Постоянный журнал — самым первым: всё дальнейшее (включая ошибки
  // старта) уже попадает в файл. Не блокирует запуск при сбое каталога.
  final logDir = await SystemService.getFilesDir();
  if (logDir != null) {
    await AppLog.init(
      dir: Directory(logDir),
      reason: startReason,
      version: CloudService.appVersion,
    );
  }
  AppLog.install();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // Планшет физически установлен в альбомной ориентации — весь UI
  // спроектирован под неё (см. переделанные экраны).
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  final config = await ConfigService.load();
  // Секреты из настроек не должны попасть в журнал и пакет диагностики.
  AppLog.setSecrets([config.servicePin, config.cloudToken, config.cloudAnonKey]);

  final notifier = AppNotifier()..config = config;
  // Блок оплаты по конфигурации (термопара/счётчик не отмечены) — до первого
  // экрана.
  notifier.refreshPaymentBlock();
  notifier.addListener(() {
    final c = notifier.config;
    AppLog.setSecrets([c.servicePin, c.cloudToken, c.cloudAnonKey]);
  });

  // Вывод аппарата из обслуживания (задача "вывод аппарата из
  // обслуживания", требования 2-5): состояние восстанавливается ДО runApp —
  // раньше, чем экран станет доступен клиенту, иначе скачок напряжения
  // снимал бы блокировку. Fail-closed: хранилище не читается или запись
  // повреждена → аппарат выведен (state_unreadable); чистое первое
  // включение (записи нет совсем) — рабочее состояние.
  final restoredOutOfService = await OutOfServiceService.restore();
  if (restoredOutOfService != null) {
    notifier.enterOutOfService(restoredOutOfService);
  }

  // Облачный слой. Транспорт выбирается по сохранённым настройкам —
  // если облако не настроено/выключено, работает локальный лог.
  CloudService.configure(
    deviceId: config.deviceId,
    enabled: config.cloudEnabled,
    url: config.cloudUrl,
    anonKey: config.cloudAnonKey,
    token: config.cloudToken,
  );

  // Оператор должен узнать об этом раньше клиентов — событие уходит сразу
  // (при отсутствии связи ляжет в обычную очередь).
  if (restoredOutOfService != null) {
    unawaited(OutOfServiceService.reportRestored(restoredOutOfService));
  }

  SyncService.start(notifier);
  LevelService.start(notifier);

  // Роль домашнего экрана НЕ синхронизируется здесь с AppConfig при каждом
  // запуске — раньше так и было, но это создавало реальную гонку: при
  // старте приложение поднимает отдельный движок Flutter на КАЖДЫЙ запуск
  // активности (обычный, через роль Home, после перезагрузки), и если
  // второй движок успевал прочитать AppConfig раньше, чем первый успевал
  // сохранить только что включённый тумблер на диск, "подстраховка" здесь
  // тут же откатывала PackageManager обратно — киоск-режим самопроизвольно
  // выключался через несколько секунд после включения (проверено вживую).
  // Единственное место, которое должно менять состояние роли Home —
  // сам тумблер в сервисном меню (_KioskTab._onToggle).

  // Причина запуска — обычный / после аварии / после перезагрузки (Шаг 32,
  // задача 6). Отдельный тип события для аварии, чтобы он подсвечивался
  // тревожным в журнале и в веб-панели без разбора вложенных полей.
  // launchDiagnostics (задача "приложение остаётся в фоне при холодном
  // старте") добавлен к обоим типам события — по нему в облачной панели
  // видно, каким путём поднялась именно эта активность (intent action,
  // категории, была ли она корнем задачи), без подключения к планшету.
  unawaited(() async {
    final reason = startReason;
    final launchDiagnostics = await SystemService.getLaunchDiagnostics();
    if (reason == 'crash') {
      await CloudService.report(
        CloudEventType.appStartedAfterCrash,
        data: {'probable_cause': 'software_crash', ...launchDiagnostics},
      );
    } else {
      await CloudService.report(
        CloudEventType.appStarted,
        data: {
          if (reason == 'boot') ...{
            'reason': 'boot',
            'probable_cause': await _detectBootCause(notifier),
          },
          ...launchDiagnostics,
        },
      );
    }
  }());

  // Безопасное выключение всего при старте — не блокирует показ UI, но
  // теперь ПОВТОРЯЕТСЯ, пока не подтвердится результат (задача
  // "гарантированное выключение при старте") — раньше это была одна
  // попытка без проверки, и на холодном старте, пока шина ещё не готова,
  // выключение молча не происходило. См. StartupService.
  unawaited(StartupService.ensureSafeStartup(notifier));

  // Сторож выходов (задача "сторож выходов") — следит за фактическим
  // состоянием выходов в состояниях покоя и гасит всё, если модуль поднял
  // что-то сам.
  OutputWatchdogService.start(notifier);

  runApp(
    ChangeNotifierProvider.value(value: notifier, child: const DryFogApp()),
  );
}

// Причина перезапуска. Признак 'crash' ставит только обработчик падения
// процесса (DryFogApplication) — если он сработал, это ТОЧНО падение софта
// ('software_crash'), гадать не нужно. При пропадании питания обработчик не
// успевает ничего поставить: аппарат просто загружается заново (причина
// 'boot'), поэтому прежняя ветка "power_loss внутри события об аварии"
// никогда не могла быть верной, а сравнение с отметкой "после последней
// сессии" и порог 0.001 кВт·ч (меньше шага счётчика 0.01) ничего не
// доказывали. Теперь для 'boot' — честное "перезагрузка устройства", с
// пометкой, отвечал ли счётчик энергии (если нет — вероятно, питание узла
// шкафа пропадало, а не только перезагрузился планшет).
Future<String> _detectBootCause(AppNotifier notifier) async {
  if (!notifier.config.energyMeterInstalled) return 'device_restart';
  const attempts = 3;
  const retryDelay = Duration(seconds: 2);
  for (var i = 0; i < attempts; i++) {
    if (await ModbusService.readEnergy() != null) return 'device_restart';
    await Future.delayed(retryDelay);
  }
  return 'device_restart_meter_unreachable';
}

class DryFogApp extends StatelessWidget {
  const DryFogApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CaRFog — Сухой туман',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFF1A1A1A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF2EC4B6),
          surface: Color(0xFF1A1A1A),
        ),
      ),
      home: const AppRouter(),
    );
  }
}

class AppRouter extends StatelessWidget {
  const AppRouter({super.key});

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final state = notifier.state;
    // Второй рубеж защиты (первый — AppNotifier.transition): пока аппарат
    // выведен из обслуживания, показывается только экран "не работает",
    // какое бы состояние ни стояло. Исключения — PIN/сервисное меню
    // (техник) и экран ошибки (объяснение клиенту, чья оплата уже прошла к
    // моменту отказа; сам возвращается на экран "не работает").
    if (notifier.isOutOfService &&
        state != AppState.outOfService &&
        state != AppState.servicePinEntry &&
        state != AppState.serviceMenu &&
        state != AppState.error) {
      return const OutOfServiceScreen();
    }
    // Платные экраны при блоке по конфигурации (термопара/счётчик не
    // отмечены установленными) — тоже только "не работает"; заставка и
    // выбор языка остаются.
    if (notifier.isConfigBlocked &&
        (state == AppState.selectFlavor || state == AppState.payment)) {
      return const OutOfServiceScreen();
    }
    switch (state) {
      case AppState.selectLanguage:
        return const LanguageSelectScreen();
      case AppState.standby:
        return const StandbyScreen();
      case AppState.selectFlavor:
        return const SelectFlavorScreen();
      case AppState.payment:
        return const PaymentScreen();
      case AppState.preparing:
        return const PreparingScreen();
      case AppState.compressorStartup:
        return const TreatingScreen();
      case AppState.treating:
        return const TreatingScreen();
      case AppState.shutdown:
        return const TreatingScreen();
      case AppState.finished:
        return const FinishedScreen();
      case AppState.error:
        return const ErrorScreen();
      case AppState.servicePinEntry:
        return const ServicePinScreen();
      case AppState.serviceMenu:
        return const ServiceMenuScreen();
      case AppState.outOfService:
        return const OutOfServiceScreen();
    }
  }
}
