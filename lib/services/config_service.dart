import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../models/bus_map.dart';
import '../models/device_spec.dart';
import '../models/hardware_profile.dart';

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
    return parsed ?? const DeviceSpec();
  }

  static AppConfig _fromJson(Map<String, dynamic> j) => AppConfig(
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
        BusPortPolicy.check((j['busPort'] as String?) ?? '') == BusPortCheck.ok
        ? j['busPort'] as String
        : HardwareProfile.defaultBusPort,
    specPumps: _specFromJson(j).pumps,
    specLangs: _specFromJson(j).langs,
    specDefaultLang: _specFromJson(j).defaultLang,
    flavorNames: (j['flavorNames'] as Map<String, dynamic>?)?.map(
      (k, v) => MapEntry(k, List<String>.from(v)),
    ),
  );
}
