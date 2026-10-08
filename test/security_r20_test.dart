import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/screens/service/service_pin.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/master_code_service.dart';
import 'package:dry_fog_app/services/pin_policy.dart';
import 'package:dry_fog_app/services/remote_commands.dart';
import 'package:dry_fog_app/services/security_service.dart';

// R2.0, п. A/B: мастер-код на каждый аппарат (хэш с солью, показ один раз,
// общая блокировка), политика PIN и принудительная смена.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudService.resetQueueForTest();
  });

  // Прежний общий мастер-код считается скомпрометированным. Собран из
  // частей, чтобы значение не лежало в репозитории одной строкой.
  final oldCompromisedCode = '4821${'7390'}';

  group('хэш мастер-кода', () {
    test('PBKDF2-HMAC-SHA256: контрольные векторы', () {
      String hex(List<int> b) =>
          b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
      // RFC 7914 §11 / общепринятые векторы PBKDF2-HMAC-SHA256
      expect(
        hex(MasterCodeService.pbkdf2('password', 'salt'.codeUnits, 1)),
        '120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b',
      );
      expect(
        hex(MasterCodeService.pbkdf2('password', 'salt'.codeUnits, 2)),
        'ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43',
      );
    });

    test('код — 8 цифр, в хранилище только хэш и соль, самого кода нет', () async {
      final code = await MasterCodeService.generateNew();
      expect(code, matches(RegExp(r'^\d{8}$')));
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getKeys().map((k) => '$k=${prefs.get(k)}').join('\n');
      expect(stored, isNot(contains(code)));
      expect(prefs.getString('master_code_hash'), hasLength(64)); // 32 байта hex
      expect(prefs.getString('master_code_salt'), hasLength(32)); // 16 байт hex
    });

    test('верный код проходит, неверный нет, пустой/нет кода — нет', () async {
      expect(await MasterCodeService.verify('12345678'), isFalse); // кода ещё нет
      final code = await MasterCodeService.generateNew(random: Random(7));
      expect(await MasterCodeService.verify(code), isTrue);
      expect(await MasterCodeService.verify('00000000'), isFalse);
      expect(await MasterCodeService.verify(''), isFalse);
    });

    test('соль индивидуальная: два кода/две соли различаются', () async {
      final rnd = Random(3);
      await MasterCodeService.generateNew(random: rnd);
      final prefs = await SharedPreferences.getInstance();
      final salt1 = prefs.getString('master_code_salt');
      final hash1 = prefs.getString('master_code_hash');
      await MasterCodeService.generateNew(random: rnd);
      expect(prefs.getString('master_code_salt'), isNot(salt1));
      expect(prefs.getString('master_code_hash'), isNot(hash1));
    });

    test('смена: прежний код перестаёт действовать, флаг «записан» сбрасывается', () async {
      final first = await MasterCodeService.generateNew(random: Random(1));
      await MasterCodeService.markAcknowledged();
      expect(await MasterCodeService.isAcknowledged(), isTrue);
      final second = await MasterCodeService.generateNew(random: Random(2));
      expect(second, isNot(first));
      expect(await MasterCodeService.verify(first), isFalse);
      expect(await MasterCodeService.verify(second), isTrue);
      expect(await MasterCodeService.isAcknowledged(), isFalse);
    });

    test('прежний общий код больше ничего не открывает', () async {
      await MasterCodeService.generateNew(random: Random(11));
      expect(await MasterCodeService.verify(oldCompromisedCode), isFalse);
      expect(await SecurityService.tryMaster(oldCompromisedCode), PinResult.wrong);
    });

    test('сравнение за постоянное время: корректность на границах', () {
      expect(MasterCodeService.constantTimeEquals([1, 2, 3], [1, 2, 3]), isTrue);
      expect(MasterCodeService.constantTimeEquals([1, 2, 3], [1, 2, 4]), isFalse);
      expect(MasterCodeService.constantTimeEquals([1, 2, 3], [1, 2]), isFalse);
      expect(MasterCodeService.constantTimeEquals([], []), isTrue);
    });
  });

  group('блокировка при вводе мастер-кода', () {
    test('3 неверных → блокировка; верный код при блокировке не проходит', () async {
      final code = await MasterCodeService.generateNew(random: Random(5));
      expect(await SecurityService.tryMaster('11111111'), PinResult.wrong);
      expect(await SecurityService.tryMaster('22222222'), PinResult.wrong);
      expect(await SecurityService.tryMaster('33333333'), PinResult.locked);
      expect(await SecurityService.isLocked(), isTrue);
      expect(await SecurityService.tryMaster(code), PinResult.locked);
      // блокировка общая: PIN тоже не принимается
      expect(await SecurityService.tryPin('7351', '7351'), PinResult.locked);
    });

    test('неверный мастер-код расходует те же попытки, что и PIN', () async {
      final code = await MasterCodeService.generateNew(random: Random(6));
      await SecurityService.tryPin('0000', '7351'); // 1
      await SecurityService.tryMaster('99999999'); // 2
      expect(await SecurityService.attemptsLeft(), 1);
      expect(await SecurityService.tryMaster(code), PinResult.ok); // 3-я попытка верная
      expect(await SecurityService.attemptsLeft(), SecurityService.maxAttempts);
    });

    test('успешный ввод фиксируется событием master_code_used', () async {
      final code = await MasterCodeService.generateNew(random: Random(8));
      await SecurityService.tryMaster(code);
      final events = await CloudService.history();
      expect(events.where((e) => e.type == CloudEventType.masterCodeUsed), isNotEmpty);
    });
  });

  group('политика PIN', () {
    test('слабые PIN отклоняются', () {
      for (final p in [
        '1234', '4321', '0000', '1111', '7777', '9999', // одинаковые и подряд
        '0123', '3210', '7890', '9876', '2345', '6789', // подряд (в т.ч. через 9→0)
        '1212', '2121', '1122', '2211', '5656', // повторяющиеся пары
        '2580', '0852', '1357', '2468', // шаблоны клавиатуры
      ]) {
        expect(PinPolicy.isWeak(p), isTrue, reason: p);
      }
    });

    test('нормальные PIN принимаются', () {
      for (final p in ['7351', '2846', '9035', '1579', '8264', '4072']) {
        expect(PinPolicy.isWeak(p), isFalse, reason: p);
      }
    });

    test('неверный формат — тоже отказ', () {
      for (final p in ['', '12', '12345', 'abcd', '12a4', ' 123']) {
        expect(PinPolicy.weakReason(p), 'format', reason: p);
      }
    });
  });

  // -------------------------------------------- принудительная смена
  group('экран PIN: принудительная смена', () {
    // Экран PIN — портретный (SY156-A510, 720x1280 dp): тест в том же размере.
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.implicitView!;
    setUp(() {
      view.devicePixelRatio = 1.5;
      view.physicalSize = const Size(1080, 1920);
    });
    tearDown(() {
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    Future<void> settle(WidgetTester t) async {
      for (var i = 0; i < 10; i++) {
        await t.runAsync(() => Future.delayed(const Duration(milliseconds: 40)));
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> enter(WidgetTester t, String digits) async {
      for (final d in digits.split('')) {
        await t.tap(find.text(d));
        await t.pump(const Duration(milliseconds: 30));
      }
      await settle(t);
    }

    Future<AppNotifier> open(WidgetTester t) async {
      final n = AppNotifier()..transition(AppState.servicePinEntry);
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: n,
          child: const MaterialApp(home: ServicePinScreen()),
        ),
      );
      await settle(t);
      return n;
    }

    testWidgets('вход с 1234 требует новый PIN; слабый не принимается; после смены — меню',
        (t) async {
      final n = await open(t);
      expect(n.config.servicePin, '1234');
      await enter(t, '1234');
      expect(n.state, AppState.servicePinEntry); // в меню НЕ пустило
      expect(find.text('Новый PIN'), findsOneWidget);
      await enter(t, '1111'); // слабый — отказ
      expect(n.config.servicePin, '1234');
      expect(find.text('Новый PIN'), findsOneWidget);
      await enter(t, '7351');
      expect(find.text('Повторите PIN'), findsOneWidget);
      await enter(t, '7352'); // не совпал — снова с начала
      expect(n.config.servicePin, '1234');
      expect(find.text('Новый PIN'), findsOneWidget);
      await enter(t, '7351');
      await enter(t, '7351');
      expect(n.config.servicePin, '7351');
      expect(n.state, AppState.serviceMenu);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('нормальный PIN сразу открывает меню без принудительной смены', (t) async {
      final n = AppNotifier()
        ..config = AppConfig(servicePin: '7351')
        ..transition(AppState.servicePinEntry);
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: n,
          child: const MaterialApp(home: ServicePinScreen()),
        ),
      );
      await settle(t);
      await enter(t, '7351');
      expect(n.state, AppState.serviceMenu);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('мастер-код открывает только смену PIN; прежний код не открывает ничего', (t) async {
      final code = (await t.runAsync(() => MasterCodeService.generateNew(random: Random(21))))!;
      final n = AppNotifier()
        ..config = AppConfig(servicePin: '7351')
        ..transition(AppState.servicePinEntry);
      await t.pumpWidget(
        ChangeNotifierProvider.value(
          value: n,
          child: const MaterialApp(home: ServicePinScreen()),
        ),
      );
      await settle(t);
      await t.tap(find.text('Аварийный доступ'));
      await settle(t);
      await enter(t, oldCompromisedCode); // прежний — отказ
      expect(find.text('Аварийный код'), findsOneWidget);
      expect(n.state, AppState.servicePinEntry);
      await enter(t, code); // свой — только смена PIN
      expect(find.text('Новый PIN'), findsOneWidget);
      expect(n.state, AppState.servicePinEntry);
      await enter(t, '8264');
      await enter(t, '8264');
      expect(n.config.servicePin, '8264');
      expect(n.state, AppState.serviceMenu);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('factory_reset и мастер-код', () {
    Future<AppNotifier> reset() async {
      final n = AppNotifier()
        ..config = AppConfig(
          thermoInstalled: true,
          energyMeterInstalled: false,
          servicePin: '7351',
          deviceId: 'D1',
        )
        ..transition(AppState.standby);
      final o = await RemoteCommands.handle(
        CloudCommand(id: 'fr', action: 'factory_reset', createdAt: DateTime.now()),
        n,
      );
      expect(o.ok, isTrue, reason: o.result);
      return n;
    }

    test('сброс НЕ стирает хэш и признак: код остаётся своим, «известного» нет', () async {
      final code = await MasterCodeService.generateNew();
      await MasterCodeService.markAcknowledged();
      final prefs = await SharedPreferences.getInstance();
      final hash = prefs.getString('master_code_hash');
      await reset();
      expect(await MasterCodeService.hasCode(), isTrue);
      expect(await MasterCodeService.isAcknowledged(), isTrue);
      expect((await SharedPreferences.getInstance()).getString('master_code_hash'), hash);
      expect(await MasterCodeService.verify(code), isTrue);
      expect(await MasterCodeService.verify(oldCompromisedCode), isFalse);
    });

    test('сброс при непоказанном коде: признак остаётся false (меню покажет код)', () async {
      await MasterCodeService.generateNew(); // ack=false
      await reset();
      expect(await MasterCodeService.isAcknowledged(), isFalse);
    });

    test('сброс без кода: код не появляется сам, прежний общий не принимается', () async {
      await reset();
      expect(await MasterCodeService.hasCode(), isFalse);
      expect(await MasterCodeService.verify(oldCompromisedCode), isFalse);
      expect(await MasterCodeService.verify('12345678'), isFalse);
    });

    test('после сброса PIN начальный (слабый): вход потребует смены', () async {
      final n = await reset();
      expect(PinPolicy.isWeak(n.config.servicePin), isTrue);
    });
  });
}
