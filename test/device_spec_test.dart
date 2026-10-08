import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/models/device_spec.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/factory_config_service.dart';

// Спецификация аппарата (число насосов, языки): контракт, хранение, заводской
// файл. Экраны и карта каналов в этой части не меняются.
class _Store implements FactoryConfigStore {
  String? text;
  @override
  Future<FileReadResult> read({bool allowRoot = true}) async => text == null
      ? const FileReadResult(FileReadStatus.absent)
      : FileReadResult(FileReadStatus.ok, text);
  @override
  Future<FileDeleteResult> delete() async {
    text = null;
    return const FileDeleteResult(FileDeleteStatus.deleted);
  }
}

String _file({Object? spec, bool withSpec = true, String configId = '2026-10-08-aa11bb22'}) => jsonEncode({
  'format': 1,
  'config_id': configId,
  'device_id': 'CARFOG-200',
  'cloud_url': 'https://example.supabase.co',
  'anon_key': 'sb_publishable_TESTKEY_not_real',
  'token': 'TESTTOKEN_not_real_0123456789',
  if (withSpec) 'spec': spec,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('разбор и проверка spec', () {
    test('значения по умолчанию', () {
      const d = DeviceSpec();
      expect(d.pumps, 4);
      expect(d.langs, ['et', 'en', 'ru']);
      expect(d.defaultLang, 'et');
      expect(d.hardwareProfile, 'sy156-a510');
      final c = AppConfig();
      expect([c.specPumps, c.specLangs, c.specDefaultLang], [4, ['et', 'en', 'ru'], 'et']);
    });

    test('пустой объект = по умолчанию; недостающие поля подставляются', () {
      expect(DeviceSpec.tryParse({}), const DeviceSpec());
      final s = DeviceSpec.tryParse({'langs': ['ru', 'de']})!;
      expect([s.pumps, s.langs, s.defaultLang], [4, ['ru', 'de'], 'ru']); // default — первый
    });

    test('границы насосов 4…10', () {
      for (final ok in [4, 5, 10]) {
        expect(DeviceSpec.tryParse({'pumps': ok}), isNotNull, reason: '$ok');
      }
      for (final bad in [3, 11, 0, -1, 4.5, '5', null, true, 100]) {
        expect(DeviceSpec.tryParse({'pumps': bad}), isNull, reason: '$bad');
      }
    });

    test('языки: каталог, повторы, регистр, длина, типы', () {
      expect(DeviceSpec.catalog.length, 27);
      expect(DeviceSpec.catalog.toSet().length, 27);
      for (final bad in [
        <Object?>[], ['xx'], ['ET'], ['et', 'et'], ['et', null], ['et', 1], 'et', null, {'a': 1}, [''],
        List.filled(25, 'et'), DeviceSpec.catalog.take(25).toList(),
      ]) {
        expect(DeviceSpec.tryParse({'langs': bad}), isNull, reason: '$bad');
      }
      expect(DeviceSpec.tryParse({'langs': DeviceSpec.catalog.take(24).toList()}), isNotNull);
      expect(DeviceSpec.tryParse({'langs': ['no']}), isNotNull);
    });

    test('default_lang должен входить в langs', () {
      expect(DeviceSpec.tryParse({'langs': ['et', 'en'], 'default_lang': 'en'}), isNotNull);
      for (final bad in ['ru', 'EN', '', null, 5]) {
        expect(DeviceSpec.tryParse({'langs': ['et', 'en'], 'default_lang': bad}), isNull, reason: '$bad');
      }
    });

    test('мусор вместо объекта', () {
      for (final bad in [null, 5, 'x', <Object?>[], true]) {
        expect(DeviceSpec.tryParse(bad), isNull, reason: '$bad');
      }
    });

    test('показ: пересечение с реализованными, порядок langs; пусто → en', () {
      final s = DeviceSpec.tryParse({'langs': ['de', 'ru', 'fr', 'et'], 'default_lang': 'de'})!;
      expect(s.displayLangs, ['ru', 'et']);
      expect(s.unsupportedLangs, ['de', 'fr']);
      expect(s.displayDefaultLang, 'ru'); // default de не показывается → первый показываемый
      final only = DeviceSpec.tryParse({'langs': ['de', 'fr']})!;
      expect(only.displayLangs, ['en']);
      expect(only.displayDefaultLang, 'en');
      expect(const DeviceSpec().displayLangs, ['et', 'en', 'ru']);
      expect(const DeviceSpec().unsupportedLangs, isEmpty);
    });
  });

  group('хранение и старые настройки', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<AppConfig> loadFixture(String name) async {
      final raw = File('test/fixtures/$name').readAsStringSync().trim();
      SharedPreferences.setMockInitialValues({'app_config': raw});
      return ConfigService.load();
    }

    for (final v in ['app_config_1_7_0.json', 'app_config_1_8_0.json']) {
      test('настройки $v загружаются: пользовательское на месте, spec по умолчанию', () async {
        final c = await loadFixture(v);
        expect(c.treatmentPriceCents, 350);
        expect(c.treatmentDurationS, 55);
        expect(c.servicePin, '7351');
        expect(c.deviceId, 'CARFOG-100');
        expect(c.cloudUrl, 'https://example.supabase.co');
        expect(c.cloudToken, 'FIXTURE_TOKEN_not_real');
        expect(c.cloudEnabled, isTrue);
        expect(c.kioskModeEnabled, isTrue);
        expect(c.thermoInstalled && c.energyMeterInstalled && c.coinAcceptorInstalled, isTrue);
        expect(c.outputWatchdogEnabled, isFalse);
        expect(c.idlePowerTariffPerKwh, 0.31);
        expect(c.flavorNames['ru']![0], 'Мой лимон');
        expect(c.flavorNames['en']![0], 'My lemon');
        expect(c.flavorNames['et']![0], 'Minu sidrun');
        expect(c.flavorNames['ru']!.length, 8);
        expect(c.busPort, v.contains('1_8_0') ? '/dev/ttyS3' : '/dev/ttyS4');
        // spec — по умолчанию (в старых настройках его не было)
        expect([c.specPumps, c.specLangs, c.specDefaultLang], [4, ['et', 'en', 'ru'], 'et']);
      });
    }

    test('сохранение–загрузка: пользовательские названия по языкам и spec', () async {
      final c = AppConfig(
        specPumps: 9,
        specLangs: ['ru', 'de', 'en'],
        specDefaultLang: 'de',
        flavorNames: {
          'ru': List.generate(10, (i) => 'Аромат $i'),
          'en': List.generate(10, (i) => 'Scent $i'),
          'de': List.generate(10, (i) => 'Duft $i'),
        },
      );
      await ConfigService.save(c);
      final back = await ConfigService.load();
      expect([back.specPumps, back.specLangs, back.specDefaultLang], [9, ['ru', 'de', 'en'], 'de']);
      expect(back.flavorNames['de']![9], 'Duft 9');
      expect(back.flavorNames['ru']![0], 'Аромат 0');
    });

    test('неверный сохранённый spec заменяется значениями по умолчанию целиком', () async {
      for (final bad in [
        {'specPumps': 3, 'specLangs': ['ru'], 'specDefaultLang': 'ru'},
        {'specPumps': 6, 'specLangs': ['xx'], 'specDefaultLang': 'xx'},
        {'specPumps': 6, 'specLangs': ['ru'], 'specDefaultLang': 'en'},
        {'specPumps': '6', 'specLangs': 'ru'},
      ]) {
        SharedPreferences.setMockInitialValues({'app_config': jsonEncode({'treatmentPriceCents': 300, ...bad})});
        final c = await ConfigService.load();
        expect(c.treatmentPriceCents, 300, reason: '$bad');
        expect([c.specPumps, c.specLangs, c.specDefaultLang], [4, ['et', 'en', 'ru'], 'et'], reason: '$bad');
      }
    });

    test('слепок настроек содержит spec и профиль, без секретов', () {
      final snap = AppConfig(specPumps: 7, specLangs: ['ru', 'en'], specDefaultLang: 'ru',
          cloudToken: 'секрет-токен', servicePin: '7351').reportedSnapshot();
      expect(snap['spec_pumps'], 7);
      expect(snap['spec_langs'], ['ru', 'en']);
      expect(snap['spec_default_lang'], 'ru');
      expect(snap['hardware_profile'], 'sy156-a510');
      final j = jsonEncode(snap);
      expect(j, isNot(contains('секрет-токен')));
      expect(j, isNot(contains('7351')));
    });
  });

  group('заводской файл со spec', () {
    late _Store store;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      store = _Store();
      FactoryConfigService.store = store;
      CloudService.resetQueueForTest();
    });

    AppConfig custom() => AppConfig(
      treatmentPriceCents: 450,
      treatmentDurationS: 61,
      servicePin: '8264',
      compressorPurgeS: 9,
      pumpAfterHeaterS: 8,
      kioskModeEnabled: true,
      paymentTerminalEnabled: true,
      paymentTerminalChannel: 4,
      outputWatchdogEnabled: false,
      thermoInstalled: true,
      energyMeterInstalled: true,
      coinAcceptorInstalled: true,
      idlePowerTariffPerKwh: 0.5,
      busPort: '/dev/ttyS3',
      flavorNames: {
        'ru': List.generate(10, (i) => 'Мой $i'),
        'en': List.generate(10, (i) => 'Mine $i'),
        'et': List.generate(10, (i) => 'Minu $i'),
      },
    );

    test('разбор: spec есть / нет / неверный', () {
      final ok = parseFactoryConfig(_file(spec: {'pumps': 8, 'langs': ['ru', 'en'], 'default_lang': 'en'}));
      expect(ok.ok, isTrue);
      expect(ok.config!.spec!.pumps, 8);
      expect(ok.config!.spec!.langs, ['ru', 'en']);
      final none = parseFactoryConfig(_file(withSpec: false));
      expect(none.ok, isTrue);
      expect(none.config!.spec, isNull); // старый файл работает
      for (final bad in [
        {'pumps': 3}, {'pumps': 11}, {'langs': ['xx']}, {'langs': ['et', 'et']},
        {'langs': ['et'], 'default_lang': 'ru'}, 'x', 5, <Object?>[],
      ]) {
        final r = parseFactoryConfig(_file(spec: bad));
        expect(r.ok, isFalse, reason: '$bad');
        expect(r.error, FactoryConfigError.badSpec);
      }
      expect(parseFactoryConfig(_file(spec: null)).error, FactoryConfigError.badSpec); // "spec": null
    });

    test('применение: меняются только облако и spec; пользовательское не тронуто', () async {
      store.text = _file(spec: {'pumps': 8, 'langs': ['ru', 'de', 'en'], 'default_lang': 'ru'});
      final before = custom();
      final out = await FactoryConfigService.applyOnStartup(before);
      // spec
      expect([out.specPumps, out.specLangs, out.specDefaultLang], [8, ['ru', 'de', 'en'], 'ru']);
      // облако
      expect(out.deviceId, 'CARFOG-200');
      expect(out.cloudEnabled, isTrue);
      expect(out.cloudToken, 'TESTTOKEN_not_real_0123456789');
      // пользовательские настройки НЕ перезаписаны
      expect(out.treatmentPriceCents, 450);
      expect(out.treatmentDurationS, 61);
      expect(out.servicePin, '8264');
      expect(out.compressorPurgeS, 9);
      expect(out.pumpAfterHeaterS, 8);
      expect(out.kioskModeEnabled, isTrue);
      expect(out.paymentTerminalEnabled, isTrue);
      expect(out.paymentTerminalChannel, 4);
      expect(out.outputWatchdogEnabled, isFalse);
      expect(out.thermoInstalled && out.energyMeterInstalled && out.coinAcceptorInstalled, isTrue);
      expect(out.idlePowerTariffPerKwh, 0.5);
      expect(out.busPort, '/dev/ttyS3');
      expect(out.flavorNames, before.flavorNames); // названия ароматов — никогда
      // и после перезапуска (из хранилища)
      final back = await ConfigService.load();
      expect(back.specPumps, 8);
      expect(back.flavorNames['ru']![9], 'Мой 9');
    });

    test('файл без spec не трогает spec в настройках', () async {
      store.text = _file(withSpec: false);
      final base = custom()..specPumps = 7..specLangs = ['ru', 'en']..specDefaultLang = 'en';
      final out = await FactoryConfigService.applyOnStartup(base);
      expect(out.deviceId, 'CARFOG-200');
      expect([out.specPumps, out.specLangs, out.specDefaultLang], [7, ['ru', 'en'], 'en']);
    });

    test('правило применения то же: тот же config_id и облако на месте — spec не применяется повторно', () async {
      store.text = _file(spec: {'pumps': 8});
      var c = await FactoryConfigService.applyOnStartup(custom());
      expect(c.specPumps, 8);
      // техник/облако изменили spec позже; тот же файл ещё лежит → не затирает
      c = c.copyWith(specPumps: 6);
      final again = await FactoryConfigService.applyOnStartup(c);
      expect(again.specPumps, 6);
      // облачные поля пусты → применится снова (как облако)
      final cleared = c.copyWith(cloudToken: '', cloudAnonKey: '', cloudUrl: '');
      final re = await FactoryConfigService.applyOnStartup(cleared);
      expect(re.specPumps, 8);
    });

    test('неверный spec: файл отклонён целиком, ничего не применено', () async {
      store.text = _file(spec: {'pumps': 99});
      final base = custom();
      final out = await FactoryConfigService.applyOnStartup(base);
      expect(identical(out, base), isTrue);
      expect(out.deviceId, isNot('CARFOG-200'));
      expect(out.specPumps, 4);
    });
  });
}
