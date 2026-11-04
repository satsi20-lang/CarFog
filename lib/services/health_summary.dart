import '../models/app_state.dart';
import '../models/remote_limits.dart';
import 'card_terminal_service.dart';
import 'modbus_service.dart';

// Короткая сводка здоровья аппарата (RD1): уходит в облачный слепок
// (reported_config.health) для светофора клиента и в пакет диагностики.
// Значения — только коды, без показаний и без данных терминала.
//   bus_ok   — шина отвечает;
//   thermo / meter — off (не установлен) | ok (свежее годное показание) |
//                    stale (давно не было годного);
//   terminal — off | ok | down (карта MDB) | unknown (импульсный: связь не
//              проверяется).
class HealthSummary {
  HealthSummary._();

  static Map<String, dynamic> build(AppNotifier n, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final cfg = n.config;
    String fresh(bool installed, DateTime? lastOk, Duration window) {
      if (!installed) return 'off';
      if (lastOk == null) return 'stale';
      return at.difference(lastOk) <= window ? 'ok' : 'stale';
    }

    final String terminal;
    switch (cfg.paymentTerminalType) {
      case PaymentTerminalType.mdb:
        terminal = CardTerminalService.status.value.cardAvailable ? 'ok' : 'down';
      case PaymentTerminalType.pulse:
        terminal = 'unknown';
      default:
        terminal = 'off';
    }

    return {
      'bus_ok': n.busHealthy,
      'thermo': fresh(
        cfg.thermoInstalled,
        ModbusService.lastUsableTemperature?.at,
        DiagnosticsLimits.thermoFreshFor,
      ),
      'meter': fresh(
        cfg.energyMeterInstalled,
        ModbusService.lastEnergyOkAt,
        DiagnosticsLimits.meterFreshFor,
      ),
      'terminal': terminal,
    };
  }
}
