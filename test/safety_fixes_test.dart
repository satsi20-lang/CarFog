import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/bus_map.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';

// Правки по замечаниям ревью: выключение ТЭНа с подтверждением и очередь
// облака, не теряющая события, добавленные во время отправки.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.carfog.dryfog/modbus');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  List<bool> coils({required bool heater}) =>
      List.generate(12, (i) => i == AuxOutput.heaterDO ? heater : false);

  group('forceHeaterOff', () {
    test('подтверждено чтением катушки с первой попытки', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c.method);
        if (c.method == 'readCoils') return coils(heater: false);
        return true;
      });
      expect(await ModbusService.forceHeaterOff(), isTrue);
      expect(calls, ['setDO', 'readCoils']);
    });

    test('неудачная запись повторяется, пока катушка не погаснет', () async {
      var writes = 0;
      messenger.setMockMethodCallHandler(channel, (c) async {
        if (c.method == 'setDO') {
          writes++;
          return false; // запись не прошла
        }
        if (c.method == 'readCoils') return coils(heater: writes < 3);
        return true;
      });
      expect(
        await ModbusService.forceHeaterOff(pause: Duration.zero),
        isTrue,
      );
      expect(writes, 3);
    });

    test('катушка остаётся включённой → не подтверждено, safeAllOff пробуется',
        () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (c) async {
        calls.add(c.method);
        if (c.method == 'readCoils') return coils(heater: true);
        return true;
      });
      expect(
        await ModbusService.forceHeaterOff(pause: Duration.zero),
        isFalse,
      );
      expect(calls.where((m) => m == 'safeAllOff'), isNotEmpty);
    });

    test('чтение не удалось, но запись подтверждена дважды → принимается',
        () async {
      messenger.setMockMethodCallHandler(channel, (c) async {
        if (c.method == 'readCoils') throw PlatformException(code: 'MODBUS');
        return true;
      });
      expect(
        await ModbusService.forceHeaterOff(pause: Duration.zero),
        isTrue,
      );
    });

    test('ни запись, ни чтение не проходят → не подтверждено', () async {
      messenger.setMockMethodCallHandler(channel, (c) async {
        if (c.method == 'readCoils') throw PlatformException(code: 'MODBUS');
        return false;
      });
      expect(
        await ModbusService.forceHeaterOff(pause: Duration.zero),
        isFalse,
      );
    });
  });

  group('очередь облака', () {
    test('события, добавленные во время отправки, не теряются', () async {
      SharedPreferences.setMockInitialValues({});
      final sent = <String>[];
      final transport = _SlowTransport(sent);
      CloudService.transport = transport;
      addTearDown(() => CloudService.transport = LocalLogTransport());

      await CloudService.report('first');
      // flush из report не ждётся — дожидаемся, пока первая отправка начнётся
      await transport.started.future;
      await CloudService.report('second'); // добавлено ВО ВРЕМЯ отправки
      transport.release.complete();
      await transport.done.future;
      // дать второй порции уйти
      for (var i = 0; i < 20 && sent.length < 2; i++) {
        await Future.delayed(const Duration(milliseconds: 10));
      }

      expect(sent, ['first', 'second']);
      expect(await CloudService.pendingCount(), 0);
    });
  });
}

class _SlowTransport implements CloudTransport {
  final List<String> sent;
  final started = Completer<void>();
  final release = Completer<void>();
  final done = Completer<void>();
  var _first = true;
  _SlowTransport(this.sent);

  @override
  Future<bool> send(String deviceId, List<CloudEvent> events) async {
    if (_first) {
      _first = false;
      started.complete();
      await release.future;
    }
    sent.addAll(events.map((e) => e.type));
    if (!done.isCompleted) done.complete();
    return true;
  }

  @override
  Future<CloudPollResult> fetchCommands(String deviceId,
          {Map<String, dynamic>? config}) async =>
      CloudPollResult(commands: const []);

  @override
  Future<bool> ackCommand(
          String deviceId, String commandId, bool ok, String? result) async =>
      true;
}
