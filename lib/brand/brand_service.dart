import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/app_state.dart';
import '../services/app_log_service.dart';
import '../services/cloud_service.dart';
import '../services/system_service.dart';
import 'brand.dart';
import 'brand_rules.dart';
import 'brand_zip.dart';

/// Что сервер сказал про бренд в ответе device_poll (поле `brand`).
/// Нет поля или мусор — [BrandDirective.tryParse] вернёт null: «ничего не
/// менять». Явный null на сервере — [BrandDirective.builtin].
@immutable
class BrandDirective {
  const BrandDirective.builtin()
      : id = null,
        version = 0,
        sha256 = null,
        sizeBytes = 0;
  const BrandDirective.assign({
    required String this.id,
    required this.version,
    required String this.sha256,
    required this.sizeBytes,
  });

  final String? id;
  final int version;
  final String? sha256;
  final int sizeBytes;

  bool get isBuiltin => id == null;

  /// [body] — разобранный ответ device_poll.
  static BrandDirective? tryParse(Map body) {
    if (!body.containsKey('brand')) return null;
    final raw = body['brand'];
    if (raw == null) return const BrandDirective.builtin();
    if (raw is! Map) return null;
    final id = raw['id'];
    final version = raw['version'];
    final sha = raw['sha256'];
    final size = raw['size_bytes'];
    if (id is! String || !brandIdRe.hasMatch(id)) return null;
    if (version is! int || version < 1) return null;
    if (sha is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha)) return null;
    if (size is! int || size < 1 || size > BrandLimits.maxZipBytes) return null;
    return BrandDirective.assign(
      id: id,
      version: version,
      sha256: sha.toLowerCase(),
      sizeBytes: size,
    );
  }

  String get key => isBuiltin ? 'builtin' : '$id/$version/$sha256';
}

/// Ответ Edge Function brand-url.
class BrandTicket {
  const BrandTicket({
    required this.id,
    required this.version,
    required this.sha256,
    required this.sizeBytes,
    required this.url,
  });
  final String id;
  final int version;
  final String sha256;
  final int sizeBytes;
  final Uri url;
}

/// Сбой установки пакета; [code] идёт в событие brand_failed как есть.
class BrandFailure implements Exception {
  const BrandFailure(this.code);
  final String code;
  @override
  String toString() => 'BrandFailure($code)';
}

/// Получение, проверка и применение пакета бренда (ТЗ белого лейбла).
///
/// Хранение: `filesDir/brand/ID-vN/` и указатель
/// `filesDir/brand/current.json` {id, version, sha256}. Папка filesDir
/// переживает обновление APK и перезагрузку.
///
/// Любой сбой оставляет прежний бренд (или встроенный) нетронутым: пакет
/// собирается во временной папке `tmp-*`, переименовывается в итоговую, и
/// только потом атомарно (файл + rename) меняется указатель.
class BrandService {
  BrandService._();

  // ---------------- подменяемые части (для тестов) ----------------

  /// Папка filesDir/brand или null, если каталог недоступен.
  static Future<Directory?> Function() rootProvider = _defaultRoot;

  /// Запрос подписанной ссылки у brand-url. null — «бренда нет».
  static Future<BrandTicket?> Function(AppConfig cfg) ticketFetcher = _fetchTicket;

  /// Скачивание в память с пределом размера.
  static Future<Uint8List> Function(Uri url, int maxBytes) downloader = _download;

  static DateTime Function() clock = DateTime.now;

  /// Отправка события в облако.
  static Future<void> Function(String type, Map<String, dynamic> data) reporter =
      (type, data) => CloudService.report(type, data: data);

  /// Точка отказа для тестов: бросает FileSystemException на этапе.
  @visibleForTesting
  static void Function(String stage)? ioFailureHook;

  static const Duration _downloadTimeout = Duration(seconds: 60);
  static const Duration _idleTimeout = Duration(seconds: 20);
  static const Duration _requestTimeout = Duration(seconds: 15);

  /// Пауза между попытками установки одного и того же пакета: не меньше
  /// 30 с (лимит brand-url — один запрос в 30 с на аппарат), растёт вдвое
  /// до 15 минут. Внутри одного опроса попытка одна — цикла нет.
  static const Duration minRetryPause = Duration(seconds: 30);
  static const Duration maxRetryPause = Duration(minutes: 15);

