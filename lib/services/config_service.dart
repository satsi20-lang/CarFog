import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';

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
        'flavorNames': c.flavorNames,
      };

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
        flavorNames: (j['flavorNames'] as Map<String, dynamic>?)?.map(
          (k, v) => MapEntry(k, List<String>.from(v)),
        ),
      );
}
