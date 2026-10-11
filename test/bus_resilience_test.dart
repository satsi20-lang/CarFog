import 'package:flutter/foundation.dart';
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
  late int detachCalls;

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
    detachCalls = 0;
    watchdog = BusWatchdogService(
      notifier,
      poll: () async => next,
      now: () => now,
      report: (data) async => reports.add(data),
      detach: () => detachCalls++,
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
    expect(
      reports.single['state'],
      'standby',
      reason: 'состояние до переключения на "не работает"',
    );
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

  test(
    'порт закрыт сознательно (сканер в сервисном меню) — не отказ шины',
    () async {
      final closed = BusHealth(
        owner: true,
        desired: false,
        open: false,
        failures: 0,
        successes: 100,
      );
      await tickAt(0, dead());
      await tickAt(30, closed);
      await tickAt(95, closed);
      expect(codes(), isEmpty);
      expect(notifier.isOutOfService, isFalse);
      // После сканера порт снова открыт, но молчит — отсчёт с нуля.
      await tickAt(98, dead());
      await tickAt(150, dead());
      expect(codes(), isEmpty);
      await tickAt(158, dead());
      expect(codes(), ['bus_down']);
    },
  );

  test('desired из нативного снимка', () {
    expect(
      BusHealth.fromMap({'owner': true, 'desired': false})!.desired,
      isFalse,
    );
    expect(
      BusHealth.fromMap({'owner': true, 'desired': true})!.desired,
      isTrue,
    );
  });

  test(
    'уходящий движок (не владелец порта) не выводит и не шлёт событий',
    () async {
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
    },
  );

  test(
    'не владелец два опроса подряд — опрос в движке останавливается один раз',
    () async {
      final foreign = BusHealth(
        owner: false,
        open: true,
        failures: 0,
        successes: 50,
      );
      await tickAt(0, foreign);
      expect(detachCalls, 0, reason: 'один опрос — может быть переходным');
      expect(watchdog.isDetached, isFalse);
      await tickAt(3, foreign);
      expect(detachCalls, 1);
      expect(watchdog.isDetached, isTrue);
      // Дальше — ни повторной остановки, ни событий, ни вывода.
      await tickAt(6, foreign);
      await tickAt(120, dead());
      expect(detachCalls, 1);
      expect(codes(), isEmpty);
      expect(notifier.isOutOfService, isFalse);
    },
  );

  test('один опрос без владения между нормальными — не остановка', () async {
    await tickAt(0, dead(failures: 0));
    await tickAt(
      3,
      BusHealth(owner: false, open: true, failures: 0, successes: 100),
    );
    await tickAt(6, dead(successes: 110, failures: 0));
    await tickAt(
      9,
      BusHealth(owner: false, open: true, failures: 0, successes: 110),
    );
    expect(detachCalls, 0);
    expect(watchdog.isDetached, isFalse);
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
      expect(reports.single['state'], 'treating');
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

  group('журнал ошибок опроса терминала (не чаще раза в 30 с)', () {
    test('серия: первая сразу, дальше раз в 30 с со счётчиком пропущенных', () {
      var t = DateTime(2026, 10, 11, 10, 33);
      final log = ThrottledErrorLog(now: () => t);
      expect(log.error('e'), 'e');
      for (var i = 0; i < 149; i++) {
        t = t.add(const Duration(milliseconds: 200));
        expect(log.error('e'), isNull);
      }
      t = DateTime(2026, 10, 11, 10, 33, 30);
      expect(log.error('e'), 'e (пропущено таких же: 149)');
      t = t.add(const Duration(seconds: 1));
      expect(log.error('e'), isNull);
    });

    test('после восстановления первая ошибка пишется сразу', () {
      var t = DateTime(2026, 10, 11, 10, 33);
      final log = ThrottledErrorLog(now: () => t);
      log.error('e');
      t = t.add(const Duration(seconds: 1));
      log.error('e');
      log.error('e');
      expect(log.success(), contains('не записано: 2'));
      expect(log.success(), isNull, reason: 'итог серии — один раз');
      t = t.add(const Duration(seconds: 1));
      expect(log.error('e'), 'e');
    });

    test(
      'pollTerminal: опрос не меняется, в журнал — одна строка на серию',
      () async {
        const channel = MethodChannel('com.carfog.dryfog/modbus');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        var calls = 0;
        var busDead = true;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls++;
          if (busDead) {
            throw PlatformException(
              code: 'MODBUS',
              message: 'pollTerminal failed',
            );
          }
          return {'state': false, 'confirmed': false};
        });
        final printed = <String>[];
        final oldPrint = debugPrint;
        debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');
        var t = DateTime(2026, 10, 11, 10, 33);
        final log = ModbusService.pollTerminalErrorLog
          ..reset()
          ..now = () => t;
        try {
          Future<TerminalPoll?> poll() => ModbusService.pollTerminal(
            channel: 10,
            mode: 'level',
            guardMs: 0,
          );
          for (var i = 0; i < 50; i++) {
            expect(await poll(), isNull);
            t = t.add(const Duration(milliseconds: 200));
          }
          expect(calls, 50, reason: 'каждый опрос доходит до канала');
          expect(
            printed.where((l) => l.contains('pollTerminal error')).length,
            1,
          );

          busDead = false;
          expect(await poll(), isNotNull);
          expect(printed.last, contains('не записано: 49'));
          busDead = true;
          await poll();
          expect(printed.last, contains('pollTerminal error'));
        } finally {
          debugPrint = oldPrint;
          log
            ..reset()
            ..now = DateTime.now;
          messenger.setMockMethodCallHandler(channel, null);
        }
      },
    );
  });
}
