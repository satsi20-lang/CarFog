import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/bus_map.dart';
import 'package:dry_fog_app/models/device_spec.dart';
import 'package:dry_fog_app/models/hardware_profile.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/system_service.dart';

// Универсальная сборка: профиль выбирается при старте по реальному устройству
// (SY156-A510 или IXP101M1), от него зависят порт шины по умолчанию и
// hardware_profile в слепке для облака.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.carfog.dryfog/system');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    HardwareProfile.current = HardwareProfile.fallback;
    BusParams.resetPortForTest();
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('detect', () {
    test('Syoung по чипу rk3562', () {
      expect(
        HardwareProfile.detect(props: ['rk3562_t', 'rk3562_t', 'rk30board']),
        same(HardwareProfile.sy156a510),
      );
    });

    test('IXP101M1 по чипу rk3568 (регистр не важен)', () {
      expect(
        HardwareProfile.detect(props: ['RK3568_T', null, 'rk30board']),
        same(HardwareProfile.ixp101m1),
      );
    });

    test('чип не узнан — по длинной стороне экрана', () {
      expect(
        HardwareProfile.detect(props: ['x'], longSidePx: 1280),
        same(HardwareProfile.ixp101m1),
      );
      expect(
        HardwareProfile.detect(props: ['x'], longSidePx: 1920),
        same(HardwareProfile.sy156a510),
      );
    });

    test('чип важнее экрана', () {
      expect(
        HardwareProfile.detect(props: ['rk3562_t'], longSidePx: 1280),
        same(HardwareProfile.sy156a510),
      );
    });

    test('ничего не узнано — профиль по умолчанию SY156-A510', () {
      expect(HardwareProfile.detect(), same(HardwareProfile.fallback));
      expect(
        HardwareProfile.detect(props: ['generic'], longSidePx: 2400),
        same(HardwareProfile.sy156a510),
      );
    });

    test('byId', () {
      expect(HardwareProfile.byId('ixp101m1'), same(HardwareProfile.ixp101m1));
      expect(HardwareProfile.byId('ixp101m1-legacy'), isNull);
    });
  });

  group('канал', () {
    test('ответ нативной стороны → профиль IXP101M1', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getHardwareIdentity');
        return {
          'board': 'rk30sdk',
          'device': 'rk3568_t',
          'model': 'rk3568_t',
          'hardware': 'rk30board',
          'width_px': 800,
          'height_px': 1280,
        };
      });
      expect(
        await SystemService.detectHardwareProfile(),
        same(HardwareProfile.ixp101m1),
      );
    });

    test('ошибка канала → профиль по умолчанию', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'x');
      });
      expect(
        await SystemService.detectHardwareProfile(),
        same(HardwareProfile.fallback),
      );
    });
  });

  group('порт шины по профилю', () {
    test('порты по умолчанию допустимы политикой', () {
      for (final p in HardwareProfile.all) {
        expect(
          BusPortPolicy.check(p.defaultBusPort),
          BusPortCheck.ok,
          reason: p.id,
        );
      }
      expect(HardwareProfile.sy156a510.defaultBusPort, '/dev/ttyS4');
      expect(HardwareProfile.ixp101m1.defaultBusPort, '/dev/ttyS5');
    });

    test('IXP101M1: новая конфигурация берёт ttyS5', () {
      HardwareProfile.current = HardwareProfile.ixp101m1;
      BusParams.resetPortForTest();
      expect(AppConfig().busPort, '/dev/ttyS5');
      expect(BusParams.port, '/dev/ttyS5');
    });

    test('IXP101M1: старая конфигурация без busPort → ttyS5', () async {
      HardwareProfile.current = HardwareProfile.ixp101m1;
      SharedPreferences.setMockInitialValues({
        'app_config': jsonEncode({'treatmentPriceCents': 300}),
      });
      expect((await ConfigService.load()).busPort, '/dev/ttyS5');
    });

    test('IXP101M1: сохранённый порт важнее значения по умолчанию', () async {
      HardwareProfile.current = HardwareProfile.ixp101m1;
      SharedPreferences.setMockInitialValues({
        'app_config': jsonEncode({'busPort': '/dev/ttyS4'}),
      });
      expect((await ConfigService.load()).busPort, '/dev/ttyS4');
    });

    test('запрещённые узлы запрещены для обоих профилей', () async {
      for (final p in HardwareProfile.all) {
        HardwareProfile.current = p;
        for (final bad in BusPortPolicy.forbidden) {
          SharedPreferences.setMockInitialValues({
            'app_config': jsonEncode({'busPort': bad}),
          });
          expect(
            (await ConfigService.load()).busPort,
            p.defaultBusPort,
            reason: '${p.id} $bad',
          );
          expect(BusParams.applyConfigured(bad), isFalse);
        }
      }
    });
  });

  group('слепок для облака', () {
    test('hardware_profile — реальный профиль запуска', () {
      HardwareProfile.current = HardwareProfile.ixp101m1;
      expect(AppConfig().reportedSnapshot()['hardware_profile'], 'ixp101m1');
      HardwareProfile.current = HardwareProfile.sy156a510;
      expect(AppConfig().reportedSnapshot()['hardware_profile'], 'sy156-a510');
    });

    test('профиль спецификации по умолчанию не зависит от запуска', () {
      HardwareProfile.current = HardwareProfile.ixp101m1;
      expect(const DeviceSpec().hardwareProfile, 'sy156-a510');
    });
  });
}
