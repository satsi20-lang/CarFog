import 'dart:async';
import '../models/app_state.dart';
import 'cloud_service.dart';
import 'modbus_service.dart';

// Гарантированное выключение оборудования при старте (задача "гарантия
// выключения при старте"). Раньше main.dart открывал порт и вызывал
// safeAllOff() один раз, не проверяя результат — ModbusService по
// устройству проглатывает ошибки и возвращает безопасное значение, так что
// при холодном старте, когда порт/шина ещё не готовы, выключение молча не
// происходило и никто об этом не узнавал. Выходы оставались в том
// состоянии, в котором их поднял сам модуль при подаче питания — включая
// ТЭН на 2 кВт.
//
// Аппаратные меры (руками, вне этого кода) остаются обязательными и не
// заменяются программными: состояние выходов модуля MBSL16DI16DO при
// подаче питания должно быть выставлено в "все выключены", и в разрыв
// силовой линии ТЭНа должен стоять нормально замкнутый термовыключатель
// 260-280°C. Программная защита не спасает при мёртвой шине — аппаратная
// спасает всегда.
class StartupService {
  static const _port = '/dev/ttyS5'; // уточнить после find_port.py

  // Первые попытки — часто (шина может ответить уже через пару секунд
  // после подачи питания), дальше интервал растёт — не молотить шину
  // впустую, если модуль не отвечает вовсе.
  static const _fastAttempts = 5;
  static const _fastDelay = Duration(seconds: 2);
  static const _slowDelay = Duration(seconds: 20);

  // Сообщать в облако не на первой же попытке — порт открывается не
  // мгновенно после подачи питания, это нормально и не авария.
  static const _reportAfterAttempts = 5;

  // Открыть порт, выключить все выходы, ПРОВЕРИТЬ результат — и повторять
  // неограниченно долго, пока не получится. Аппарат, который не может
  // управлять оборудованием, не имеет права считать себя работоспособным
  // (см. AppNotifier.busHealthy — до первого успеха здесь остаётся false,
  // и AppNotifier.selectFlavor не пускает клиента дальше выбора аромата).
  static Future<void> ensureSafeStartup(AppNotifier notifier) async {
    var attempt = 0;
    var opened = false;
    var reported = false;

    while (true) {
      attempt++;

      // Порт открываем только пока это не удалось — повторный успешный
      // open() создавал бы новое подключение поверх уже рабочего без
      // необходимости (лишний файловый дескриптор на каждой попытке).
      if (!opened) {
        opened = await ModbusService.open(port: _port);
      }

      final ok = opened && await ModbusService.safeAllOff();
      if (ok) {
        notifier.setBusHealthy(true);
        // Если до этого уже сообщали об аварии — зафиксировать и
        // восстановление тем же типом события: по паре записей с
        // временными метками видно, сколько длился опасный промежуток
        // (задача 2.5).
        if (reported) {
          await CloudService.report(
            CloudEventType.hardwareError,
            data: {'code': 'startup_shutdown_recovered', 'attempts': attempt},
          );
        }
        return;
      }

      if (!reported && attempt >= _reportAfterAttempts) {
        reported = true;
        await CloudService.report(
          CloudEventType.hardwareError,
          data: {
            'code': opened ? 'startup_shutdown_failed' : 'modbus_open_failed',
            'attempts': attempt,
            'port': _port,
          },
        );
      }

      await Future.delayed(attempt <= _fastAttempts ? _fastDelay : _slowDelay);
    }
  }
}
