import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../models/app_state.dart';
import '../models/remote_limits.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'system_service.dart';

// Снимок своего экрана по команде capture_screen (RD1, ТЗ 4.2): корень
// Flutter (RepaintBoundary в MaterialApp.builder) без системных прав и без
// системных панелей, уменьшенный до 800 px по длинной стороне, JPEG ~70%
// (нативное сжатие), отправка в закрытый бакет через Edge Function
// diag-shot-upload.
//
// Запрет (вместо картинки — отказ): экран ввода PIN, всё сервисное меню (там
// поля PIN, кодов и настроек облака) и любой открытый диалог ввода секрета
// (secretInputOpened/Closed).
class ScreenshotService {
  ScreenshotService._();

  static final GlobalKey boundaryKey = GlobalKey(debugLabel: 'screenshot');

  static int _secretInputs = 0;

  // Диалог ввода PIN/кода открыт / закрыт (парные вызовы).
  static void secretInputOpened() => _secretInputs++;
  static void secretInputClosed() {
    if (_secretInputs > 0) _secretInputs--;
  }

  // Причина запрета для текущего состояния; null — снимать можно.
  static String? refusalFor(AppState state) {
    if (state == AppState.servicePinEntry) return 'pin_screen';
    if (state == AppState.serviceMenu) return 'service_menu';
    if (_secretInputs > 0) return 'pin_dialog';
    return null;
  }

  static const Map<String, String> refusalText = {
    'pin_screen': 'снимок запрещён: экран PIN',
    'service_menu': 'снимок запрещён: сервисное меню',
    'pin_dialog': 'снимок запрещён: ввод PIN',
  };

  // Подменяются в тестах.
  @visibleForTesting
  static Future<Uint8List?> Function() capture = _captureRoot;
  @visibleForTesting
  static Future<String?> Function(String shotId, Uint8List jpeg) upload =
      _uploadToCloud;

  @visibleForTesting
  static void resetForTest() {
    _secretInputs = 0;
    capture = _captureRoot;
    upload = _uploadToCloud;
  }

  // Выполнить команду. ok=false — снимка нет (отказ или ошибка); result —
  // короткий JSON для ack.
  static Future<({bool ok, String result})> captureAndSend(
    AppNotifier n,
  ) async {
    final refused = refusalFor(n.state);
    if (refused != null) {
      AppLog.log('Screenshot', 'отказ: $refused');
      return (
        ok: false,
        result: jsonEncode({
          'refused': refused,
          'message': refusalText[refused],
        }),
      );
    }
    final jpeg = await capture();
    if (jpeg == null || jpeg.isEmpty) {
      return (ok: false, result: jsonEncode({'error': 'capture_failed'}));
    }
    if (jpeg.length > ScreenshotLimits.maxBytes) {
      return (
        ok: false,
        result: jsonEncode({'error': 'too_large', 'size_bytes': jpeg.length}),
      );
    }
    final id = 'shot-${DateTime.now().millisecondsSinceEpoch}';
    final error = await upload(id, jpeg);
    AppLog.log('Screenshot', '$id ${jpeg.length} B ${error ?? 'sent'}');
    return (
      ok: error == null,
      result: jsonEncode({
        'shot_id': id,
        'size_bytes': jpeg.length,
        'sent': error == null,
        'error': ?error,
      }),
    );
  }

  // Масштаб для toImage: длинная сторона логического размера → 800 px.
  @visibleForTesting
  static double pixelRatioFor(Size logical) {
    final long = math.max(logical.width, logical.height);
    return long <= 0 ? 1 : ScreenshotLimits.longSidePx / long;
  }

  static Future<Uint8List?> _captureRoot() async {
    try {
      final ro = boundaryKey.currentContext?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return null;
      final image = await ro.toImage(pixelRatio: pixelRatioFor(ro.size));
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (data == null) return null;
        return SystemService.encodeJpeg(
          image.width,
          image.height,
          data.buffer.asUint8List(),
          quality: ScreenshotLimits.jpegQuality,
        );
      } finally {
        image.dispose();
      }
    } catch (e) {
      AppLog.log('Screenshot', 'ошибка снимка: ${e.runtimeType}');
      return null;
    }
  }

  // Отправка в Edge Function diag-shot-upload. null — принято; иначе
  // короткий код (auth, rate_limited, bad_request, http_<код>, network,
  // no_cloud). Тело ответа и токен в журнал не пишутся.
  static Future<String?> _uploadToCloud(String shotId, Uint8List jpeg) async {
    final t = CloudService.transport;
    if (t is! SupabaseTransport) return 'no_cloud';
    final base = t.baseUrl.replaceAll(RegExp(r'/+$'), '');
    try {
      final resp = await http
          .post(
            Uri.parse('$base/functions/v1/diag-shot-upload'),
            headers: {
              'apikey': t.anonKey,
              'Authorization': 'Bearer ${t.anonKey}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'device': CloudService.deviceId,
              'token': t.deviceToken,
              'shot': shotId,
              'jpeg_b64': base64Encode(jpeg),
            }),
          )
          .timeout(ScreenshotLimits.uploadTimeout);
      return switch (resp.statusCode) {
        200 => null,
        400 => 'bad_request',
        401 => 'auth',
        429 => 'rate_limited',
        _ => 'http_${resp.statusCode}',
      };
    } catch (e) {
      AppLog.log('Screenshot', 'отправка: ${e.runtimeType}');
      return 'network';
    }
  }
}
