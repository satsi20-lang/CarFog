import 'package:flutter/material.dart';
import '../services/config_service.dart';
import '../services/modbus_service.dart';
import 'bus_map.dart';
import 'out_of_service.dart';

// Активное количество ароматов на этом конкретном аппарате: столько
// насосов (PumpChannel.do_ 0..kFlavorCount-1, bus_map.dart) и датчиков
// уровня (PumpChannel.sensorDI 0..kFlavorCount-1) реально распаяно и
// показывается покупателю. Хранилище (flavorNames, уровни канистр) и
// низкоуровневое железо всегда рассчитаны на полный PumpChannel.values —
// так что для перехода на 6 или 8 ароматов достаточно поменять только это
// число, ничего больше трогать не нужно.
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

  // Платёжный терминал — см. IoModuleInputs.defaultPaymentTerminalDI
  // (bus_map.dart) для дефолта и истории решения по номеру канала.
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

  // Сторож выходов (задача "сторож выходов", шаг 37) — по умолчанию
  // ВКЛЮЧЁН (доработка 03.10.2026): подтверждён живыми тестами, штатная
  // защита. Уже сохранённое явное значение не перезаписывается.
  bool outputWatchdogEnabled;

  // "Установлено" — по каждому устройству на шине отдельно (задача "убрать
  // бесполезный опрос отсутствующих устройств"), карта адресов и признаков
  // — bus_map.dart (BusDevice.isInstalled читает именно эти поля).
  // Выключенный признак останавливает информационный опрос этого
  // устройства целиком — не просто прячет ошибку в UI, а не даёт
  // транзакции вообще уйти на шину. Сейчас реально на шине только модуль
  // ввода-вывода; термопара временно снята, счётчик и монетоприёмник ещё
  // не смонтированы — отсюда дефолты. paymentTerminalEnabled выше — тот
  // же по смыслу признак для терминала, отдельное поле под него не
  // заводим.
  bool dioInstalled;
  bool thermoInstalled;
  bool energyMeterInstalled;
  bool coinAcceptorInstalled;

  // Тариф на электроэнергию, €/кВт·ч — редактируется в сервисном меню,
  // используется только для справочной строки "стоимость простоя за
  // сутки" (задача "контроль цикла по электросчётчику", фаза 2, часть 3).
  // Не аналитика: PowerSignature.idleW (~15 Вт) даёт около 11 кВт·ч в
  // месяц, это пара евро — цифра для оператора, не для ценообразования.
  double idlePowerTariffPerKwh;

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
    this.paymentTerminalChannel = IoModuleInputs.defaultPaymentTerminalDI,
    this.paymentTerminalMode = 'edge',
    this.paymentTerminalGuardMs = 3000,
    this.paymentTerminalEnabled = false,
    // Включён по умолчанию (доработка после проверки 73acfe3, п.4): на
    // боевом аппарате сторож — штатная защита, а не диагностика. Уже
    // сохранённое явное значение не перезаписывается.
    this.outputWatchdogEnabled = true,
    this.dioInstalled = true,
    this.thermoInstalled = false,
    this.energyMeterInstalled = false,
    this.coinAcceptorInstalled = false,
    this.idlePowerTariffPerKwh = 0.20,
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
    bool? outputWatchdogEnabled,
    bool? dioInstalled,
    bool? thermoInstalled,
    bool? energyMeterInstalled,
    bool? coinAcceptorInstalled,
    double? idlePowerTariffPerKwh,
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
      outputWatchdogEnabled:
          outputWatchdogEnabled ?? this.outputWatchdogEnabled,
      dioInstalled: dioInstalled ?? this.dioInstalled,
      thermoInstalled: thermoInstalled ?? this.thermoInstalled,
      energyMeterInstalled: energyMeterInstalled ?? this.energyMeterInstalled,
      coinAcceptorInstalled:
          coinAcceptorInstalled ?? this.coinAcceptorInstalled,
      idlePowerTariffPerKwh:
          idlePowerTariffPerKwh ?? this.idlePowerTariffPerKwh,
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
  // Аппарат выведен из обслуживания (задача "вывод аппарата из
  // обслуживания"): сюда уходит всё, пока признак не снят вручную.
  outOfService,
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

  // --- Выведен из обслуживания (задача "вывод аппарата из обслуживания") ---
  // null — аппарат работает. Выставляется ТОЛЬКО из OutOfServiceService
  // (после подтверждённой записи на диск) и при старте приложения из
  // main.dart, снимается только вручную на месте.
  OutOfServiceState? _outOfService;
  OutOfServiceState? get outOfService => _outOfService;
  bool get isOutOfService => _outOfService != null;

  // --- Обязательные устройства (доработка после проверки коммита 73acfe3,
  // п.3) --- Для платной работы термопара и счётчик энергии должны быть
  // отмечены установленными: без термопары прогрев нечем контролировать
  // (клиент заплатил бы, а цикл кончился бы ошибкой), без счётчика молча
  // пропадают проверка мощности ТЭНа, энергетический бюджет и проверка
  // выключения ТЭНа по мощности. Это СОСТОЯНИЕ КОНФИГУРАЦИИ, а не отказ:
  // в постоянный признак вывода из обслуживания не пишется и пропадает
  // сразу после включения флагов в сервисном меню.
  List<String> get missingRequiredDevices => [
    if (!config.thermoInstalled) 'thermocouple',
    if (!config.energyMeterInstalled) 'energy_meter',
  ];
  bool get isConfigBlocked => missingRequiredDevices.isNotEmpty;
  bool get isPaymentBlocked => isOutOfService || isConfigBlocked;

  // Платёжный сервис блокируется и по признаку отказа, и по конфигурации;
  // вызывается при любом изменении того и другого.
  void refreshPaymentBlock() {
    ModbusService.paymentBlocked = isPaymentBlocked;
    // Флаги включили, пока клиент стоял на экране "не работает" без
    // постоянного признака — возвращаемся в ожидание.
    if (!isPaymentBlocked && _state == AppState.outOfService) {
      _state = AppState.standby;
    }
  }

  // Пока признак стоит, достижимы только экраны, которые не принимают
  // деньги: сам экран "не работает", PIN/сервисное меню (техник) и экран
  // ошибки (клиенту, чья оплата уже прошла к моменту отказа, нужно
  // объяснить про возврат; он сам возвращается на экран "не работает" по
  // таймеру).
  static bool _allowedWhileOutOfService(AppState s) {
    switch (s) {
      case AppState.outOfService:
      case AppState.servicePinEntry:
      case AppState.serviceMenu:
      case AppState.error:
        return true;
      default:
        return false;
    }
  }

  // Выставить признак. showScreen=false — вызывающий сам сразу покажет
  // экран ошибки клиенту (preparing/treating после отказа), экран "не
  // работает" появится после него по таймеру возврата.
  void enterOutOfService(OutOfServiceState state, {bool showScreen = true}) {
    _outOfService = state;
    refreshPaymentBlock();
    _selectedFlavor = null;
    if (showScreen && _state != AppState.servicePinEntry && _state != AppState.serviceMenu) {
      _errorCode = null;
      _state = AppState.outOfService;
    }
    notifyListeners();
  }

  // Обновить запись (повторный отказ, в том числе на пробном цикле) без
  // смены экрана.
  void updateOutOfService(OutOfServiceState state) {
    _outOfService = state;
    notifyListeners();
  }

  // Снятие признака. Вызывать только из OutOfServiceService.clearByTechnician
  // (после подтверждённого удаления записи и успешного пробного цикла).
  void leaveOutOfService() {
    _outOfService = null;
    refreshPaymentBlock();
    if (_state == AppState.outOfService) {
      _state = AppState.standby;
    }
    notifyListeners();
  }

  // Порт занят другим процессом (задача "эксклюзивное открытие
  // последовательного порта") — техническая деталь ПОЧЕМУ шина недоступна,
  // отдельно от самого busHealthy. Не показывается клиенту (экран ошибки
  // остаётся на общем 'bus_unavailable' без технических подробностей) —
  // только технику, на вкладке Диагностика. null, если порт занят не был
  // либо шина уже восстановилась.
  String? _busBusyPort;
  int? _busBusyPid;
  String? get busBusyPort => _busBusyPort;
  int? get busBusyPid => _busBusyPid;

  void setBusBusyInfo(String port, int? pid) {
    _busBusyPort = port;
    _busBusyPid = pid;
    notifyListeners();
  }

  void setBusHealthy(bool healthy) {
    if (_busHealthy == healthy) return;
    final was = _busHealthy;
    _busHealthy = healthy;
    if (healthy) {
      _busBusyPort = null;
      _busBusyPid = null;
    }
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
    // Единая точка входа во все экраны: пока аппарат выведен из
    // обслуживания, любая попытка уйти на оплату/прогрев/ожидание
    // (таймеры, автовозврат по неактивности, выбор аромата, отладочные
    // переключатели) заворачивается на экран "не работает".
    if (_outOfService != null && !_allowedWhileOutOfService(newState)) {
      newState = AppState.outOfService;
    }
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
    if (_outOfService != null) {
      transition(AppState.outOfService);
      return;
    }
    // Обязательные устройства не отмечены установленными — до оплаты
    // показывается "временно не работает" (см. missingRequiredDevices).
    if (isConfigBlocked) {
      refreshPaymentBlock();
      transition(AppState.outOfService);
      return;
    }
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
    // В режиме "выведен из обслуживания" возврат "в ожидание" ведёт на экран
    // "не работает", а не на заставку, принимающую оплату.
    _state = isPaymentBlocked ? AppState.outOfService : AppState.standby;
    notifyListeners();
  }

  // ============================================================
  // КОНФИГ
  // ============================================================

  void updateConfig(AppConfig newConfig) {
    config = newConfig;
    refreshPaymentBlock();
    notifyListeners();
  }

  Future<void> saveConfig(AppConfig newConfig) async {
    config = newConfig;
    refreshPaymentBlock();
    notifyListeners();
    await ConfigService.save(newConfig);
  }
}
