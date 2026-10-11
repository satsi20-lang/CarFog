// Сетевой adb: фактическое состояние и команды (docs/kiosk_device_owner.md,
// раздел «Сетевой adb»).
//
// На прошивках Rockchip порт 5555 открывают ТРИ свойства, а не одно:
//  * persist.internet_adb_enable=1 — правило init (init.rk30board.rc) ставит
//    service.adb.tcp.port=5555 и перезапускает adbd, переживает перезагрузку;
//  * service.adb.tcp.port — то, что adbd читает первым (до перезагрузки);
//  * persist.adb.tcp.port — adbd читает, только если service.* пусто.
// adbd читает порт только при своём запуске, поэтому истина — не свойства, а
// слушающий сокет в /proc/net/tcp{,6}; свойства лишь объясняют причину.
//
// ro.adb.secure на CARFOG-100 не задано: adbd не проверяет ключ ни на 5555,
// ни на беспроводной отладке (TLS). Защита — только в том, что порт закрыт.

// Порт сетевого adb без TLS, который открывает приложение.
const int adbTcpPort = 5555;

// Сколько живёт окно, открытое тумблером, и беспроводная отладка.
const Duration adbWindow = Duration(minutes: 30);

class AdbExposure {
  // adbd слушает TCP без TLS (5555 или порт из свойств).
  final bool tcpListening;
  // Порт по свойствам, как его выберет adbd при запуске (0 — нет).
  final int configuredPort;
  // Откуда порт: internet_adb | service_port | persist_port | none.
  final String source;
  // Беспроводная отладка Android включена (settings adb_wifi_enabled).
  final bool wifiDebug;
  // Порт беспроводной отладки и слушается ли он.
  final int? tlsPort;
  final bool tlsListening;
  // adbd требует ключ (ro.adb.secure=1). На CARFOG-100 — false.
  final bool authRequired;
  // Сокеты прочитаны; иначе tcpListening выведен из свойств.
  final bool socketsKnown;
  // Сырые свойства (для журнала и разбора расхождений).
  final bool internetAdb;
  final bool persistPort;

  const AdbExposure({
    required this.tcpListening,
    required this.configuredPort,
    required this.source,
    required this.wifiDebug,
    required this.tlsPort,
    required this.tlsListening,
    required this.authRequired,
    required this.socketsKnown,
    required this.internetAdb,
    required this.persistPort,
  });

  // Свойства говорят одно, сокет другое (adbd не перезапущен после смены).
  bool get mismatch => socketsKnown && tcpListening != (configuredPort > 0);

  // Что-нибудь из сетевого adb открыто.
  bool get anyOpen => tcpListening || wifiDebug;

  Map<String, Object?> toJson() => {
    'tcp_listening': tcpListening,
    'port': configuredPort,
    'source': source,
    'wifi_debug': wifiDebug,
    'tls_port': tlsPort,
    'tls_listening': tlsListening,
    'auth_required': authRequired,
    'sockets_known': socketsKnown,
    'mismatch': mismatch,
  };

  @override
  String toString() =>
      'tcp=${tcpListening ? 'listen' : 'closed'} port=$configuredPort '
      'source=$source wifi=${wifiDebug ? 1 : 0} tls=${tlsPort ?? '-'} '
      'auth=${authRequired ? 1 : 0}${mismatch ? ' MISMATCH' : ''}';

