import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/app_state.dart';
import '../services/app_log_service.dart';
import 'video_model.dart';

/// Сбой скачивания/проверки; [code] идёт в отчёт как `failed:<code>`.
class VideoFailure implements Exception {
  const VideoFailure(this.code, {this.retryable = false, this.keepPart = false});

  /// no_sd, no_space, network, http_NNN, auth, not_found, sha256, size,
  /// probe, io, ticket, paused.
  final String code;

  /// Можно повторить сразу (внутри попытки) — обрыв связи, истёкшая ссылка.
  final bool retryable;

  /// Недокачанный файл оставить для докачки по Range.
  final bool keepPart;

  @override
  String toString() => 'VideoFailure($code)';
}

class DesiredResult {
  const DesiredResult.ok(DesiredSet this.set) : error = null;
  const DesiredResult.fail(String this.error) : set = null;
  final DesiredSet? set;
  final String? error;
}

class VideoTicket {
  const VideoTicket({required this.url, required this.sha256, required this.sizeBytes});
  final Uri url;
  final String sha256;
  final int sizeBytes;
}

/// Обмен с облаком. Интерфейс подменяется в тестах.
abstract class VideoApi {
  Future<DesiredResult> getDesired(AppConfig cfg);
  Future<VideoTicket> ticket(AppConfig cfg, String videoId);

  /// Скачивает [url] в [part], начиная с байта [start] (Range). Бросает
  /// [VideoFailure]. [shouldContinue] false — прервать (карта убрана,
  /// пришёл клиент): недокачанное остаётся.
  Future<void> download(
    Uri url,
    File part,
    int start, {
    required bool Function() shouldContinue,
  });

  Future<bool> report(AppConfig cfg, List<Map<String, dynamic>> items);
}

class HttpVideoApi implements VideoApi {
  const HttpVideoApi();

  static const Duration _requestTimeout = Duration(seconds: 15);
  static const Duration _idleTimeout = Duration(seconds: 30);

  Map<String, String> _headers(AppConfig cfg) => {
        'apikey': cfg.cloudAnonKey,
        'Authorization': 'Bearer ${cfg.cloudAnonKey}',
        'Content-Type': 'application/json',
      };

  String _base(AppConfig cfg) => cfg.cloudUrl.replaceAll(RegExp(r'/+$'), '');

