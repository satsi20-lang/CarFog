import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../models/bus_map.dart';
import '../models/device_spec.dart';
import '../models/hardware_profile.dart';
import 'app_log_service.dart';

class ConfigService {
  static const _key = 'app_config';

  // Загрузить конфиг с диска. Если нет — вернуть дефолтный.
  static Future<AppConfig> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_key);
      if (json == null) return AppConfig();
      return _fromJson(jsonDecode(json));
    } catch (e) {
      debugPrint('ConfigService.load error: $e');
      return AppConfig();
    }
  }

  // Сохранить конфиг на диск.
  static Future<void> save(AppConfig config) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_toJson(config)));
    } catch (e) {
      debugPrint('ConfigService.save error: $e');
    }
  }

  // Сбросить к заводским настройкам.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Map<String, dynamic> _toJson(AppConfig c) => {
    'treatmentPriceCents': c.treatmentPriceCents,
    'treatmentDurationS': c.treatmentDurationS,
    'servicePin': c.servicePin,
    'compressorPurgeS': c.compressorPurgeS,
    'pumpAfterHeaterS': c.pumpAfterHeaterS,
    'deviceId': c.deviceId,
    'cloudUrl': c.cloudUrl,
    'cloudAnonKey': c.cloudAnonKey,
    'cloudToken': c.cloudToken,
    'cloudEnabled': c.cloudEnabled,
    'kioskModeEnabled': c.kioskModeEnabled,
    'paymentTerminalChannel': c.paymentTerminalChannel,
    'paymentTerminalMode': c.paymentTerminalMode,
    'paymentTerminalGuardMs': c.paymentTerminalGuardMs,
    'paymentTerminalEnabled': c.paymentTerminalEnabled,
    'outputWatchdogEnabled': c.outputWatchdogEnabled,
    'dioInstalled': c.dioInstalled,
    'thermoInstalled': c.thermoInstalled,
    'energyMeterInstalled': c.energyMeterInstalled,
    'coinAcceptorInstalled': c.coinAcceptorInstalled,
    'idlePowerTariffPerKwh': c.idlePowerTariffPerKwh,
    'busPort': c.busPort,
    'specPumps': c.specPumps,
    'specLangs': c.specLangs,
    'specDefaultLang': c.specDefaultLang,
    'flavorNames': c.flavorNames,
  };

  // Сохранённая спецификация: неполная или неверная (старый JSON без полей,
  // мусор) заменяется значениями по умолчанию целиком.
  static DeviceSpec _specFromJson(Map<String, dynamic> j) {
    final langs = j['specLangs'];
    final parsed = DeviceSpec.tryParse({
      'pumps': ?j['specPumps'],
      'langs': ?langs,
      'default_lang': ?j['specDefaultLang'],
    });
    if (parsed == null) {
      // Неверная сохранённая спецификация (например 9 насосов при максимуме 8):
      // значения по умолчанию, одна строка в журнал (без секретов).
      AppLog.log(
        'Spec',
        'сохранённая спецификация неверна, использованы значения по умолчанию',
      );
    }
    return parsed ?? const DeviceSpec();
  }

  // Нейтральные названия ароматов 5…8, которыми дополняются старые настройки с
  // меньшим числом названий (существующие названия и порядок не меняются).
  static const Map<String, String> _neutralPrefix = {
    'ru': 'Аромат',
    'en': 'Flavor',
    'et': 'Aroma',
  };

  // Список названий рассчитан на все 8 каналов: недостающие добавляются
  // нейтральными; лишние и существующие не трогаются. Названия, которые
  // оказались неактивными (число насосов уменьшили), остаются в хранилище.
  static Map<String, List<String>>? padFlavorNames(
    Map<String, List<String>>? names,
  ) {
    if (names == null) return null;
    final out = <String, List<String>>{};
    names.forEach((lang, list) {
      final prefix = _neutralPrefix[lang] ?? 'Flavor';
      final padded = List<String>.from(list);
      for (var i = padded.length; i < PumpChannel.values.length; i++) {
        padded.add('$prefix ${i + 1}');
      }
      out[lang] = padded;
    });
    return out;
  }

  static AppConfig _fromJson(Map<String, dynamic> j) {
    final spec = _specFromJson(j);
    return AppConfig(
      treatmentPriceCents: (j['treatmentPriceCents'] as int?) ?? 200,
      treatmentDurationS: (j['treatmentDurationS'] as int?) ?? 40,
      servicePin: (j['servicePin'] as String?) ?? '1234',
      compressorPurgeS: (j['compressorPurgeS'] as int?) ?? 5,
      pumpAfterHeaterS: (j['pumpAfterHeaterS'] as int?) ?? 5,
      deviceId: (j['deviceId'] as String?) ?? 'CARFOG-001',
      cloudUrl: (j['cloudUrl'] as String?) ?? '',
      cloudAnonKey: (j['cloudAnonKey'] as String?) ?? '',
      cloudToken: (j['cloudToken'] as String?) ?? '',
      cloudEnabled: (j['cloudEnabled'] as bool?) ?? false,
      kioskModeEnabled: (j['kioskModeEnabled'] as bool?) ?? false,
      paymentTerminalChannel:
          (j['paymentTerminalChannel'] as int?) ??
          IoModuleInputs.defaultPaymentTerminalDI,
      paymentTerminalMode: (j['paymentTerminalMode'] as String?) ?? 'edge',
      paymentTerminalGuardMs: (j['paymentTerminalGuardMs'] as int?) ?? 3000,
      paymentTerminalEnabled: (j['paymentTerminalEnabled'] as bool?) ?? false,
      outputWatchdogEnabled: (j['outputWatchdogEnabled'] as bool?) ?? true,
      dioInstalled: (j['dioInstalled'] as bool?) ?? true,
      thermoInstalled: (j['thermoInstalled'] as bool?) ?? false,
      energyMeterInstalled: (j['energyMeterInstalled'] as bool?) ?? false,
      coinAcceptorInstalled: (j['coinAcceptorInstalled'] as bool?) ?? false,
      idlePowerTariffPerKwh:
          (j['idlePowerTariffPerKwh'] as num?)?.toDouble() ?? 0.20,
      // Сохранённое недопустимое/запрещённое значение не применяется.
      busPort:
          BusPortPolicy.check((j['busPort'] as String?) ?? '') ==
              BusPortCheck.ok
          ? j['busPort'] as String
          : HardwareProfile.defaultBusPort,
      specPumps: spec.pumps,
      specLangs: spec.langs,
      specDefaultLang: spec.defaultLang,
      flavorNames: padFlavorNames(
        (j['flavorNames'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, List<String>.from(v)),
        ),
      ),
    );
  }
}
