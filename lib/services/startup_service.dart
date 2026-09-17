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
//
// Правка (задача "починить обмен по шине"): цикл раньше мог вызывать
// ModbusService.open() повторно при каждой неудаче safeAllOff() — на
// нативной стороне (см. ModbusChannel.openPort) это теперь идемпотентно и
// безопасно само по себе, но цикл здесь ВСЁ РАВНО переписан так, чтобы не
// полагаться только на это: порт открывается один раз ДО цикла, дальше
// повторяется только сама команда выключения, а переоткрытие происходит
// только после нескольких подряд неудачных команд — не на каждую
// единичную.
class StartupService {
  static const _port = '/dev/ttyS5'; // уточнить после find_port.py

  // Первые попытки — часто (шина может ответить уже через пару секунд
  // после подачи питания), дальше интервал растёт — не молотить шину
  // впустую, если модуль не отвечает вовсе. Обе паузы ≥ 1 секунды —
  // цикл без паузы забивает шину и мешает сам себе.
  static const _fastAttempts = 5;
  static const _fastDelay = Duration(seconds: 2);
  static const _slowDelay = Duration(seconds: 20);

  // Сообщать в облако не на первой же попытке — порт открывается не
  // мгновенно после подачи питания, это нормально и не авария.
  static const _reportAfterAttempts = 5;

  // Переоткрывать порт только после стольки подряд неудачных команд, не
  // на каждую единичную — единичная неудача на загруженной шине бывает и
  // в норме.
  static const _reopenAfterFailures = 5;

  // Открыть порт ОДИН раз, дальше в цикле повторять только команду
  // выключения — и повторять неограниченно долго, пока не получится.
  // Аппарат, который не может управлять оборудованием, не имеет права
  // считать себя работоспособным (см. AppNotifier.busHealthy — до
  // первого успеха здесь остаётся false, и AppNotifier.selectFlavor не
  // пускает клиента дальше выбора аромата).
  static Future<void> ensureSafeStartup(AppNotifier notifier) async {
    var attempt = 0;
    var reported = false;
    var consecutiveCommandFailures = 0;

    var opened = await ModbusService.open(port: _port);

    while (true) {
      attempt++;

      // Успех определяется ответом самой команды выключения (эхо
      // запроса на каждый из 12 каналов, см. ModbusRtu.writeSingleCoil/
      // ModbusChannel "safeAllOff") — не чтением катушек. Поведение
      // чтения катушек на конкретном модуле не подтверждено, и если оно
      // ведёт себя иначе, чем ожидалось, такая проверка проваливалась бы
      // всегда, и цикл не завершился бы никогда.
      final ok = opened && await ModbusService.safeAllOff();
      if (ok) {
        notifier.setBusHealthy(true);
        // Если до этого уже сообщали об аварии — зафиксировать и
        // восстановление тем же типом события: по паре записей с
        // временными метками видно, сколько длился опасный промежуток.
        if (reported) {
          await CloudService.report(
            CloudEventType.hardwareError,
            data: {'code': 'startup_shutdown_recovered', 'attempts': attempt},
          );
        }
        return;
      }

      consecutiveCommandFailures = opened ? consecutiveCommandFailures + 1 : 0;

      // Переоткрыть порт — только после серии неудач самой команды, а не
      // при каждой единичной. ModbusService.open() на нативной стороне
      // сам закроет предыдущий экземпляр перед пересозданием (идемпотентно,
      // без утечки дескриптора) — здесь достаточно просто вызвать его
      // снова, когда решили, что переоткрытие оправдано.
      if (!opened || consecutiveCommandFailures >= _reopenAfterFailures) {
        consecutiveCommandFailures = 0;
        opened = await ModbusService.open(port: _port);
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
