import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/out_of_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/out_of_service_service.dart';

// Вывод аппарата из обслуживания (задача "вывод аппарата из
// обслуживания"): модель, чтение при старте (fail-closed), порядок "запись
// на диск → экран → облако", блокировка всех входов в оплату и снятие
// только после пробного цикла. Нативное хранилище подменяется
// обработчиком канала — само OutOfServiceStore проверяется Kotlin-тестами.
// Аппарат с обязательными устройствами, отмеченными установленными (иначе
// оплата блокируется конфигурацией — AppNotifier.isConfigBlocked).
AppNotifier readyNotifier() => AppNotifier()
  ..config = AppConfig(thermoInstalled: true, energyMeterInstalled: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.carfog.dryfog/system');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Содержимое "диска", вызовы и поведение подменяются в каждом тесте.
  Object? Function(MethodCall call)? handler;
  final calls = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    handler = null;
    ModbusService.paymentBlocked = false;
    OutOfServiceService.invalidateTrial();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return handler?.call(call);
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    ModbusService.paymentBlocked = false;
  });

  group('модель', () {
    test('круговая сериализация сохраняет код, время и подробности', () {
      final s = OutOfServiceState(
        code: OutOfServiceCode.heaterNoPower,
        since: DateTime.utc(2026, 10, 1, 12, 30),
        details: {'power_w': 12.5, 'voltage_v': 233.0},
      );
      final back = OutOfServiceState.tryParse(jsonDecode(jsonEncode(s.toJson())));
      expect(back, isNotNull);
      expect(back!.code, 'heater_no_power');
      expect(back.since, s.since);
      expect(back.details['power_w'], 12.5);
    });

    test('запись без кода/времени/неверных типов не разбирается (→ повреждена)', () {
      expect(OutOfServiceState.tryParse(null), isNull);
      expect(OutOfServiceState.tryParse('x'), isNull);
      expect(OutOfServiceState.tryParse({'code': '', 'since': '2026-10-01'}), isNull);
      expect(OutOfServiceState.tryParse({'code': 'a', 'since': 5}), isNull);
      expect(OutOfServiceState.tryParse({'code': 'a', 'since': 'не дата'}), isNull);
    });
  });

  group('чтение при старте (fail-closed)', () {
    test('записи нет совсем — рабочее состояние, это не ошибка', () async {
      handler = (_) => {'status': 'none', 'json': null};
      expect(await OutOfServiceService.restore(), isNull);
    });

    test('целая запись восстанавливается как есть', () async {
      final s = OutOfServiceState(
        code: OutOfServiceCode.tempSensorFault,
        since: DateTime.utc(2026, 10, 1),
        details: {'subtype': 'stale'},
      );
      handler = (_) => {'status': 'ok', 'json': jsonEncode(s.toJson())};
      final r = await OutOfServiceService.restore();
      expect(r?.code, 'temp_sensor_fault');
      expect(r?.details['subtype'], 'stale');
    });

    test('повреждённая запись — выведен, state_unreadable', () async {
      handler = (_) => {'status': 'corrupt', 'json': null};
      final r = await OutOfServiceService.restore();
      expect(r?.code, OutOfServiceCode.stateUnreadable);
    });

    test('исключение нативного канала — выведен, а не рабочий', () async {
      handler = (_) => throw PlatformException(code: 'IO', message: 'нет диска');
      final r = await OutOfServiceService.restore();
      expect(r?.code, OutOfServiceCode.stateUnreadable);
    });

    test('статус ok, но JSON мусорный — выведен', () async {
      handler = (_) => {'status': 'ok', 'json': '{не json'};
      expect((await OutOfServiceService.restore())?.code, 'state_unreadable');
    });

    test('статус ok, но JSON без обязательных полей — выведен', () async {
      handler = (_) => {'status': 'ok', 'json': '{"a":1}'};
      expect((await OutOfServiceService.restore())?.code, 'state_unreadable');
    });

    test('неизвестный статус — выведен', () async {
      handler = (_) => {'status': 'что-то', 'json': null};
      expect((await OutOfServiceService.restore())?.code, 'state_unreadable');
    });

    test('канал вернул null — выведен', () async {
      handler = (_) => null;
      expect((await OutOfServiceService.restore())?.code, 'state_unreadable');
    });
  });

  group('trip: порядок записи, экрана и облака', () {
    test('запись на диск подтверждена РАНЬШЕ, чем показан экран', () async {
      final notifier = readyNotifier();
      final order = <String>[];
      handler = (call) async {
        if (call.method == 'writeOutOfService') {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          order.add('write_confirmed');
          return true;
        }
        return null;
      };
      notifier.addListener(() {
        if (notifier.isOutOfService) order.add('screen');
      });

      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterNoPower,
        details: {'power_w': 11.0},
      );

      expect(order, ['write_confirmed', 'screen']);
      expect(notifier.state, AppState.outOfService);
      expect(ModbusService.paymentBlocked, isTrue);
    });

    test('отключение выходов идёт параллельно с записью, а не после неё', () async {
      final notifier = readyNotifier();
      final order = <String>[];
      handler = (call) async {
        if (call.method == 'writeOutOfService') {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          order.add('write_done');
          return true;
        }
        return null;
      };
      final shutdown = () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('outputs_off');
      }();
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.tempSensorFault,
        alongside: shutdown,
      );
      // выходы выключились раньше завершения долгой записи
      expect(order, ['outputs_off', 'write_done']);
    });

    test('запись не подтверждена — аппарат всё равно заблокирован в памяти', () async {
      final notifier = readyNotifier();
      handler = (call) => call.method == 'writeOutOfService' ? false : null;
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterNoPower,
      );
      expect(notifier.isOutOfService, isTrue);
      expect(ModbusService.paymentBlocked, isTrue);
      // попыток записи было несколько
      expect(calls.where((c) => c == 'writeOutOfService').length, greaterThan(1));
    });

    test('нативная запись бросает исключение — блокировка остаётся', () async {
      final notifier = readyNotifier();
      handler = (call) => call.method == 'writeOutOfService'
          ? throw PlatformException(code: 'IO')
          : null;
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterNoPower,
      );
      expect(notifier.isOutOfService, isTrue);
    });

    test('повторный отказ не затирает момент первого вывода', () async {
      final notifier = readyNotifier();
      handler = (call) => call.method == 'writeOutOfService' ? true : null;
      await OutOfServiceService.trip(notifier, code: OutOfServiceCode.heaterNoPower);
      final first = notifier.outOfService!.since;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await OutOfServiceService.trip(notifier, code: OutOfServiceCode.tempSensorFault);
      expect(notifier.outOfService!.since, first);
      expect(notifier.outOfService!.code, OutOfServiceCode.tempSensorFault);
      expect(notifier.outOfService!.details['previous_code'], 'heater_no_power');
    });

    test('showScreen=false: клиент сначала увидит экран ошибки', () async {
      final notifier = readyNotifier()..transition(AppState.preparing);
      handler = (call) => call.method == 'writeOutOfService' ? true : null;
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterNoPower,
        showScreen: false,
      );
      expect(notifier.isOutOfService, isTrue);
      expect(notifier.state, AppState.preparing); // экран не менялся
      notifier.goToError('heater_failure');
      expect(notifier.state, AppState.error); // объяснение клиенту доступно
      notifier.resetSession(); // таймер возврата с экрана ошибки
      expect(notifier.state, AppState.outOfService);
    });
  });

  group('все входы в оплату заблокированы', () {
    late AppNotifier notifier;

    setUp(() async {
      notifier = readyNotifier();
      handler = (call) => call.method == 'writeOutOfService' ? true : null;
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterNoPower,
      );
    });

    test('выбор аромата не ведёт на оплату', () {
      notifier.selectFlavor(0);
      expect(notifier.state, AppState.outOfService);
    });

    test('любая попытка уйти на оплату/прогрев/ожидание заворачивается', () {
      for (final s in [
        AppState.payment,
        AppState.preparing,
        AppState.compressorStartup,
        AppState.treating,
        AppState.shutdown,
        AppState.standby,
        AppState.selectFlavor,
        AppState.selectLanguage,
        AppState.finished,
      ]) {
        notifier.transition(s);
        expect(notifier.state, AppState.outOfService, reason: '$s');
      }
    });

    test('автовозврат "в ожидание" (resetSession) ведёт на экран "не работает"', () {
      notifier.resetSession();
      expect(notifier.state, AppState.outOfService);
    });

    test('техник доходит до PIN и сервисного меню, выход из меню — снова на "не работает"', () {
      notifier.transition(AppState.servicePinEntry);
      expect(notifier.state, AppState.servicePinEntry);
      notifier.transition(AppState.serviceMenu);
      expect(notifier.state, AppState.serviceMenu);
      notifier.transition(AppState.standby); // "Выход" из меню
      expect(notifier.state, AppState.outOfService);
    });

    test('платёжный сервис заблокирован независимо от экрана', () {
      expect(ModbusService.paymentBlocked, isTrue);
    });
  });

  group('снятие блокировки — только вручную и после пробного цикла', () {
    late AppNotifier notifier;

    setUp(() async {
      notifier = readyNotifier();
      handler = (call) {
        if (call.method == 'writeOutOfService') return true;
        if (call.method == 'clearOutOfService') return true;
        return null;
      };
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterNoPower,
      );
      calls.clear();
    });

    test('без пробного цикла снять нельзя, хранилище не трогается', () async {
      expect(await OutOfServiceService.clearByTechnician(notifier), isFalse);
      expect(notifier.isOutOfService, isTrue);
      expect(calls.contains('clearOutOfService'), isFalse);
    });

    test('после пройденного пробного цикла блокировка снимается', () async {
      OutOfServiceService.markTrialPassed();
      expect(await OutOfServiceService.clearByTechnician(notifier), isTrue);
      expect(notifier.isOutOfService, isFalse);
      expect(ModbusService.paymentBlocked, isFalse);
      expect(notifier.state, AppState.standby);
    });

    test('сама по себе блокировка пробным циклом не снимается (только разрешение)', () {
      OutOfServiceService.markTrialPassed();
      expect(notifier.isOutOfService, isTrue);
      expect(OutOfServiceService.trialPassedRecently, isTrue);
    });

    test('хранилище не удалило запись — блокировка остаётся (fail-closed)', () async {
      handler = (call) => call.method == 'clearOutOfService' ? false : true;
      OutOfServiceService.markTrialPassed();
      expect(await OutOfServiceService.clearByTechnician(notifier), isFalse);
      expect(notifier.isOutOfService, isTrue);
      expect(ModbusService.paymentBlocked, isTrue);
    });

    test('провал пробного цикла сбрасывает разрешение на снятие', () async {
      OutOfServiceService.markTrialPassed();
      await OutOfServiceService.recordTrialFailure(
        notifier,
        code: OutOfServiceCode.tempSensorFault,
        details: {'subtype': 'stale'},
      );
      expect(OutOfServiceService.trialPassedRecently, isFalse);
      expect(await OutOfServiceService.clearByTechnician(notifier), isFalse);
      // запись о причине обновлена
      expect(notifier.outOfService!.code, OutOfServiceCode.tempSensorFault);
      expect(notifier.outOfService!.details['subtype'], 'stale');
    });

    test('повторный вывод сбрасывает старое разрешение на снятие', () async {
      OutOfServiceService.markTrialPassed();
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterNoPower,
      );
      expect(OutOfServiceService.trialPassedRecently, isFalse);
    });
  });

  test('клиент в обычном состоянии: переходы не блокируются', () {
    final notifier = readyNotifier();
    notifier.transition(AppState.standby);
    expect(notifier.state, AppState.standby);
    notifier.transition(AppState.payment);
    expect(notifier.state, AppState.payment);
  });
}