  // ---------------- состояние ----------------

  static AppNotifier? _notifier;
  static VoidCallback? _listener;
  static bool _busy = false;

  static Brand? _loaded; // пакет на диске (по указателю), null — встроенный
  static String? _loadedSha;
  static String? _failure; // 'sha256', 'zip:crc'… — причина последнего сбоя
  static String? _lastReported; // чтобы не слать одно и то же событие снова
  static String? _failKey;
  static int _failCount = 0;
  static DateTime? _nextAttempt;

  /// Состояние для reported_config: builtin / applied / pending /
  /// failed:<причина>.
  static String get state {
    final f = _failure;
    if (f != null) return 'failed:$f';
    final target = _loaded ?? Brand.builtin;
    if (BrandController.instance.active == target) {
      return _loaded == null ? 'builtin' : 'applied';
    }
    return 'pending';
  }

  /// Поля слепка настроек для облака.
  static Map<String, dynamic> reported() {
    final b = _loaded ?? Brand.builtin;
    return {
      'brand_id': b.id,
      'brand_version': b.version,
      'brand_state': state,
    };
  }

  /// Блок `brand` пакета удалённой диагностики: без ссылок и токенов.
  static Map<String, dynamic> diagnostics() {
    final b = _loaded ?? Brand.builtin;
    final active = BrandController.instance.active;
    return {
      'id': b.id,
      'version': b.version,
      'state': state,
      'active_id': active.id,
      'active_version': active.version,
      'last_error': _failure,
    };
  }

  // ---------------- запуск ----------------

  /// Вызывается один раз при старте после создания notifier: читает
  /// указатель, проверяет файлы и (если аппарат на заставке) применяет.
  static Future<void> init(AppNotifier notifier) async {
    final old = _listener;
    if (old != null) _notifier?.removeListener(old);
    _notifier = notifier;
    _listener = () {
      if (notifier.state == AppState.standby) applyIfStandby();
    };
    notifier.addListener(_listener!);
    await _loadCurrent();
    applyIfStandby();
  }

  static Future<void> _loadCurrent() async {
    _loaded = null;
    _loadedSha = null;
    final root = await _root();
    if (root == null) return;
    await _removeTmp(root);
    final pointer = File('${root.path}/current.json');
    try {
      if (!pointer.existsSync()) return;
      final j = jsonDecode(await pointer.readAsString());
      if (j is! Map ||
          j['id'] is! String ||
          j['version'] is! int ||
          j['sha256'] is! String) {
        throw const BrandFailure('io');
      }
      final id = j['id'] as String;
      final version = j['version'] as int;
      if (!brandIdRe.hasMatch(id) || version < 1) throw const BrandFailure('io');
      final dir = Directory('${root.path}/$id-v$version');
      final brand = await _readDir(dir, id, version);
      _loaded = brand;
      _loadedSha = (j['sha256'] as String).toLowerCase();
      _failure = null;
    } catch (_) {
      // Указатель или папка повреждены: встроенный бренд, указатель
      // убираем — тогда ближайший опрос скачает пакет заново.
      _loaded = null;
      _loadedSha = null;
      try {
        if (pointer.existsSync()) pointer.deleteSync();
      } catch (_) {}
      await _fail('io', key: 'startup');
    }
  }

  /// Читает и заново проверяет распакованный пакет: манифест, PNG, контраст.
  static Future<Brand> _readDir(Directory dir, String id, int version) async {
    if (!dir.existsSync()) throw const BrandFailure('io');
    final manifestFile = File('${dir.path}/brand.json');
    final m = validateManifest(
      jsonDecode(await manifestFile.readAsString()),
      wantId: id,
      wantVersion: version,
    );
    if (m.manifest == null) throw BrandFailure('manifest:${m.error}');
    final man = m.manifest!;
    final logo = File('${dir.path}/logo.png');
    if (checkPng(await logo.readAsBytes(), BrandLimits.maxLogoBytes) != null) {
      throw const BrandFailure('png');
    }
    String? qrPath;
    if (man.hasQr) {
      final qr = File('${dir.path}/qr_default.png');
      if (checkPng(await qr.readAsBytes(), BrandLimits.maxLogoBytes) != null) {
        throw const BrandFailure('png');
      }
      qrPath = qr.path;
    }
    if (firstContrastFailure(man.colorsHex) != null) throw const BrandFailure('contrast');
    return Brand(
      id: man.id,
      version: man.version,
      name: man.name,
      colors: man.colors,
      slogan: man.slogan,
      logoPath: logo.path,
      qrPath: qrPath,
    );
  }