  // Разбор вывода adbProbeCommand. null — вывод не тот (нет маркеров).
  static AdbExposure? parse(String out) {
    final props = <String, String>{};
    final listen = <int>{};
    var inSockets = false;
    var sawProps = false;
    for (final raw in out.split('\n')) {
      final line = raw.trim();
      if (line == _socketsMarker) {
        inSockets = true;
        continue;
      }
      if (inSockets) {
        final port = _listenPort(line);
        if (port != null) listen.add(port);
        continue;
      }
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      props[line.substring(0, eq)] = line.substring(eq + 1).trim();
      sawProps = true;
    }
    if (!sawProps) return null;

    final internet = props['internet_adb'] == '1';
    final service = props['service_port'] ?? '';
    final persist = props['persist_port'] ?? '';
    // Как adbd: service.adb.tcp.port, если не пусто, иначе persist.*.
    var port = 0;
    var source = 'none';
    if (service.isNotEmpty) {
      port = int.tryParse(service) ?? 0;
      if (port > 0) {
        source = internet && port == adbTcpPort ? 'internet_adb' : 'service_port';
      }
    } else if (persist.isNotEmpty) {
      port = int.tryParse(persist) ?? 0;
      if (port > 0) source = 'persist_port';
    }
    if (port <= 0) port = 0;
    final adbdRunning = props['adbd'] == 'running';
    final configured = adbdRunning ? port : 0;

    final tlsPort = int.tryParse(props['tls_port'] ?? '');
    final socketsKnown = inSockets;
    final tcpListening = socketsKnown
        ? (listen.contains(adbTcpPort) && tlsPort != adbTcpPort) ||
            (configured > 0 && configured != tlsPort && listen.contains(configured))
        : configured > 0;

    return AdbExposure(
      tcpListening: tcpListening,
      configuredPort: configured,
      source: configured > 0 ? source : 'none',
      wifiDebug: props['adb_wifi'] == '1',
      tlsPort: tlsPort != null && tlsPort > 0 ? tlsPort : null,
      tlsListening: tlsPort != null && tlsPort > 0 && listen.contains(tlsPort),
      authRequired: props['secure'] == '1',
      socketsKnown: socketsKnown,
      internetAdb: internet,
      persistPort: persist.isNotEmpty && persist != '0',
    );
  }

  // Строка /proc/net/tcp{,6}: "N: LOCAL:PORT REMOTE:PORT ST …", ST=0A — LISTEN.
  static int? _listenPort(String line) {
    final f = line.split(RegExp(r'\s+'));
    if (f.length < 4 || f[3] != '0A') return null;
    final local = f[1];
    final c = local.lastIndexOf(':');
    if (c < 0) return null;
    return int.tryParse(local.substring(c + 1), radix: 16);
  }
}

const String _socketsMarker = '--listen--';

// Чтение состояния: свойства и только слушающие сокеты (вывод RootShell
// ограничен 8 КБ — полную таблицу соединений не тащим).
const String adbProbeCommand =
    'echo "internet_adb=\$(getprop persist.internet_adb_enable)"; '
    'echo "service_port=\$(getprop service.adb.tcp.port)"; '
    'echo "persist_port=\$(getprop persist.adb.tcp.port)"; '
    'echo "adbd=\$(getprop init.svc.adbd)"; '
    'echo "adb_wifi=\$(settings get global adb_wifi_enabled)"; '
    'echo "tls_port=\$(getprop service.adb.tls.port)"; '
    'echo "secure=\$(getprop ro.adb.secure)"; '
    'echo "$_socketsMarker"; '
    "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep ' 0A '; "
    'true';

// Снять persist.internet_adb_enable=1 и дождаться правила init (оно само
// ставит service.adb.tcp.port=0 и перезапускает adbd) — иначе правило может
// сработать ПОСЛЕ нашей записи порта и перетереть её.
const String _dropInternetAdb =
    'if [ "\$(getprop persist.internet_adb_enable)" = "1" ]; then '
    'setprop persist.internet_adb_enable 0; i=0; '
    'while [ "\$(getprop service.adb.tcp.port)" != "0" ] && [ \$i -lt 30 ]; '
    'do sleep 0.1; i=\$((i+1)); done; fi; ';

// Открыть 5555 до перезагрузки: только service.* (persist.* очищаются),
// перезагрузка или холодное выключение закрывают порт сами.
const String adbOpenCommand =
    "setprop persist.adb.tcp.port ''; "
    '$_dropInternetAdb'
    'settings put global adb_enabled 1; '
    'setprop service.adb.tcp.port $adbTcpPort; '
    'setprop ctl.restart adbd';

// Закрыть: все три свойства и перезапуск adbd (он читает порт только при
// запуске). adb_enabled не трогаем — USB и беспроводная отладка не наше.
const String adbCloseCommand =
    "setprop persist.adb.tcp.port ''; "
    '$_dropInternetAdb'
    'setprop service.adb.tcp.port 0; '
    'setprop ctl.restart adbd';

// Выключить беспроводную отладку Android (system_server гасит TLS-порт).
const String adbWifiOffCommand = 'settings put global adb_wifi_enabled 0';
