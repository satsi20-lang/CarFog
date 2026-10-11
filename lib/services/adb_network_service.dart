import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/adb_exposure.dart';
import 'app_log_service.dart';
import 'cloud_service.dart';
import 'privileged_installer.dart';
import 'update_service.dart';

// Сетевой adb по умолчанию закрыт (docs/kiosk_device_owner.md, «Сетевой adb»).
//
//  * Порт 5555 открывается только тумблером в сервисном меню (за PIN) на
//    adbWindow (30 мин) и не переживает перезагрузку (только service.*).
//  * Найденный открытым вне окна (при старте приложения, после переключателя
//    в системных настройках) — закрывается сразу.
//  * Беспроводная отладка (TLS, путь через «Открыть настройки на 10 минут»)
//    живёт те же 30 мин с момента, когда приложение её увидело.
//  * Каждое открытие, закрытие и ошибка — в журнал (тег Adb) и событием
//    debug_mode_changed в облако.
// Сроки окон хранятся в настройках: перезапуск приложения внутри окна
// (adb install) окно не обрывает. Сроки — по часам устройства, поэтому при
// каждой проверке обрезаются до «сейчас + 30 мин»: часы, переведённые назад,
// не продлевают окно больше чем на 30 минут от момента проверки.
// Проверка раз в минуту, пока что-то открыто или окно активно; раз в 5 минут
// — только когда всё закрыто. Включение беспроводной отладки нативная
// сторона сообщает сразу (наблюдатель adb_wifi_enabled), не дожидаясь опроса.
class AdbNetworkService {
  AdbNetworkService._();

  static PrivilegedInstaller get _installer => UpdateService.installer;

  static DateTime Function() clock = DateTime.now;
  static Future<void> Function(Duration) sleep = Future<void>.delayed;

  // Как часто проверять: пока что-то открыто — чаще.
  static Duration idleInterval = const Duration(minutes: 5);
  static Duration openInterval = const Duration(minutes: 1);

  static const _kTcpUntil = 'adb_tcp_until_ms';
  static const _kWifiUntil = 'adb_wifi_until_ms';

  // Последнее прочитанное состояние (null — не читали или нет root).
  static AdbExposure? state;
  static DateTime? tcpUntil;
  static DateTime? wifiUntil;

  // Для слепка: adbd слушает TCP без TLS. null — не определено.
  static bool? get adbNetwork => state?.tcpListening;

  static Timer? _timer;
  // Через сколько назначена следующая проверка (для тестов).
  static Duration? scheduledIn;
  static Future<void> _chain = Future<void>.value();
  static bool _loaded = false;

  // Последовательно: проверка по таймеру и нажатие тумблера не пересекаются.
  static Future<T> _serial<T>(Future<T> Function() f) {
    final c = Completer<T>();
    _chain = _chain.then((_) async {
      try {
        c.complete(await f());
      } catch (e, st) {
        c.completeError(e, st);
      }
    });
    return c.future;
  }

  // Старт приложения: прочитать, закрыть открытое вне окна, запустить таймер.
  static Future<void> onStartup() async {
    await _serial(() => _check(startup: true));
    _schedule();
  }

  // Проверка по таймеру (и из тестов).
  static Future<void> check() => _serial(() => _check(startup: false));

  // Нативная сторона: изменилась настройка беспроводной отладки.
  static Future<void> onAdbWifiChanged() async {
    await check();
    _schedule();
  }

  // Тумблер «вкл» (и «продлить»): открыть 5555 на adbWindow.
  static Future<bool> open() => _serial(() async {
    await _load();
    final now = clock();
    final cur = await _installer.readAdbExposure();
    if (cur == null) {
      AppLog.log('Adb', 'открыть: нет root');
      return false;
    }
    if (!cur.tcpListening) {
      final ok = await _installer.setAdbNetwork(true);
      final after = ok ? await _await(listening: true) : cur;
      if (after == null || !after.tcpListening) {
        AppLog.log('Adb', 'открыть: порт не открылся ($after)');
        // Не оставлять свойства, которые откроют порт при следующем запуске adbd.
        await _installer.setAdbNetwork(false);
        state = await _installer.readAdbExposure();
        return false;
      }
      state = after;
    } else {
      state = cur;
    }
    final extend = tcpUntil != null && cur.tcpListening;
    await _setTcpUntil(now.add(adbWindow));
    AppLog.log(
      'Adb',
      '${extend ? 'продлено' : 'открыто'} до ${_hm(tcpUntil!)} (${state!})',
    );
    await _report('adb_network', true, extend ? 'extended' : 'service_menu');
    _schedule();
    return true;
  });

  // Тумблер «выкл»: закрыть 5555 и беспроводную отладку.
  static Future<bool> close() => _serial(() async {
    await _load();
    final cur = await _installer.readAdbExposure();
    if (cur == null) {
      AppLog.log('Adb', 'закрыть: нет root');
      return false;
    }
    var ok = true;
    if (cur.tcpListening || cur.configuredPort > 0 || cur.internetAdb || cur.persistPort) {
      ok = await _closeTcp('manual');
    } else {
      await _setTcpUntil(null);
    }
    if (cur.wifiDebug) ok = await _closeWifi('manual') && ok;
    _schedule();
    return ok;
  });