  // ---------------- применение на экране ----------------

  /// Меняет активный бренд только когда аппарат на заставке: ни оплата,
  /// ни приготовление, ни сервисное меню не перекрашиваются на ходу.
  static void applyIfStandby() {
    final n = _notifier;
    if (n == null || n.state != AppState.standby) return;
    BrandController.instance.setActive(_loaded ?? Brand.builtin);
  }

  // ---------------- опрос облака ----------------

  /// Вызывается после штатного ответа device_poll. [directive] null — поле
  /// отсутствует или непонятно: ничего не менять.
  static Future<void> onPoll(AppNotifier n, BrandDirective? directive) async {
    if (directive == null || _busy) return;
    _busy = true;
    try {
      if (directive.isBuiltin) {
        await _toBuiltin();
        return;
      }
      if (_loaded != null &&
          _loaded!.id == directive.id &&
          _loaded!.version == directive.version &&
          _loadedSha == directive.sha256) {
        // Уже стоит. Прежний сбой другого пакета с экрана не мешает.
        _failure = null;
        _failKey = null;
        _failCount = 0;
        return;
      }
      final next = _nextAttempt;
      if (_failKey == directive.key && next != null && clock().isBefore(next)) {
        return; // пауза после неудачи этого же пакета
      }
      await _install(n, directive);
    } finally {
      _busy = false;
    }
  }

  static Future<void> _toBuiltin() async {
    _failure = null;
    _failKey = null;
    _failCount = 0;
    if (_loaded == null && _loadedSha == null) return;
    final root = await _root();
    try {
      if (root != null) {
        final p = File('${root.path}/current.json');
        if (p.existsSync()) p.deleteSync();
      }
    } catch (_) {
      await _fail('io', key: 'builtin');
      return;
    }
    _loaded = null;
    _loadedSha = null;
    applyIfStandby();
  }

