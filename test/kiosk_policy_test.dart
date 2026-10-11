// Киоск через Device Owner (device-owner-spike): разбор ответа нативной
// стороны и поведение без Device Owner.
import 'package:dry_fog_app/services/system_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.carfog.dryfog/system');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('KioskPolicyState.fromMap', () {
    test('null и пустой ответ — нет Device Owner', () {
      for (final m in [null, <String, Object?>{}]) {
        final st = KioskPolicyState.fromMap(m);
        expect(st.deviceOwner, isFalse);
        expect(st.lockEnabled, isFalse);
        expect(st.temporaryExit, isFalse);
      }
    });

    test('полный ответ', () {
      final st = KioskPolicyState.fromMap({
        'device_owner': true,
        'lock_enabled': true,
        'lock_task_active': false,
        'exit_remaining_ms': 125000,
      });
      expect(st.deviceOwner, isTrue);
      expect(st.lockEnabled, isTrue);
      expect(st.lockTaskActive, isFalse);
      expect(st.temporaryExit, isTrue);
      expect(st.exitRemaining, const Duration(milliseconds: 125000));
    });

    test('обратный отсчёт только при включённой блокировке', () {
      final off = KioskPolicyState.fromMap({
        'device_owner': true,
        'lock_enabled': false,
        'exit_remaining_ms': 60000,
      });
      expect(off.temporaryExit, isTrue);
      expect(off.showExitCountdown, isFalse);
      final on = KioskPolicyState.fromMap({
        'device_owner': true,
        'lock_enabled': true,
        'exit_remaining_ms': 60000,
      });
      expect(on.showExitCountdown, isTrue);
      final noExit = KioskPolicyState.fromMap({
        'device_owner': true,
        'lock_enabled': true,
      });
      expect(noExit.showExitCountdown, isFalse);
    });

    test('чужие типы не считаются истиной', () {
      final st = KioskPolicyState.fromMap({
        'device_owner': 'true',
        'lock_enabled': 1,
        'exit_remaining_ms': -5,
      });
      expect(st.deviceOwner, isFalse);
      expect(st.lockEnabled, isFalse);
      expect(st.exitRemaining, Duration.zero);
    });
  });

  group('канал', () {
    test('нет нативной реализации — состояние «нет Device Owner»', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw MissingPluginException();
      });
      final st = await SystemService.kioskPolicyState();
      expect(st.deviceOwner, isFalse);
    });

    test('действия передают аргументы и возвращают ответ', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return 'no_device_owner';
      });
      expect(await SystemService.kioskSetLockEnabled(true), 'no_device_owner');
      expect(
        await SystemService.kioskTemporaryExit(openSettings: true),
        'no_device_owner',
      );
      expect(await SystemService.kioskClearDeviceOwner(), 'no_device_owner');
      expect(calls.map((c) => c.method), [
        'kioskSetLockEnabled',
        'kioskTemporaryExit',
        'kioskClearDeviceOwner',
      ]);
      expect(calls[0].arguments, {'enabled': true});
      expect(calls[1].arguments, {'openSettings': true});
    });

    test('ошибка канала превращается в error:', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'x');
      });
      expect(await SystemService.kioskClearDeviceOwner(), startsWith('error:'));
    });
  });
}