  static Future<void> _check({required bool startup}) async {
    await _load();
    final s = await _installer.readAdbExposure();
    if (s == null) return; // нет root — нечего проверять
    state = s;
    final now = clock();

    // Часы переведены назад: срок дальше, чем «сейчас + 30 мин», — обрезать.
    final cap = now.add(adbWindow);
    final tu = tcpUntil;
    if (tu != null && tu.isAfter(cap)) {
      AppLog.log('Adb', 'срок окна обрезан (часы назад): ${_hm(tu)} → ${_hm(cap)}');
      await _setTcpUntil(cap);
    }
    final wu = wifiUntil;
    if (wu != null && wu.isAfter(cap)) {
      AppLog.log('Adb', 'срок беспроводной отладки обрезан (часы назад): ${_hm(wu)} → ${_hm(cap)}');
      await _setWifiUntil(cap);
    }

    // Сетевой adb без TLS.
    final tcpOpen = s.tcpListening || s.configuredPort > 0 || s.internetAdb || s.persistPort;
    if (tcpOpen) {
      final until = tcpUntil;
      if (until == null) {
        await _closeTcp(startup ? 'startup' : 'outside_window');
      } else if (!now.isBefore(until)) {
        await _closeTcp('timer');
      }
    } else if (tcpUntil != null) {
      // Закрылся сам: при старте — перезагрузка или холодное выключение.
      AppLog.log('Adb', 'порт закрыт без приложения, окно снято ($s)');
      await _setTcpUntil(null);
      await _report('adb_network', false, startup ? 'reboot' : 'external');
    }

    // Беспроводная отладка: срок с момента, когда её увидели.
    if (s.wifiDebug) {
      final until = wifiUntil;
      if (until == null) {
        await _setWifiUntil(now.add(adbWindow));
        // Состояние — после закрытия 5555 выше (state, а не s).
        AppLog.log('Adb', 'беспроводная отладка включена, выключится в ${_hm(wifiUntil!)} ($state)');
        await _report('adb_wifi', true, startup ? 'startup' : 'detected');
      } else if (!now.isBefore(until)) {
        await _closeWifi('timer');
      }
    } else if (wifiUntil != null) {
      AppLog.log('Adb', 'беспроводная отладка выключена без приложения');
      await _setWifiUntil(null);
      await _report('adb_wifi', false, 'external');
    }
  }

  static Future<bool> _closeTcp(String reason) async {
    final ok = await _installer.setAdbNetwork(false);
    final after = ok ? await _await(listening: false) : await _installer.readAdbExposure();
    if (after != null) state = after;
    final closed = after != null && !after.tcpListening && after.configuredPort == 0;
    await _setTcpUntil(null);
    AppLog.log(
      'Adb',
      closed ? 'закрыто ($reason) ($after)' : 'закрыть не удалось ($reason) ($after)',
    );
    if (closed) await _report('adb_network', false, reason);
    return closed;
  }

  static Future<bool> _closeWifi(String reason) async {
    final ok = await _installer.disableAdbWifi();
    final after = await _installer.readAdbExposure();
    if (after != null) state = after;
    final closed = ok && after != null && !after.wifiDebug;
    if (closed) await _setWifiUntil(null);
    AppLog.log(
      'Adb',
      closed
          ? 'беспроводная отладка выключена ($reason)'
          : 'беспроводную отладку выключить не удалось ($reason) ($after)',
    );
    if (closed) await _report('adb_wifi', false, reason);
    return closed;
  }

  // adbd перезапускается не мгновенно: ждать до ~5 с нужного состояния.
  static Future<AdbExposure?> _await({required bool listening}) async {
    AdbExposure? s;
    for (var i = 0; i < 6; i++) {
      if (i > 0) await sleep(const Duration(seconds: 1));
      s = await _installer.readAdbExposure();
      if (s != null && s.tcpListening == listening) return s;
    }
    return s;
  }

  static Future<void> _report(String code, bool enabled, String reason) =>
      CloudService.report(
        CloudEventType.debugModeChanged,
        data: {'code': code, 'enabled': enabled, 'reason': reason},
      );

  // Таймер: ближайший срок окна, но не реже интервала.
  static void _schedule() {
    _timer?.cancel();
    final now = clock();
    final open = state?.anyOpen == true || tcpUntil != null || wifiUntil != null;
    var d = open ? openInterval : idleInterval;
    for (final u in [tcpUntil, wifiUntil]) {
      if (u == null) continue;
      final left = u.difference(now) + const Duration(seconds: 1);
      if (left < d) d = left.isNegative ? Duration.zero : left;
    }
    scheduledIn = d;
    _timer = Timer(d, () async {
      await check();
      _schedule();
    });
  }

  static Future<void> _load() async {
    if (_loaded) return;
    final p = await SharedPreferences.getInstance();
    final t = p.getInt(_kTcpUntil);
    final w = p.getInt(_kWifiUntil);
    tcpUntil = t == null ? null : DateTime.fromMillisecondsSinceEpoch(t);
    wifiUntil = w == null ? null : DateTime.fromMillisecondsSinceEpoch(w);
    _loaded = true;
  }

  static Future<void> _setTcpUntil(DateTime? v) async {
    tcpUntil = v;
    final p = await SharedPreferences.getInstance();
    v == null ? await p.remove(_kTcpUntil) : await p.setInt(_kTcpUntil, v.millisecondsSinceEpoch);
  }

  static Future<void> _setWifiUntil(DateTime? v) async {
    wifiUntil = v;
    final p = await SharedPreferences.getInstance();
    v == null ? await p.remove(_kWifiUntil) : await p.setInt(_kWifiUntil, v.millisecondsSinceEpoch);
  }

  static String _hm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // Тесты.
  static void resetForTest() {
    _timer?.cancel();
    _timer = null;
    scheduledIn = null;
    _chain = Future<void>.value();
    _loaded = false;
    state = null;
    tcpUntil = null;
    wifiUntil = null;
    clock = DateTime.now;
    sleep = Future<void>.delayed;
  }
}