  static Future<void> _install(AppNotifier n, BrandDirective d) async {
    final root = await _root();
    if (root == null) {
      await _fail('io', key: d.key);
      return;
    }
    Directory? tmp;
    try {
      final cfg = n.config;
      final ticket = await ticketFetcher(cfg);
      if (ticket == null) {
        // Назначение сняли между опросом и запросом ссылки.
        await _toBuiltin();
        return;
      }
      if (ticket.id != d.id ||
          ticket.version != d.version ||
          ticket.sha256 != d.sha256 ||
          ticket.sizeBytes != d.sizeBytes) {
        throw const BrandFailure('download');
      }
      final Uint8List bytes;
      try {
        bytes = await downloader(ticket.url, BrandLimits.maxZipBytes);
      } on BrandFailure {
        rethrow;
      } catch (_) {
        throw const BrandFailure('download');
      }
      if (bytes.length != d.sizeBytes || sha256.convert(bytes).toString() != d.sha256) {
        throw const BrandFailure('sha256');
      }

      final Map<String, Uint8List> files;
      try {
        files = readBrandZip(bytes);
      } on BrandZipException catch (e) {
        throw BrandFailure('zip:${e.code}');
      }

      _checkFiles(files, d);

      // Запись: tmp → итоговая папка → указатель.
      try {
        _hook('mkdir_tmp');
        tmp = Directory('${root.path}/tmp-${clock().microsecondsSinceEpoch}');
        await tmp.create(recursive: true);
        for (final e in files.entries) {
          await File('${tmp.path}/${e.key}').writeAsBytes(e.value, flush: true);
        }
        _hook('rename_dir');
        final finalDir = Directory('${root.path}/${d.id}-v${d.version}');
        if (finalDir.existsSync()) await finalDir.delete(recursive: true);
        await tmp.rename(finalDir.path);
        tmp = null;
        _hook('write_pointer');
        final ptmp = File('${root.path}/current.json.tmp');
        await ptmp.writeAsString(
          jsonEncode({'id': d.id, 'version': d.version, 'sha256': d.sha256}),
          flush: true,
        );
        await ptmp.rename('${root.path}/current.json');
      } on FileSystemException {
        throw const BrandFailure('io');
      }

      final brand = await _readDir(
        Directory('${root.path}/${d.id}-v${d.version}'),
        d.id!,
        d.version,
      );
      _loaded = brand;
      _loadedSha = d.sha256;
      _failure = null;
      _failKey = null;
      _failCount = 0;
      _nextAttempt = null;
      AppLog.log('Brand', 'пакет ${d.id} v${d.version} установлен');
      await _cleanup(root);
      applyIfStandby();
    } on BrandFailure catch (e) {
      await _fail(e.code, key: d.key);
    } catch (_) {
      await _fail('io', key: d.key);
    } finally {
      if (tmp != null) {
        try {
          if (tmp.existsSync()) await tmp.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  static void _hook(String stage) {
    final h = ioFailureHook;
    if (h != null) h(stage);
  }

  /// Состав архива, манифест, PNG и контраст. Бросает [BrandFailure].
  static BrandManifest _checkFiles(Map<String, Uint8List> files, BrandDirective d) {
    final manifestBytes = files['brand.json'];
    if (manifestBytes == null) throw const BrandFailure('manifest:missing');
    Object? json;
    try {
      json = jsonDecode(utf8.decode(manifestBytes));
    } catch (_) {
      throw const BrandFailure('manifest:json');
    }
    final r = validateManifest(json, wantId: d.id!, wantVersion: d.version);
    final man = r.manifest;
    if (man == null) throw BrandFailure('manifest:${r.error}');
    final logo = files['logo.png'];
    if (logo == null) throw const BrandFailure('png:missing');
    final lerr = checkPng(logo, BrandLimits.maxLogoBytes);
    if (lerr != null) throw BrandFailure('png:$lerr');
    final qr = files['qr_default.png'];
    if (man.hasQr != (qr != null)) throw const BrandFailure('manifest:files');
    if (qr != null) {
      final qerr = checkPng(qr, BrandLimits.maxLogoBytes);
      if (qerr != null) throw BrandFailure('png:$qerr');
    }
    if (firstContrastFailure(man.colorsHex) != null) throw const BrandFailure('contrast');
    return man;
  }

  static Future<void> _fail(String code, {required String key}) async {
    _failure = code;
    if (_failKey == key) {
      _failCount++;
    } else {
      _failKey = key;
      _failCount = 1;
    }
    final pause = minRetryPause * (1 << (_failCount - 1).clamp(0, 10));
    _nextAttempt = clock().add(pause > maxRetryPause ? maxRetryPause : pause);
    // В журнал и событие — только короткий код (ни ссылок, ни токенов).
    AppLog.log('Brand', 'не удалось: $code');
    final rep = '$key|$code';
    if (_lastReported != rep) {
      _lastReported = rep;
      try {
        await reporter('brand_failed', {'reason': code});
      } catch (_) {}
    }
  }

  // ---------------- чистка ----------------

  static final RegExp _verDir = RegExp(r'^([a-z0-9][a-z0-9_-]*)-v(\d+)$');

  /// Оставляет текущую версию и одну предыдущую (самую большую по номеру из
  /// остальных); остальное и недокачанные tmp-* удаляет.
  static Future<void> _cleanup(Directory root) async {
    try {
      await _removeTmp(root);
      final cur = _loaded == null ? null : '${_loaded!.id}-v${_loaded!.version}';
      final others = <String, int>{};
      for (final e in root.listSync()) {
        if (e is! Directory) continue;
        final name = e.path.split('/').last;
        final m = _verDir.firstMatch(name);
        if (m == null || name == cur) continue;
        others[name] = int.parse(m.group(2)!);
      }
      final names = others.keys.toList()..sort((a, b) => others[b]!.compareTo(others[a]!));
      for (final name in names.skip(1)) {
        await Directory('${root.path}/$name').delete(recursive: true);
      }
    } catch (_) {
      // Чистка не критична.
    }
  }

  static Future<void> _removeTmp(Directory root) async {
    try {
      if (!root.existsSync()) return;
      for (final e in root.listSync()) {
        final name = e.path.split('/').last;
        if (name.startsWith('tmp-') && e is Directory) {
          await e.delete(recursive: true);
        } else if (name == 'current.json.tmp' && e is File) {
          await e.delete();
        }
      }
    } catch (_) {}
  }

  // ---------------- реализации по умолчанию ----------------

  static Future<Directory?> _root() async {
    final d = await rootProvider();
    if (d == null) return null;
    try {
      if (!d.existsSync()) await d.create(recursive: true);
    } catch (_) {
      return null;
    }
    return d;
  }

  static Future<Directory?> _defaultRoot() async {
    final p = await SystemService.getFilesDir();
    return p == null ? null : Directory('$p/brand');
  }

  static Future<BrandTicket?> _fetchTicket(AppConfig cfg) async {
    final base = cfg.cloudUrl.replaceAll(RegExp(r'/+$'), '');
    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$base/functions/v1/brand-url'),
            headers: {
              'apikey': cfg.cloudAnonKey,
              'Authorization': 'Bearer ${cfg.cloudAnonKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'device': cfg.deviceId, 'token': cfg.cloudToken}),
          )
          .timeout(_requestTimeout);
    } catch (e) {
      AppLog.log('Brand', 'brand-url: ${e.runtimeType}');
      throw const BrandFailure('download');
    }
    if (resp.statusCode != 200) {
      // 400/401 auth, 404, 429 rate_limited, 500: для события — одно
      // 'download'; точный код только в журнал.
      AppLog.log('Brand', 'brand-url: HTTP ${resp.statusCode}');
      throw const BrandFailure('download');
    }
    try {
      final j = jsonDecode(resp.body);
      if (j is! Map || j['ok'] != true) throw const BrandFailure('download');
      final b = j['brand'];
      if (b == null) return null;
      if (b is! Map) throw const BrandFailure('download');
      final url = Uri.parse(b['url'] as String);
      // Ссылка обязана вести на наш сервер.
      if (url.scheme != 'https' || url.host != Uri.parse(base).host) {
        throw const BrandFailure('download');
      }
      return BrandTicket(
        id: b['id'] as String,
        version: (b['version'] as num).toInt(),
        sha256: (b['sha256'] as String).toLowerCase(),
        sizeBytes: (b['size_bytes'] as num).toInt(),
        url: url,
      );
    } on BrandFailure {
      rethrow;
    } catch (_) {
      throw const BrandFailure('download');
    }
  }

  static Future<Uint8List> _download(Uri url, int maxBytes) async {
    final client = HttpClient()..connectionTimeout = _requestTimeout;
    try {
      return await (() async {
        final req = await client.getUrl(url);
        req.followRedirects = false;
        final resp = await req.close();
        if (resp.statusCode != 200) throw const BrandFailure('download');
        if (resp.contentLength > maxBytes) throw const BrandFailure('download');
        final buf = BytesBuilder(copy: false);
        await for (final chunk in resp.timeout(_idleTimeout)) {
          if (buf.length + chunk.length > maxBytes) throw const BrandFailure('download');
          buf.add(chunk);
        }
        return buf.toBytes();
      })().timeout(_downloadTimeout);
    } finally {
      client.close(force: true);
    }
  }

  @visibleForTesting
  static void resetForTest() {
    rootProvider = _defaultRoot;
    ticketFetcher = _fetchTicket;
    downloader = _download;
    clock = DateTime.now;
    reporter = (type, data) => CloudService.report(type, data: data);
    ioFailureHook = null;
    final l = _listener;
    if (l != null) _notifier?.removeListener(l);
    _listener = null;
    _notifier = null;
    _busy = false;
    _loaded = null;
    _loadedSha = null;
    _failure = null;
    _lastReported = null;
    _failKey = null;
    _failCount = 0;
    _nextAttempt = null;
    BrandController.instance.setActive(Brand.builtin);
  }
}
