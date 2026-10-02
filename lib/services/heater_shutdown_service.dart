import '../models/app_state.dart';
import '../models/out_of_service.dart';
import 'cloud_service.dart';
import 'modbus_service.dart';
import 'out_of_service_service.dart';

// Выключение ТЭНа с подтверждением. Единая точка для всех мест, где цикл
// обрывается или заканчивается: раньше результат команды выключения нигде
// не проверялся, и неудачная запись оставляла ТЭН горящим при "выключенном"
// состоянии в памяти. Если выключение не подтвердилось даже после повторов
// (ModbusService.forceHeaterOff) — аппарат выводится из обслуживания с
// кодом heaterOffUnconfirmed (реле может быть залипшим, безопасно греть
// нельзя) и уходит hardware_error.
class HeaterShutdownService {
  HeaterShutdownService._();

  // where — откуда вызвано (для журнала). notifier == null — вызов из
  // dispose экрана без доступа к состоянию: тогда только событие в облако.
  // Возвращает true, если выключение подтверждено.
  static Future<bool> ensureOff(
    String where, {
    AppNotifier? notifier,
    bool showScreen = false,
  }) async {
    final ok = await ModbusService.forceHeaterOff();
    if (ok) return true;
    await CloudService.report(
      CloudEventType.hardwareError,
      data: {'code': 'heater_off_unconfirmed', 'where': where},
    );
    if (notifier != null) {
      await OutOfServiceService.trip(
        notifier,
        code: OutOfServiceCode.heaterOffUnconfirmed,
        details: {'where': where},
        showScreen: showScreen,
      );
    }
    return false;
  }
}