  @override
  Future<DesiredResult> getDesired(AppConfig cfg) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${_base(cfg)}/rest/v1/rpc/device_videos_get'),
            headers: _headers(cfg),
            body: jsonEncode({'p_device': cfg.deviceId, 'p_token': cfg.cloudToken}),
          )
          .timeout(_requestTimeout);
      if (resp.statusCode != 200) {
        AppLog.log('Video', 'device_videos_get: HTTP ${resp.statusCode}');
        return DesiredResult.fail('http_${resp.statusCode}');
      }
      final body = jsonDecode(resp.body);
      if (body is Map && body['ok'] != true) {
        final e = body['error'];
        return DesiredResult.fail(
          e is String && RegExp(r'^[a-z_]{1,32}$').hasMatch(e) ? e : 'rejected',
        );
      }
      final set = DesiredSet.tryParse(body);
      return set == null ? const DesiredResult.fail('bad_response') : DesiredResult.ok(set);
    } catch (e) {
      AppLog.log('Video', 'device_videos_get: ${e.runtimeType}');
      return const DesiredResult.fail('network');
    }
  }

  @override
  Future<VideoTicket> ticket(AppConfig cfg, String videoId) async {
    final base = _base(cfg);
    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse('$base/functions/v1/video-url'),
            headers: _headers(cfg),
            body: jsonEncode({
              'device': cfg.deviceId,
              'token': cfg.cloudToken,
              'video': videoId,
            }),
          )
          .timeout(_requestTimeout);
    } catch (e) {
      AppLog.log('Video', 'video-url: ${e.runtimeType}');
      throw const VideoFailure('network', retryable: true, keepPart: true);
    }
    if (resp.statusCode != 200) {
      // Тело ответа и ссылку в журнал не пишем; 429 — лимит частоты (10 с).
      AppLog.log('Video', 'video-url: HTTP ${resp.statusCode}');
      final s = resp.statusCode;
      if (s == 429 || s >= 500) throw const VideoFailure('ticket', retryable: true, keepPart: true);
      if (s == 401) throw const VideoFailure('auth');
      if (s == 404) throw const VideoFailure('not_found');
      throw VideoFailure('http_$s');
    }
    try {
      final j = jsonDecode(resp.body);
      final v = j is Map ? j['video'] : null;
      if (v is! Map) throw const VideoFailure('ticket');
      final url = Uri.parse(v['url'] as String);
      // Ссылка обязана вести на наш сервер, по https.
      if (url.scheme != 'https' || url.host != Uri.parse(base).host) {
        throw const VideoFailure('ticket');
      }
      return VideoTicket(
        url: url,
        sha256: (v['sha256'] as String).toLowerCase(),
        sizeBytes: (v['size_bytes'] as num).toInt(),
      );
    } on VideoFailure {
      rethrow;
    } catch (_) {
      throw const VideoFailure('ticket');
    }
  }

  @override
  Future<void> download(
    Uri url,
    File part,
    int start, {
    required bool Function() shouldContinue,
  }) async {
    final client = http.Client();
    RandomAccessFile? raf;
    try {
      final req = http.Request('GET', url);
      if (start > 0) req.headers['Range'] = 'bytes=$start-';
      final resp = await client.send(req).timeout(_requestTimeout);
      final s = resp.statusCode;
      // 416: «с этого места больше нечего отдавать» — файл уже целиком.
      if (s == 416 && start > 0) return;
      if (s != 200 && s != 206) {
        await resp.stream.drain<void>().timeout(_requestTimeout, onTimeout: () {});
        if (s == 403 || s == 400) {
          // Ссылка истекла/испорчена — запросить новую.
          throw const VideoFailure('ticket', retryable: true, keepPart: true);
        }
        if (s == 429 || s >= 500) {
          throw VideoFailure('http_$s', retryable: true, keepPart: true);
        }
        throw VideoFailure('http_$s');
      }
      // 200 при запросе с Range — сервер Range не понял: пишем с нуля.
      final append = start > 0 && s == 206;
      raf = await part.open(mode: append ? FileMode.append : FileMode.write);
      await for (final chunk in resp.stream.timeout(_idleTimeout)) {
        if (!shouldContinue()) {
          throw const VideoFailure('paused', keepPart: true);
        }
        await raf.writeFrom(chunk);
      }
    } on VideoFailure {
      rethrow;
    } on TimeoutException {
      throw const VideoFailure('network', retryable: true, keepPart: true);
    } on SocketException {
      throw const VideoFailure('network', retryable: true, keepPart: true);
    } on http.ClientException {
      throw const VideoFailure('network', retryable: true, keepPart: true);
    } on HandshakeException {
      throw const VideoFailure('network', retryable: true, keepPart: true);
    } on FileSystemException catch (e) {
      // ENOSPC = 28.
      final noSpace = e.osError?.errorCode == 28;
      throw VideoFailure(noSpace ? 'no_space' : 'io');
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
      client.close();
    }
  }

  @override
  Future<bool> report(AppConfig cfg, List<Map<String, dynamic>> items) async {
    try {
      final resp = await http
          .post(
            Uri.parse('${_base(cfg)}/rest/v1/rpc/device_video_report'),
            headers: _headers(cfg),
            body: jsonEncode({
              'p_device': cfg.deviceId,
              'p_token': cfg.cloudToken,
              'p_items': items,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) {
        AppLog.log('Video', 'device_video_report: HTTP ${resp.statusCode}');
        return false;
      }
      final body = jsonDecode(resp.body);
      final ok = body is Map && body['ok'] == true;
      if (!ok) debugPrint('VideoApi.report: отказ сервера');
      return ok;
    } catch (e) {
      AppLog.log('Video', 'device_video_report: ${e.runtimeType}');
      return false;
    }
  }
}
