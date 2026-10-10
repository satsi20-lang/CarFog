import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/out_of_service.dart';
import 'package:dry_fog_app/services/bus_watchdog_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/out_of_service_service.dart';

// Устойчивость шины (1.10.3), сторона Dart: события переоткрытия, bus_down
// через существующий механизм вывода из обслуживания (временной причиной)
// и автоматическое восстановление. Само переоткрытие и владение портом
// проверяются Kotlin-тестами (BusPortRegistryTest, BusWatchdogTest).
AppNotifier readyNotifier() =>
    AppNotifier()
      ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppNotifier notifier;
  late DateTime now;
  late BusHealth? next;
  late List<Map<String, dynamic>> reports;
  late BusWatchdogService watchdog;

  BusHealth dead({int successes = 100, int failures = 4, bool open = true}) =>
      BusHealth(
        owner: true,
        open: open,
        failures: failures,
        successes: successes,
      );

  Future<void> tickAt(int seconds, BusHealth? h) async {
    now = DateTime(2026, 10, 10, 21, 48).add(Duration(seconds: seconds));
    next = h;
    await watchdog.tick();
  }

  List<String> codes() => [for (final r in reports) r['code'] as String];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ModbusService.paymentBlocked = false;
    notifier = readyNotifier()..transition(AppState.standby);
    reports = [];
    next = null;
    watchdog = BusWatchdogService(
      notifier,
      poll: () async => next,
      now: () => now,
      report: (data) async => reports.add(data),
    );
  });

  tearDown(() => ModbusService.paymentBlocked = false);

  test('снимок с нативной стороны разбирается', () {
    final h = BusHealth.fromMap({
      'owner': true,
      'open': false,
      'failures': 3,
      'successes': 12,
      'reopens': 1,
      'events': [
        {
          'at': 1,
          'ok': false,
          'attempt': 1,
          'result': 'failed',
          'port': '/dev/ttyS4',
        },
      ],
    })!;
    expect(h.owner, isTrue);
    expect(h.open, isFalse);
    expect(h.failures, 3);
    expect(h.successes, 12);
    expect(h.events.single['result'], 'failed');
    expect(BusHealth.fromMap(null), isNull);
  });

  test('ModbusService.busHealth — метод канала busHealth', () async {
    const channel = MethodChannel('com.carfog.dryfog/modbus');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return {'owner': true, 'open': true, 'failures': 0, 'successes': 5};
    });
    final h = BusHealth.fromMap(await ModbusService.busHealth());
    messenger.setMockMethodCallHandler(channel, null);
    expect(calls, ['busHealth']);
    expect(h!.successes, 5);
  });

  test('события переоткрытия уходят в облако как bus_reopened', () async {
    await tickAt(
      0,
      BusHealth(
        owner: true,
        open: true,
        failures: 0,
        successes: 10,
        reopens: 1,
        events: [
          {
            'at': 1,
            'ok': true,
            'attempt': 1,
            'result': 'ok',
            'port': '/dev/ttyS4',
          },
        ],
      ),
    );
    expect(codes(), ['bus_reopened']);
    expect(reports.single['ok'], isTrue);
    expect(reports.single['attempt'], 1);
  });

  test('шина молчит дольше 60 с → bus_down и экран "не работает"', () async {
    await tickAt(0, dead());
    await tickAt(30, dead());
    await tickAt(57, dead());
    expect(codes(), isEmpty);
    expect(notifier.isOutOfService, isFalse);

    await tickAt(60, dead());
    expect(codes(), ['bus_down']);
    expect(reports.single['down_s'], 60);
    expect(reports.single['out_of_service'], isTrue);
    expect(reports.single['screen_shown'], isTrue);
    expect(notifier.outOfService!.code, OutOfServiceCode.busDown);
    expect(notifier.state, AppState.outOfService);
    expect(notifier.isPaymentBlocked, isTrue);
    expect(ModbusService.paymentBlocked, isTrue);

    // Повторно не сообщается.
    await tickAt(63, dead());
    expect(codes(), ['bus_down']);
  });

  test('порт не открыт — тоже отказ шины', () async {
    await tickAt(0, dead(open: false, failures: 0));
    await tickAt(61, dead(open: false, failures: 0));
    expect(codes(), ['bus_down']);
  });

  test('ответы вернулись → bus_recovered, признак снимается сам', () async {
    await tickAt(0, dead());
    await tickAt(61, dead());
    expect(notifier.state, AppState.outOfService);

    await tickAt(64, dead(successes: 101, failures: 0));
    expect(codes(), ['bus_down', 'bus_recovered']);
    expect(reports.last['out_of_service_cleared'], isTrue);
    expect(notifier.isOutOfService, isFalse);
    expect(notifier.state, AppState.standby);
    expect(ModbusService.paymentBlocked, isFalse);
  });

  test('короткий сбой (< 60 с) не выводит и не шлёт событий', () async {
    await tickAt(0, dead());
    await tickAt(40, dead());
    await tickAt(43, dead(successes: 150, failures: 0));
    await tickAt(90, dead(successes: 150));
    expect(codes(), isEmpty, reason: 'отсчёт начался заново с t=90');
  });

  test(
    'успехи вперемешку с ошибками (нет необязательного устройства) — шина жива',
    () async {
      await tickAt(0, dead(successes: 10, failures: 2));
      for (var t = 3; t <= 120; t += 3) {
        await tickAt(t, dead(successes: 10 + t, failures: 2));
      }
      expect(codes(), isEmpty);
    },
  );

  test('без обмена между опросами состояние не меняется', () async {
    await tickAt(0, dead());
    // failures == 0 и successes не растёт: обмена не было (например, сразу
    // после переоткрытия) — отсчёт отказа не сбрасывается.
    await tickAt(30, dead(failures: 0));
    await tickAt(61, dead());
    expect(codes(), ['bus_down']);
  });

  test('уходящий движок (не владелец порта) ничего не делает', () async {
    final foreign = BusHealth(
      owner: false,
      open: false,
      failures: 9,
      successes: 0,
    );
    await tickAt(0, foreign);
    await tickAt(120, foreign);
    expect(codes(), isEmpty);
    expect(notifier.isOutOfService, isFalse);
  });

  test(
    'во время обработки экран не переключается, но оплата блокируется',
    () async {
      notifier.transition(AppState.treating);
      await tickAt(0, dead());
      await tickAt(61, dead());
      expect(notifier.outOfService!.code, OutOfServiceCode.busDown);
      expect(notifier.state, AppState.treating);
      expect(reports.single['out_of_service'], isTrue);
      expect(reports.single['screen_shown'], isFalse);
      // Завершение цикла приводит на экран "не работает".
      notifier.resetSession();
      expect(notifier.state, AppState.outOfService);
    },
  );

  test(
    'постоянный вывод не подменяется и не снимается сторожем шины',
    () async {
      final persistent = OutOfServiceState(
        code: OutOfServiceCode.overheat,
        since: DateTime(2026, 10, 10, 20),
      );
      notifier.enterOutOfService(persistent);
      await tickAt(0, dead());
      await tickAt(61, dead());
      expect(notifier.outOfService!.code, OutOfServiceCode.overheat);
      expect(reports.single['out_of_service'], isFalse);

      await tickAt(64, dead(successes: 200, failures: 0));
      expect(notifier.outOfService!.code, OutOfServiceCode.overheat);
      expect(reports.last['out_of_service_cleared'], isFalse);
    },
  );

  test(
    'постоянный отказ поверх bus_down: время вывода — с момента отказа',
    () async {
      const channel = MethodChannel('com.carfog.dryfog/system');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => true);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      OutOfServiceService.enterTransient(
        notifier,
        code: OutOfServiceCode.busDown,
      );
      final transientSince = notifier.outOfService!.since;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.outputStuckOn,
      );
      final s = notifier.outOfService!;
      expect(s.code, OutOfServiceCode.outputStuckOn);
      expect(s.since.isAfter(transientSince), isTrue);
      expect(s.details['previous_code'], OutOfServiceCode.busDown);
      // Временное снятие постоянный вывод не трогает.
      expect(
        OutOfServiceService.leaveTransient(
          notifier,
          code: OutOfServiceCode.busDown,
        ),
        isFalse,
      );
      expect(notifier.isOutOfService, isTrue);
    },
  );

  test('bus_down не пишется на диск', () async {
    const channel = MethodChannel('com.carfog.dryfog/system');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await tickAt(0, dead());
    await tickAt(61, dead());
    expect(notifier.outOfService!.details['transient'], isTrue);
    expect(calls, isNot(contains('writeOutOfService')));
  });
}
