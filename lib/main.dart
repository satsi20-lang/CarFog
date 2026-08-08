import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'models/app_state.dart';
import 'screens/language_select.dart';
import 'screens/standby.dart';
import 'screens/select_flavor.dart';
import 'screens/payment.dart';
import 'screens/preparing.dart';
import 'screens/treating.dart';
import 'screens/finished.dart';
import 'screens/error.dart';
import 'screens/service/service_pin.dart';
import 'screens/service/service_menu.dart';
import 'services/cloud_service.dart';
import 'services/config_service.dart';
import 'services/modbus_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  final config = await ConfigService.load();

  // Облачный слой. Транспорт выбирается по сохранённым настройкам —
  // если облако не настроено/выключено, работает локальный лог.
  CloudService.configure(
    deviceId: config.deviceId,
    enabled: config.cloudEnabled,
    url: config.cloudUrl,
    anonKey: config.cloudAnonKey,
    token: config.cloudToken,
  );
  unawaited(CloudService.report(CloudEventType.appStarted));

  // Безопасное выключение всего при старте — не блокирует показ UI,
  // если железо ещё не подключено или порт не совпал.
  unawaited(() async {
    await ModbusService.open(); // порт уточнить после find_port.py
    await ModbusService.safeAllOff();
  }());

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppNotifier()..config = config,
      child: const DryFogApp(),
    ),
  );
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
    final state = context.watch<AppNotifier>().state;
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
    }
  }
}
