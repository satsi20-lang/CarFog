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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppNotifier(),
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
        // Убираем дубликат, оставляем один вариант
        return const Scaffold(
          body: Center(
            child: Text(
              'ЗАПУСК КОМПРЕССОРА...',
              style: TextStyle(color: Color(0xFFFFAA00), fontSize: 20),
            ),
          ),
        );
      case AppState.treating:
        return const TreatingScreen();
      case AppState.shutdown:
        return const TreatingScreen();
      default:
        return const Scaffold(
          body: Center(
            child: Text(
              'Экран в разработке...',
              style: TextStyle(color: Colors.white),
            ),
          ),
        );
    }
  }
}
