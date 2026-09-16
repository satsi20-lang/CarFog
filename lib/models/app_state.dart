import 'package:flutter/material.dart';
import '../services/config_service.dart';

// Активное количество ароматов на этом конкретном аппарате: столько
// насосов (DO 0..kFlavorCount-1) и датчиков уровня (DI 0..kFlavorCount-1)
// реально распаяно и показывается покупателю. Хранилище (flavorNames,
// уровни канистр) и низкоуровневое железо всегда рассчитаны на полные
// 8 каналов DIO-модуля — так что для перехода на 6 или 8 ароматов
// достаточно поменять только это число, ничего больше трогать не нужно.
const int kFlavorCount = 4;

// ============================================================
// КОНФИГ (редактируется через сервисное меню)
// ============================================================

class AppConfig {
  int treatmentPriceCents;
  int treatmentDurationS;
  String servicePin;
  int compressorPurgeS;
  int pumpAfterHeaterS;
  String deviceId;
  String cloudUrl;
  String cloudAnonKey;
  String cloudToken;
  bool cloudEnabled;
  // Роль домашнего экрана (Шаг 32, задача 3) — по умолчанию выключена,
  // включается только тумблером "Киоск-режим" в сервисном меню, чтобы
  // свежая сборка на планшете разработчика не захватывала рабочий стол.
  bool kioskModeEnabled;

  // Платёжный терминал (клемма DI11 модуля MBSL16DI16DO = канал 10).
  // Форма сигнала не измерена заранее — отсюда настраиваемые режим и
  // защитная пауза вместо жёсткой логики, калибруются по журналу на
  // вкладке "Датчики" сервисного меню.
  int paymentTerminalChannel;
  // 'edge' — короткий импульс на каждую оплату, 'level' — вход
  // удерживается на время транзакции.
  String paymentTerminalMode;
  // Мс — защита от того, что дребезг контакта или длинный импульс
  // превратится в две оплаты подряд.
  int paymentTerminalGuardMs;
  // Пока мастер не установил терминал физически, приложение не должно
  // реагировать на этот вход вообще — по умолчанию выключено.
  bool paymentTerminalEnabled;

  Map<String, List<String>> flavorNames;

