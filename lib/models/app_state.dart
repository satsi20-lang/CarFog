import 'package:flutter/material.dart';

// ============================================================
// КОНФИГ (редактируется через сервисное меню)
// ============================================================

class AppConfig {
  double servicePriceEur;
  int treatmentDurationS;
  Map<String, List<String>> flavorNames;

  AppConfig({
    this.servicePriceEur = 5.0,
    this.treatmentDurationS = 40,
    Map<String, List<String>>? flavorNames,
  }) : flavorNames =
           flavorNames ??
           {
             'ru': [
               'Лимон',
               'Вишня',
               'Хвоя',
               'Лаванда',
               'Океан',
               'Кофе',
               'Ваниль',
               'Мята',
             ],
             'en': [
               'Lemon',
               'Cherry',
               'Pine',
               'Lavender',
               'Ocean',
               'Coffee',
               'Vanilla',
               'Mint',
             ],
             'et': [
               'Sidrun',
               'Kirss',
               'Mänd',
               'Lavendel',
               'Ookean',
               'Kohv',
               'Vanilje',
               'Münt',
             ],
           };
}

// ============================================================
// STATE-МАШИНА — все состояния приложения
// ============================================================

enum AppState {
  selectLanguage,
  standby,
  selectFlavor,
  payment,
  preparing, // нагрев ТЭН (0→100% по температуре)
  compressorStartup, // компрессор ВКЛ, пауза 5 сек
  treating, // насос ВКЛ, обработка 40 сек
  shutdown, // насос+ТЭН ВЫКЛ, компрессор продувает 5 сек
  finished,
  error,
  servicePinEntry,
  serviceMenu,
}

// ============================================================
// NOTIFIER — централизованное состояние приложения
// ============================================================

class AppNotifier extends ChangeNotifier {
  // --- Конфиг ---
  AppConfig config = AppConfig();

  // --- Текущее состояние ---
  AppState _state = AppState.selectLanguage;
  AppState get state => _state;

  // --- Язык ---
  String _lang = 'ru';
  String get lang => _lang;

  // --- Выбранный аромат (0-7) ---
  int? _selectedFlavor;
  int? get selectedFlavor => _selectedFlavor;

  // --- Оплата ---
  double _amountPaid = 0.0;
  double get amountPaid => _amountPaid;

  // --- Уровни канистр (8 штук, true = есть жидкость) ---
  List<bool> _levels = List.filled(8, true);
  List<bool> get levels => _levels;

  // ============================================================
  // ПЕРЕХОДЫ СОСТОЯНИЙ
  // ============================================================

  void transition(AppState newState) {
    debugPrint('STATE: $_state → $newState (lang=$_lang)');
    _state = newState;
    notifyListeners();
  }

  // ============================================================
  // ЯЗЫК
  // ============================================================

  void setLanguage(String lang) {
    _lang = lang;
    notifyListeners();
  }

  // ============================================================
  // ВЫБОР АРОМАТА
  // ============================================================

  void selectFlavor(int index) {
    _selectedFlavor = index;
    transition(AppState.payment);
  }

  // ============================================================
  // ОПЛАТА
  // ============================================================

  void addPayment(double amount) {
    _amountPaid += amount;
    notifyListeners();
  }

  void resetPayment() {
    _amountPaid = 0.0;
    notifyListeners();
  }

  // ============================================================
  // УРОВНИ КАНИСТР
  // ============================================================

  void updateLevels(List<bool> levels) {
    _levels = levels;
    notifyListeners();
  }

  // ============================================================
  // СБРОС СЕССИИ (возврат в STANDBY)
  // ============================================================

  void resetSession() {
    _selectedFlavor = null;
    _amountPaid = 0.0;
    _state = AppState.standby;
    notifyListeners();
  }

  // ============================================================
  // КОНФИГ
  // ============================================================

  void updateConfig(AppConfig newConfig) {
    config = newConfig;
    notifyListeners();
  }
}
