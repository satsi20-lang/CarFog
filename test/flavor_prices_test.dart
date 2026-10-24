import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/remote_limits.dart';
import 'package:dry_fog_app/screens/select_flavor.dart';
import 'package:dry_fog_app/screens/service/service_menu.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/modbus_service.dart';
import 'package:dry_fog_app/services/remote_commands.dart';

// Цены по запахам, тип терминала и окно возврата картой (1.11.0, этап 1 ТЗ
// оплаты картой): миграция старых настроек, сохранение для отката,
// update_config, правило pulse, цена на экране выбора.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const system = MethodChannel('com.carfog.dryfog/system');
  const storage = MethodChannel('com.carfog.dryfog/storage');
  const modbus = MethodChannel('com.carfog.dryfog/modbus');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLog.resetForTest();
    CloudService.resetQueueForTest();
    ModbusService.paymentBlocked = false;
    for (final c in [system, storage, modbus]) {
      messenger.setMockMethodCallHandler(c, (call) async => null);
    }
  });
  tearDown(() {
    for (final c in [system, storage, modbus]) {
      messenger.setMockMethodCallHandler(c, null);
    }
  });

  Future<AppConfig> loadFrom(Map<String, dynamic> json) async {
    SharedPreferences.setMockInitialValues({'app_config': jsonEncode(json)});
    return ConfigService.load();
  }

  group('миграция старых настроек', () {
    for (final name in ['app_config_1_7_0.json', 'app_config_1_8_0.json']) {
      test('$name: все цены = прежняя цена, pulse из прежнего флага', () async {
        final raw = File('test/fixtures/$name').readAsStringSync().trim();
        SharedPreferences.setMockInitialValues({'app_config': raw});
        final c = await ConfigService.load();
        final old = jsonDecode(raw) as Map<String, dynamic>;
        expect(c.treatmentPriceCents, old['treatmentPriceCents']);
        expect(c.flavorPricesCents, List.filled(8, old['treatmentPriceCents']));
        expect(
          c.paymentTerminalType,
          old['paymentTerminalEnabled'] == true
              ? PaymentTerminalType.pulse
              : PaymentTerminalType.off,
        );
        expect(c.cardRefundWindowS, 30);
        expect(c.cardConfirmEnabled, isTrue);
      });
    }

    test('без прежнего флага — терминал выключен', () async {
      final c = await loadFrom({'treatmentPriceCents': 250});
      expect(c.paymentTerminalType, PaymentTerminalType.off);
      expect(c.flavorPricesCents, List.filled(8, 250));
    });

    test('мусор: позиции вне пределов → цена по умолчанию, окно вне 10–38 → 30', () async {
      final c = await loadFrom({
        'treatmentPriceCents': 300,
        'flavorPricesCents': [250, 'x', 49, 2001, 500],
        'paymentTerminalType': 'nfc',
        'paymentTerminalEnabled': true,
        'cardRefundWindowS': 39,
      });
      expect(c.flavorPricesCents, [250, 300, 300, 300, 500, 300, 300, 300]);
      expect(c.paymentTerminalType, PaymentTerminalType.pulse);
      expect(c.cardRefundWindowS, 30);
      final c2 = await loadFrom({'cardRefundWindowS': 9});
      expect(c2.cardRefundWindowS, 30);
      final c3 = await loadFrom({'cardRefundWindowS': '20'});
      expect(c3.cardRefundWindowS, 30);
    });
  });

  group('сохранение', () {
    test('сохранение–загрузка: цены, тип mdb, окно, служебный флаг', () async {
      final c = AppConfig(
        treatmentPriceCents: 200,
        flavorPricesCents: [150, 200, 250, 300, 350, 400, 450, 500],
        paymentTerminalType: PaymentTerminalType.mdb,
        cardRefundWindowS: 25,
        cardConfirmEnabled: false,
      );
      await ConfigService.save(c);
      final back = await ConfigService.load();
      expect(back.flavorPricesCents, [150, 200, 250, 300, 350, 400, 450, 500]);
      expect(back.paymentTerminalType, PaymentTerminalType.mdb);
      expect(back.cardRefundWindowS, 25);
      expect(back.cardConfirmEnabled, isFalse);
    });

    test('для отката пишутся прежние поля: флаг = pulse, цена по умолчанию', () async {
      for (final (type, flag) in [
        (PaymentTerminalType.pulse, true),
        (PaymentTerminalType.mdb, false),
        (PaymentTerminalType.off, false),
      ]) {
        await ConfigService.save(
          AppConfig(treatmentPriceCents: 300, paymentTerminalType: type),
        );
        final prefs = await SharedPreferences.getInstance();
        final j = jsonDecode(prefs.getString('app_config')!) as Map<String, dynamic>;
        expect(j['paymentTerminalEnabled'], flag, reason: type);
        expect(j['treatmentPriceCents'], 300);
      }
    });
  });

  group('модель', () {
    test('смена цены по умолчанию не перезаписывает цены запахов', () {
      final c = AppConfig(flavorPricesCents: [150, 250, 350, 450]);
      final c2 = c.copyWith(treatmentPriceCents: 900);
      expect(c2.treatmentPriceCents, 900);
      expect(c2.flavorPricesCents.take(4), [150, 250, 350, 450]);
      // недостающие позиции при создании — цена по умолчанию (200)
      expect(c2.flavorPricesCents.skip(4), [200, 200, 200, 200]);
    });

    test('цена выбранного запаха', () {
      final c = AppConfig(flavorPricesCents: [150, 250, 350, 450]);
      expect(c.priceForFlavor(1), 250);
      expect(c.priceForFlavor(99), c.treatmentPriceCents);
    });

    test('прежний флаг в copyWith: true → pulse, false → off', () {
      final c = AppConfig(paymentTerminalType: PaymentTerminalType.mdb);
      expect(c.copyWith(paymentTerminalEnabled: true).paymentTerminalType, 'pulse');
      expect(c.copyWith(paymentTerminalEnabled: false).paymentTerminalType, 'off');
      expect(c.copyWith(cardRefundWindowS: 20).paymentTerminalType, 'mdb');
      expect(c.paymentTerminalEnabled, isFalse, reason: 'mdb — не импульсный');
    });

    test('pulse: разные цены активных запахов — конфликт, неактивные не считаются', () {
      final pulse = AppConfig(paymentTerminalType: PaymentTerminalType.pulse, specPumps: 4);
      expect(pulse.copyWith(flavorPricesCents: [200, 200, 200, 200, 900]).pulsePricesConflict, isFalse);
      expect(pulse.copyWith(flavorPricesCents: [200, 250, 200, 200]).pulsePricesConflict, isTrue);
      final mdb = pulse.copyWith(paymentTerminalType: PaymentTerminalType.mdb);
      expect(mdb.copyWith(flavorPricesCents: [200, 250]).pulsePricesConflict, isFalse);
    });

    test('слепок для облака: цены активных запахов и настройки карты', () {
      final c = AppConfig(
        specPumps: 4,
        flavorPricesCents: [150, 250, 350, 450, 999],
        paymentTerminalType: PaymentTerminalType.mdb,
      );
      final s = c.reportedSnapshot();
      expect(s['flavor_prices_cents'], [150, 250, 350, 450]);
      expect(s['payment_terminal_type'], 'mdb');
      expect(s['card_refund_window_s'], 30);
      expect(s['card_confirm_enabled'], isTrue);
      expect(s['price_cents'], 200);
    });
  });

  group('update_config', () {
    AppNotifier notifier({String type = PaymentTerminalType.off}) => AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: true,
        servicePin: '7351',
        paymentTerminalType: type,
      );
    Future<CommandOutcome> upd(AppNotifier n, Map<String, dynamic> p) => RemoteCommands.handle(
      CloudCommand(
        id: 'c-${DateTime.now().microsecondsSinceEpoch}',
        action: 'update_config',
        params: p,
        createdAt: DateTime.now().toUtc(),
      ),
      n,
    );

    test('цены запахов: заменяются первые N, остальные на месте', () async {
      final n = notifier();
      final o = await upd(n, {'flavorPricesCents': [300, 350]});
      expect(o.ok, isTrue, reason: o.result);
      expect(n.config.flavorPricesCents.take(3), [300, 350, 200]);
    });

    test('treatmentPriceCents не перезаписывает цены запахов', () async {
      final n = notifier();
      await upd(n, {'flavorPricesCents': [300, 350, 400, 450]});
      final o = await upd(n, {'treatmentPriceCents': 1000});
      expect(o.ok, isTrue);
      expect(n.config.treatmentPriceCents, 1000);
      expect(n.config.flavorPricesCents.take(4), [300, 350, 400, 450]);
    });

    test('тип терминала и окно возврата', () async {
      final n = notifier();
      final o = await upd(n, {'paymentTerminalType': 'mdb', 'cardRefundWindowS': 20, 'cardConfirmEnabled': false});
      expect(o.ok, isTrue, reason: o.result);
      expect(n.config.paymentTerminalType, 'mdb');
      expect(n.config.cardRefundWindowS, 20);
      expect(n.config.cardConfirmEnabled, isFalse);
    });

    for (final (params, code) in <(Map<String, dynamic>, String)>[
      ({'flavorPricesCents': [49]}, 'out_of_range:flavorPricesCents'),
      ({'flavorPricesCents': [2001]}, 'out_of_range:flavorPricesCents'),
      ({'flavorPricesCents': ['300']}, 'bad_type:flavorPricesCents'),
      ({'flavorPricesCents': 300}, 'bad_type:flavorPricesCents'),
      ({'flavorPricesCents': <int>[]}, 'bad_type:flavorPricesCents'),
      ({'flavorPricesCents': List.filled(9, 300)}, 'bad_type:flavorPricesCents'),
      ({'paymentTerminalType': 'nfc'}, 'invalid:paymentTerminalType'),
      ({'cardRefundWindowS': 9}, 'out_of_range:cardRefundWindowS'),
      ({'cardRefundWindowS': 39}, 'out_of_range:cardRefundWindowS'),
      ({'cardConfirmEnabled': 'yes'}, 'bad_type:cardConfirmEnabled'),
    ]) {
      test('отклоняется целиком: $params → $code', () async {
        final n = notifier();
        final before = jsonEncode(n.config.reportedSnapshot());
        final o = await upd(n, {...params, 'treatmentDurationS': 60});
        expect(o.ok, isFalse);
        expect(o.result, code);
        expect(jsonEncode(n.config.reportedSnapshot()), before);
      });
    }

    test('pulse: разные цены не сохраняются (ни ценами, ни сменой типа)', () async {
      final n = notifier(type: PaymentTerminalType.pulse);
      final o = await upd(n, {'flavorPricesCents': [300, 350]});
      expect(o.ok, isFalse);
      expect(o.result, 'pulse_prices_differ');
      expect(n.config.flavorPricesCents.take(2), [200, 200]);

      final m = notifier(type: PaymentTerminalType.mdb);
      await upd(m, {'flavorPricesCents': [300, 350]});
      final o2 = await upd(m, {'paymentTerminalType': 'pulse'});
      expect(o2.ok, isFalse);
      expect(o2.result, 'pulse_prices_differ');
      expect(m.config.paymentTerminalType, 'mdb');

      final o3 = await upd(n, {'flavorPricesCents': [300, 300, 300, 300]});
      expect(o3.ok, isTrue, reason: 'одинаковые цены при pulse — можно');
    });

    test('пределы окна возврата — в общем списке ConfigLimits', () {
      expect(ConfigLimits.range('cardRefundWindowS'), (min: 10, max: 38));
      expect(CardPaymentLimits.refundWindowDefaultS, 30);
    });
  });

  // 1.11.2: цены перенесены с «Настроек» на вкладку «Ароматы» (название и
  // цена запаха рядом); ключи настроек прежние.
  group('сервисное меню, цены на вкладке «Ароматы»', () {
    Future<AppNotifier> pumpMenu(
      WidgetTester tester, {
      String type = PaymentTerminalType.off,
      List<int> prices = const [200, 200, 200, 200],
      AppConfig? config,
    }) async {
      tester.view.devicePixelRatio = 1.5;
      tester.view.physicalSize = const Size(1080, 1920);
      addTearDown(tester.view.reset);
      final n = AppNotifier()
        ..config = config ??
            AppConfig(
              thermoInstalled: true,
              energyMeterInstalled: true,
              servicePin: '7351',
              treatmentPriceCents: 300,
              flavorPricesCents: prices,
              paymentTerminalType: type,
            );
      n.setLanguage('ru');
      await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
        value: n,
        child: const MaterialApp(home: ServiceMenuScreen()),
      ));
      await tester.pump(const Duration(milliseconds: 600));
      // При первом входе меню показывает окно «Мастер-код этого аппарата».
      final dlg = find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextButton));
      if (dlg.evaluate().isNotEmpty) {
        await tester.tap(dlg.last);
        await tester.pump(const Duration(milliseconds: 600));
      }
      return n;
    }

    Future<void> tapVisible(WidgetTester tester, Finder f) async {
      await tester.ensureVisible(f);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(f);
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> openFlavors(WidgetTester tester) async {
      await tester.tap(find.text('Ароматы'));
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> save(WidgetTester tester) =>
        tapVisible(tester, find.widgetWithText(ElevatedButton, 'Сохранить').first);

    Finder plus(int i) => find.descendant(
          of: find.byKey(ValueKey('flavor_price_$i')),
          matching: find.byIcon(Icons.add),
        );

    Future<void> disposeMenu(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
    }

    testWidgets('«Настройки»: цен нет, окно возврата осталось', (tester) async {
      await pumpMenu(tester);
      for (final k in ['default_price', 'one_price_btn', 'flavor_price_0', 'pulse_prices_warn']) {
        expect(find.byKey(ValueKey(k)), findsNothing, reason: k);
      }
      expect(find.text('Цена по умолчанию (для новых запахов)'), findsNothing);
      expect(find.byKey(const ValueKey('refund_window')), findsOneWidget);
      await disposeMenu(tester);
    });

    testWidgets('«Ароматы»: цена по умолчанию вверху, у каждого активного запаха своя цена', (tester) async {
      await pumpMenu(tester, prices: const [150, 250, 300, 350]);
      await openFlavors(tester);
      expect(find.byKey(const ValueKey('default_price')), findsOneWidget);
      expect(find.text('Цена по умолчанию (для новых запахов)'), findsOneWidget);
      expect(find.text('3.00 €'), findsWidgets);
      for (var i = 0; i < 4; i++) {
        expect(find.byKey(ValueKey('flavor_price_$i')), findsOneWidget, reason: '$i');
      }
      expect(find.byKey(const ValueKey('flavor_price_4')), findsNothing, reason: 'насосов 4');
      final d0 = tester.getTopLeft(find.byKey(const ValueKey('default_price')));
      final p0 = tester.getTopLeft(find.byKey(const ValueKey('flavor_price_0')));
      expect(d0.dy, lessThan(p0.dy), reason: 'общая цена — над ценами запахов');
      for (final p in ['1.50 €', '2.50 €', '3.50 €']) {
        expect(find.text(p), findsOneWidget, reason: p);
      }
      expect(tester.takeException(), isNull);
      await disposeMenu(tester);
    });

    testWidgets('mdb: разные цены сохраняются вместе с названиями', (tester) async {
      final n = await pumpMenu(tester, type: PaymentTerminalType.mdb);
      await openFlavors(tester);
      expect(find.byKey(const ValueKey('pulse_prices_warn')), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'Мята');
      await tapVisible(tester, plus(1));
      await save(tester);
      expect(n.config.flavorPricesCents.take(4), [200, 250, 200, 200]);
      expect(n.config.flavorNames['ru']!.first, 'Мята');
      expect(n.config.treatmentPriceCents, 300);
      await disposeMenu(tester);
    });

    testWidgets('цена по умолчанию сохраняется и не перезаписывает цены запахов', (tester) async {
      final n = await pumpMenu(tester);
      await openFlavors(tester);
      await tapVisible(tester, find.descendant(
        of: find.byKey(const ValueKey('default_price')), matching: find.byIcon(Icons.add)));
      await save(tester);
      expect(n.config.treatmentPriceCents, 350);
      expect(n.config.flavorPricesCents.take(4), [200, 200, 200, 200]);
      await disposeMenu(tester);
    });

    testWidgets('pulse: цена одного запаха меняет цены всех, пояснение видно', (tester) async {
      final n = await pumpMenu(tester, type: PaymentTerminalType.pulse);
      await openFlavors(tester);
      expect(find.byKey(const ValueKey('pulse_prices_warn')), findsOneWidget);
      expect(find.textContaining('изменение цены любого запаха меняет все'), findsOneWidget);
      await tapVisible(tester, plus(1));
      expect(find.text('2.50 €'), findsNWidgets(4));
      await save(tester);
      expect(n.config.flavorPricesCents.take(4), [250, 250, 250, 250]);
      expect(n.config.pulsePricesConflict, isFalse);
      await disposeMenu(tester);
    });

    testWidgets('pulse: уже разные цены (сменили тип) не сохраняются — прежняя проверка', (tester) async {
      final n = await pumpMenu(tester, type: PaymentTerminalType.pulse, prices: const [200, 250, 200, 200]);
      await openFlavors(tester);
      await save(tester);
      expect(n.config.flavorPricesCents.take(4), [200, 250, 200, 200]);
      expect(find.textContaining('Импульсный терминал списывает одну сумму'), findsWidgets);
      await disposeMenu(tester);
    });

    testWidgets('«Одна цена всем запахам» — только после подтверждения', (tester) async {
      final n = await pumpMenu(tester);
      await openFlavors(tester);
      final btn = find.byKey(const ValueKey('one_price_btn'));
      await tapVisible(tester, btn);
      expect(find.text('Одна цена всем запахам'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
      await tester.pump(const Duration(milliseconds: 400));
      await save(tester);
      expect(n.config.flavorPricesCents.take(4), [200, 200, 200, 200]);
      // Сохранение вне сервисного состояния возвращает язык на en — снова ru.
      n.setLanguage('ru');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 6));
      await tester.pump(const Duration(seconds: 1));

      await tapVisible(tester, btn);
      await tester.tap(find.widgetWithText(TextButton, 'Поставить'));
      await tester.pump(const Duration(milliseconds: 400));
      await save(tester);
      expect(n.config.flavorPricesCents.take(4), [300, 300, 300, 300]);
      await disposeMenu(tester);
    });

    testWidgets('сохранение «Настроек» не трогает цены', (tester) async {
      final n = await pumpMenu(tester, type: PaymentTerminalType.mdb, prices: const [150, 250, 300, 350]);
      await save(tester);
      expect(n.config.flavorPricesCents.take(4), [150, 250, 300, 350]);
      expect(n.config.treatmentPriceCents, 300);
      await disposeMenu(tester);
    });

    testWidgets('после обновления: старые ключи прочитаны, вкладка показывает те же цены и названия', (tester) async {
      // Сохранённые 1.11.1 настройки (ключи не менялись).
      await tester.runAsync(() async {
        await ConfigService.save(AppConfig(
          thermoInstalled: true,
          energyMeterInstalled: true,
          servicePin: '7351',
          treatmentPriceCents: 220,
          flavorPricesCents: [100, 250, 150, 300, 200, 200, 200, 200],
          paymentTerminalType: PaymentTerminalType.mdb,
          flavorNames: {
            'ru': ['Лимон', 'Вишня', 'Хвоя', 'Лаванда'],
            'en': ['Lemon', 'Cherry', 'Pine', 'Lavender'],
            'et': ['Sidrun', 'Kirss', 'Mänd', 'Lavendel'],
          },
        ));
      });
      final raw = jsonDecode((await tester.runAsync(SharedPreferences.getInstance))!
          .getString('app_config')!) as Map<String, dynamic>;
      expect(raw.containsKey('treatmentPriceCents'), isTrue);
      expect(raw.containsKey('flavorPricesCents'), isTrue);
      final loaded = (await tester.runAsync(ConfigService.load))!;
      final n = await pumpMenu(tester, config: loaded);
      await openFlavors(tester);
      for (final p in ['2.20 €', '1.00 €', '2.50 €', '1.50 €', '3.00 €']) {
        expect(find.text(p), findsOneWidget, reason: p);
      }
      expect(find.textContaining('Лаванда'), findsWidgets);
      // сохранение без правок — ничего не теряется
      await save(tester);
      expect(n.config.flavorPricesCents, [100, 250, 150, 300, 200, 200, 200, 200]);
      expect(n.config.treatmentPriceCents, 220);
      expect(n.config.flavorNames['ru']!.take(4), ['Лимон', 'Вишня', 'Хвоя', 'Лаванда']);
      await disposeMenu(tester);
    });
  });

  testWidgets('экран выбора: у каждого запаха своя цена', (tester) async {
    tester.view.devicePixelRatio = 1.5;
    tester.view.physicalSize = const Size(1080, 1920);
    addTearDown(tester.view.reset);
    final n = AppNotifier()
      ..config = AppConfig(
        thermoInstalled: true,
        energyMeterInstalled: true,
        flavorPricesCents: [150, 250, 300, 1990],
      );
    n.updateLevels([true, true, true, true, true, true, true, true]);
    await tester.pumpWidget(ChangeNotifierProvider<AppNotifier>.value(
      value: n,
      child: const MaterialApp(home: SelectFlavorScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 600));
    for (final p in ['1.50 €', '2.50 €', '3.00 €', '19.90 €']) {
      expect(find.text(p), findsOneWidget, reason: p);
    }
    expect(tester.takeException(), isNull);
  });
}