  AppConfig({
    this.treatmentPriceCents = 200,
    this.treatmentDurationS = 40,
    this.servicePin = '1234',
    this.compressorPurgeS = 5,
    this.pumpAfterHeaterS = 5,
    this.deviceId = 'CARFOG-001',
    this.cloudUrl = '',
    this.cloudAnonKey = '',
    this.cloudToken = '',
    this.cloudEnabled = false,
    this.kioskModeEnabled = false,
    this.paymentTerminalChannel = 10,
    this.paymentTerminalMode = 'edge',
    this.paymentTerminalGuardMs = 3000,
    this.paymentTerminalEnabled = false,
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

  AppConfig copyWith({
    int? treatmentPriceCents,
    int? treatmentDurationS,
    String? servicePin,
    int? compressorPurgeS,
    int? pumpAfterHeaterS,
    String? deviceId,
    String? cloudUrl,
    String? cloudAnonKey,
    String? cloudToken,
    bool? cloudEnabled,
    bool? kioskModeEnabled,
    int? paymentTerminalChannel,
    String? paymentTerminalMode,
    int? paymentTerminalGuardMs,
    bool? paymentTerminalEnabled,
    Map<String, List<String>>? flavorNames,
  }) {
    return AppConfig(
      treatmentPriceCents: treatmentPriceCents ?? this.treatmentPriceCents,
      treatmentDurationS: treatmentDurationS ?? this.treatmentDurationS,
      servicePin: servicePin ?? this.servicePin,
      compressorPurgeS: compressorPurgeS ?? this.compressorPurgeS,
      pumpAfterHeaterS: pumpAfterHeaterS ?? this.pumpAfterHeaterS,
      deviceId: deviceId ?? this.deviceId,
      cloudUrl: cloudUrl ?? this.cloudUrl,
      cloudAnonKey: cloudAnonKey ?? this.cloudAnonKey,
      cloudToken: cloudToken ?? this.cloudToken,
      cloudEnabled: cloudEnabled ?? this.cloudEnabled,
      kioskModeEnabled: kioskModeEnabled ?? this.kioskModeEnabled,
      paymentTerminalChannel:
          paymentTerminalChannel ?? this.paymentTerminalChannel,
      paymentTerminalMode: paymentTerminalMode ?? this.paymentTerminalMode,
      paymentTerminalGuardMs:
          paymentTerminalGuardMs ?? this.paymentTerminalGuardMs,
      paymentTerminalEnabled:
          paymentTerminalEnabled ?? this.paymentTerminalEnabled,
      flavorNames: flavorNames ?? this.flavorNames,
    );
  }

  // Слепок настроек для облака (Шаг 34) — только эксплуатационная часть,
  // то, что панель управления реально должна показывать оператору. При
  // добавлении нового поля в AppConfig решайте здесь же, входит ли оно
  // сюда: НИКОГДА не добавляйте servicePin (даёт физический доступ к
  // аппарату), cloudToken (это и есть ключ к самому облаку — отправлять
  // его обратно бессмысленно и опасно), cloudAnonKey, cloudUrl.
  Map<String, dynamic> reportedSnapshot() {
    return {
      'price_cents': treatmentPriceCents,
      'duration_s': treatmentDurationS,
      'compressor_purge_s': compressorPurgeS,
      'pump_after_heater_s': pumpAfterHeaterS,
      'flavor_count': kFlavorCount,
      'flavor_names_ru': flavorNames['ru']?.take(kFlavorCount).toList() ?? [],
      'kiosk_mode_enabled': kioskModeEnabled,
    };
  }
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

  // --- Код текущей ошибки (см. AppState.error) ---
  String? _errorCode;
  String? get errorCode => _errorCode;

  // --- Уровни канистр (8 штук, true = есть жидкость) ---
  List<bool> _levels = List.filled(8, true);
  List<bool> get levels => _levels;

  // --- Работоспособность шины (задача "не брать деньги, если шина
  // недоступна") --- По умолчанию false: пока StartupService ни разу не
  // подтвердил успешное выключение всех выходов при старте, аппарат не
  // должен считать себя работоспособным (та же логика, что и в самой
  // задаче о гарантированном выключении — железо, которым нельзя
  // управлять, не имеет права принимать деньги). Дальше поддерживается
  // StartupService (первый успех) и OutputWatchdogService (последующие
  // успехи/ошибки обмена в состояниях покоя).
  bool _busHealthy = false;
  bool get busHealthy => _busHealthy;

  void setBusHealthy(bool healthy) {
    if (_busHealthy == healthy) return;
    final was = _busHealthy;
    _busHealthy = healthy;
    // Связь восстановилась, пока клиент стоял на экране "аппарат не
    // работает" — возвращаемся в обычный режим сами, без перезапуска
    // (задача 4.5). Не трогаем других причин ошибки (перегрев и т.д.) —
    // только именно этот код.
    if (!was &&
        healthy &&
        _state == AppState.error &&
        _errorCode == 'bus_unavailable') {
      resetSession();
      return;
    }
    notifyListeners();
  }

  // ============================================================
  // ПЕРЕХОДЫ СОСТОЯНИЙ
  // ============================================================

  void transition(AppState newState) {
    debugPrint('STATE: $_state → $newState (lang=$_lang)');
    if (newState != AppState.error) _errorCode = null;
    _state = newState;
    notifyListeners();
  }

  void goToError(String code) {
    _errorCode = code;
    transition(AppState.error);
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
    // Не пускаем дальше выбора аромата, если шина недоступна (задача "не
    // брать деньги, если шина недоступна") — приём оплаты при потерянном
    // управлении оборудованием означает, что клиент заплатит и не получит
    // услугу.
    if (!_busHealthy) {
      goToError('bus_unavailable');
      return;
    }
    _selectedFlavor = index;
    transition(AppState.payment);
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
    _errorCode = null;
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

  Future<void> saveConfig(AppConfig newConfig) async {
    config = newConfig;
    notifyListeners();
    await ConfigService.save(newConfig);
  }
}
