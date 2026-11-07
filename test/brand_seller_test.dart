import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dry_fog_app/brand/brand.dart';
import 'package:dry_fog_app/brand/brand_qr.dart';
import 'package:dry_fog_app/brand/seller_info.dart';
import 'package:dry_fog_app/models/app_state.dart';
import 'package:dry_fog_app/services/app_log_service.dart';
import 'package:dry_fog_app/services/cloud_service.dart';
import 'package:dry_fog_app/services/config_service.dart';
import 'package:dry_fog_app/services/remote_commands.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SellerInfo.sanitize', () {
    test('qr_url и seller_site: только https, ≤ предела', () {
      expect(SellerInfo.sanitize('qr_url', 'https://carfog.eu/x?a=1'),
          'https://carfog.eu/x?a=1');
      expect(SellerInfo.sanitize('qr_url', 'http://carfog.eu'), isNull);
      expect(SellerInfo.sanitize('qr_url', 'javascript:alert(1)'), isNull);
      expect(SellerInfo.sanitize('qr_url', 'https://'), isNull);
      expect(SellerInfo.sanitize('qr_url', 'https://a b.eu'), isNull);
      final long = 'https://a.eu/${'x' * 300}';
      expect(SellerInfo.sanitize('qr_url', long), isNull);
      final edge = 'https://a.eu/${'x' * (300 - 'https://a.eu/'.length)}';
      expect(edge.length, 300);
      expect(SellerInfo.sanitize('qr_url', edge), edge);
      expect(SellerInfo.sanitize('seller_site', 'https://acme.ee'), 'https://acme.ee');
      expect(SellerInfo.sanitize('seller_site', 'http://acme.ee'), isNull);
      expect(SellerInfo.sanitize('seller_site', 'https://${'a' * 120}.ee'), isNull);
    });

    test('телефон ≤ 32, почта ≤ 80 и простая проверка, юр. строка ≤ 120', () {
      expect(SellerInfo.sanitize('seller_phone', '+372 5555 5555'), '+372 5555 5555');
      expect(SellerInfo.sanitize('seller_phone', '1' * 33), isNull);
      expect(SellerInfo.sanitize('seller_phone', '1' * 32), '1' * 32);
      expect(SellerInfo.sanitize('seller_email', 'info@acme.ee'), 'info@acme.ee');
      expect(SellerInfo.sanitize('seller_email', 'info-at-acme.ee'), isNull);
      expect(SellerInfo.sanitize('seller_email', 'a@b'), isNull);
      expect(SellerInfo.sanitize('seller_email', 'a b@c.ee'), isNull);
      expect(SellerInfo.sanitize('seller_email', '${'a' * 80}@b.ee'), isNull);
      expect(SellerInfo.sanitize('seller_legal', 'ACME OÜ, reg 123'), 'ACME OÜ, reg 123');
      expect(SellerInfo.sanitize('seller_legal', 'x' * 121), isNull);
    });

    test('управляющие символы отбрасываются, крайние пробелы тоже', () {
      expect(SellerInfo.sanitize('seller_phone', ' +372\n55\u0000 5 \t'), '+37255 5');
      expect(SellerInfo.sanitize('seller_legal', 'A\u202EB\u2028C\u0085D'), 'ABCD');
      // только управляющие → пусто = поле очищено
      expect(SellerInfo.sanitize('seller_phone', '\n\t'), '');
    });

    test('null и пустая строка очищают поле; не строка — отказ', () {
      expect(SellerInfo.sanitize('qr_url', null), '');
      expect(SellerInfo.sanitize('qr_url', ''), '');
      expect(SellerInfo.sanitize('qr_url', 5), isNull);
      expect(SellerInfo.sanitize('qr_url', ['https://a.eu']), isNull);
      expect(SellerInfo.sanitize('нет_такого', 'x'), isNull);
    });
  });

  group('update_config: данные продавца', () {
    late Directory tmp;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = await Directory.systemTemp.createTemp('seller');
      AppLog.resetForTest();
      await AppLog.init(dir: tmp, reason: 'normal', version: '1');
      CloudService.appVersion = '1.0+1';
    });
    tearDown(() async {
      AppLog.resetForTest();
      await tmp.delete(recursive: true);
    });

    Future<CommandOutcome> upd(AppNotifier n, Map<String, dynamic> p) =>
        RemoteCommands.handle(
          CloudCommand(
            id: 'u-${DateTime.now().microsecondsSinceEpoch}',
            action: 'update_config',
            params: p,
            createdAt: DateTime.now(),
          ),
          n,
        );

    test('годные поля применяются и переживают перезапуск (ConfigService)', () async {
      final n = AppNotifier();
      final o = await upd(n, {
        'qr_url': 'https://acme.ee/start',
        'seller_phone': '+372 5555 5555',
        'seller_email': 'info@acme.ee',
        'seller_site': 'https://acme.ee',
        'seller_legal': 'ACME OÜ, reg 123',
      });
      expect(o.ok, isTrue);
      expect(n.config.qrUrl, 'https://acme.ee/start');
      expect(n.config.sellerLegal, 'ACME OÜ, reg 123');
      final back = await ConfigService.load();
      expect(back.qrUrl, 'https://acme.ee/start');
      expect(back.sellerPhone, '+372 5555 5555');
      expect(back.sellerEmail, 'info@acme.ee');
      expect(back.sellerSite, 'https://acme.ee');
      expect(back.sellerLegal, 'ACME OÜ, reg 123');
    });

    test('не прошедшее проверку поле игнорируется, остальные применяются; в журнале имя поля без значения', () async {
      final n = AppNotifier();
      await upd(n, {'qr_url': 'https://old.ee', 'seller_phone': '111'});
      final o = await upd(n, {
        'qr_url': 'http://evil.example/SECRETVALUE',
        'seller_phone': '222',
        'seller_email': 'не-почта',
      });
      expect(o.ok, isTrue);
      expect(n.config.qrUrl, 'https://old.ee'); // прежнее осталось
      expect(n.config.sellerPhone, '222');
      expect(n.config.sellerEmail, '');
      await AppLog.flush();
      final log = (await AppLog.tail(50)).join('\n');
      expect(log, contains('qr_url'));
      expect(log, contains('seller_email'));
      expect(log, isNot(contains('SECRETVALUE')));
      expect(log, isNot(contains('не-почта')));
    });

    test('пустое значение очищает поле', () async {
      final n = AppNotifier();
      await upd(n, {'seller_site': 'https://acme.ee'});
      await upd(n, {'seller_site': ''});
      expect(n.config.sellerSite, '');
    });

    test('испорченные сохранённые настройки при загрузке не применяются', () async {
      SharedPreferences.setMockInitialValues({
        'app_config': '{"qrUrl":"http://x.ee","sellerEmail":"bad","sellerPhone":"123"}',
      });
      final c = await ConfigService.load();
      expect(c.qrUrl, '');
      expect(c.sellerEmail, '');
      expect(c.sellerPhone, '123');
    });
  });

  group('QR из ссылки (qr_flutter, уровень H)', () {
    test('логотип занимает не больше 4 % площади — в пределах коррекции H (~30 %)', () {
      expect(BrandQr.logoFraction * BrandQr.logoFraction, lessThanOrEqualTo(0.0401));
      // Самая длинная допустимая ссылка кодируется на уровне H.
      final url = 'https://a.eu/${'x' * (SellerLimits.qrUrlMax - 'https://a.eu/'.length)}';
      final code = QrCode.fromData(
        data: url,
        errorCorrectLevel: QrErrorCorrectLevel.H,
      );
      final img = QrImage(code);
      expect(img.moduleCount, lessThanOrEqualTo(177)); // версия ≤ 40
      // Логотип по центру не накрывает поисковые узоры в углах.
      final side = img.moduleCount;
      final logoModules = (side * BrandQr.logoFraction).ceil();
      final from = (side - logoModules) ~/ 2;
      expect(from, greaterThan(8)); // узор 7 + разделитель 1
      // Доля закрытых логотипом модулей.
      expect(logoModules * logoModules / (side * side), lessThan(0.3));
    });

    test('логотип в центре QR сохраняет пропорции и не превышает 4 % площади', () {
      for (final a in [0.25, 0.5, 100 / 106, 1.0, 2.0, 4.0]) {
        final sz = BrandQr.embeddedLogoSize(300, a);
        expect(sz.width / sz.height, closeTo(a, 1e-9), reason: '$a');
        expect(sz.width * sz.height, lessThanOrEqualTo(300 * 300 * 0.0401), reason: '$a');
        expect(sz.width, lessThanOrEqualTo(300 * BrandQr.logoFraction + 1e-9));
        expect(sz.height, lessThanOrEqualTo(300 * BrandQr.logoFraction + 1e-9));
      }
      // мусор вместо пропорций → квадрат
      expect(BrandQr.embeddedLogoSize(300, 0).width, 60);
      expect(BrandQr.embeddedLogoSize(300, double.nan).height, 60);
    });

    test('короткая ссылка: версия мала, модули считаются', () {
      final code = QrCode.fromData(
        data: 'https://carfog.eu',
        errorCorrectLevel: QrErrorCorrectLevel.H,
      );
      expect(QrImage(code).moduleCount, lessThan(45));
    });

    test('встроенный бренд — без логотипа и без своего QR', () {
      expect(Brand.builtin.logoPath, isNull);
      expect(Brand.builtin.qrPath, isNull);
      expect(Brand.builtin.name, 'CaRFog OÜ');
      expect(Brand.builtin.slogan, '');
    });
  });
}
