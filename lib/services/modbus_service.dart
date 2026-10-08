import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../models/bus_map.dart';

class ModbusService {
  static const _channel = MethodChannel('com.carfog.dryfog/modbus');
  static bool _open = false;

  // Открыть порт. Вызывать один раз при старте.
  //
  // code/pid (задача "эксклюзивное открытие последовательного порта") —
  // раньше возвращался просто bool, и "порт занят другим процессом"
  // выглядело неотличимо от "порт не найден"/"нет прав": час ушёл на
  // диагностику по логу вместо одной внятной ошибки на экране. code ==
  // 'PORT_BUSY' — сигнал звать именно эту ошибку, а не общую "не открылся".
  static Future<({bool ok, String? code, int? pid})> open({
    String? port,
    int baud = BusParams.baud,
  }) async {
    final usePort = port ?? BusParams.port;
    if (BusPortPolicy.check(usePort) != BusPortCheck.ok) {
      debugPrint('ModbusService.open: порт не допускается ($usePort)');
      return (ok: false, code: 'BAD_PORT', pid: null);
    }
    try {
      final result = await _channel.invokeMethod<Map>('open', {
        'port': usePort,
        'baud': baud,
      });
      final ok = result?['ok'] as bool? ?? false;
      _open = ok;
      return (
        ok: ok,
        code: result?['code'] as String?,
        pid: result?['pid'] as int?,
      );
    } catch (e) {
      debugPrint('ModbusService.open error: $e');
      _open = false;
      return (ok: false, code: null, pid: null);
    }
  }

  static Future<void> close() async {
    try {
      await _channel.invokeMethod('close');
      _open = false;
    } catch (e) {
      debugPrint('ModbusService.close error: $e');
    }
  }

  static bool get isOpen => _open;

  // Читает ВСЕ 16 дискретных входов одной транзакцией (каналы датчиков
  // уровня — см. PumpChannel.sensorDI в bus_map.dart, IoModuleInputs —
  // монетоприёмник/терминал). Один запрос на 16 входов стоит по времени
  // столько же, сколько на 8 — служебная часть кадра одинакова.
  // null = ошибка чтения.
  static Future<List<bool>?> readAllInputs() async {
    try {
      final result = await _channel.invokeMethod<List>('readAllInputs');
      return result?.map((e) => e as bool).toList();
    } catch (e) {
      debugPrint('ModbusService.readAllInputs error: $e');
      return null;
    }
  }

  // Уровни канистр (каналы датчиков PumpChannel.sensorDI) — тонкая
  // обёртка над readAllInputs() для мест, которым не нужны остальные
  // каналы. true = есть жидкость. null = ошибка чтения (не путать с
  // настоящим "все канистры пусты").
  static Future<List<bool>?> readLevels() async {
    final all = await readAllInputs();
    if (all == null || all.length < PumpChannel.values.length) return null;
    return all.sublist(0, PumpChannel.values.length);
  }

  // Читает сигнал монетоприёмника. null — ошибка чтения (шина занята/
  // таймаут), отличается от честного false (сигнала нет) — нужно для
  // бэкоффа информационных опросов в сервисном меню.
  static Future<bool?> readCoin() async {
    try {
      return await _channel.invokeMethod<bool>('readCoin');
    } catch (e) {
      debugPrint('ModbusService.readCoin error: $e');
      return null;
    }
  }

  // Управляет одним DO. channel 0-based — полная карта в bus_map.dart:
  // PumpChannel.do_ (насосы), AuxOutput.compressorDO/heaterDO/ledGreenDO/
  // ledRedDO.
  static Future<bool> setDO(int channel, bool value) async {
    try {
      return await _channel.invokeMethod<bool>('setDO', {
            'channel': channel,
            'value': value,
          }) ??
          false;
    } catch (e) {
      debugPrint('ModbusService.setDO error: $e');
      return false;
    }
  }

  // Удобные обёртки для конкретных устройств
  static Future<bool> setPump(int flavorIndex, bool on) =>
      setDO(flavorIndex, on); // PumpChannel.values[flavorIndex].do_

  static Future<bool> setCompressor(bool on) =>
      setDO(AuxOutput.compressorDO, on);

  static Future<bool> setHeater(bool on) => setDO(AuxOutput.heaterDO, on);

  static Future<bool> setLedGreen(bool on) => setDO(AuxOutput.ledGreenDO, on);

  static Future<bool> setLedRed(bool on) => setDO(AuxOutput.ledRedDO, on);

  // Выключить ВСЕ выходы — вызывать при старте и при любой ошибке.
  static Future<bool> safeAllOff() async {
    try {
      return await _channel.invokeMethod<bool>('safeAllOff') ?? false;
    } catch (e) {
      debugPrint('ModbusService.safeAllOff error: $e');
      return false;
    }
  }

  // Выключить ТЭН и УБЕДИТЬСЯ, что он выключен (замечание ревью: результат
  // команды выключения нигде не проверялся, а реле, "запомненное" как
  // выключенное после неудачной записи, больше никто не пытался выключить).
  // Подтверждение — чтение катушки ТЭНа обратно. Если чтение не удалось, но
  // запись подтверждена устройством два раза подряд — тоже принимается
  // (шина шумит, а не реле залипло). Сначала обычные команды на один
  // выход, затем FC15 safeAllOff. false — выключение не подтверждено.
  static Future<bool> forceHeaterOff({
    int attempts = 5,
    Duration pause = const Duration(milliseconds: 100),
  }) async {
    var acks = 0;
    for (var i = 0; i < attempts; i++) {
      final wrote = i < 3 ? await setHeater(false) : await safeAllOff();
      final coils = await readCoils();
      if (coils != null && coils.length > AuxOutput.heaterDO) {
        if (!coils[AuxOutput.heaterDO]) return true;
        acks = 0;
      } else if (wrote) {
        if (++acks >= 2) return true;
      } else {
        acks = 0;
      }
      await Future.delayed(pause);
    }
    return false;
  }

  // Погасить оба индикаторных светодиода. safeAllOff их намеренно не
  // трогает (красный должен сигналить аварию), поэтому после отказа в
  // обработке зелёный "идёт обработка" оставался гореть на выведенном
  // аппарате — вызывать явно там, где цикл оборван.
  static Future<void> ledsOff() async {
    await setLedGreen(false);
    await setLedRed(false);
  }

  // Фактическое состояние всех 12 используемых выходов одной транзакцией
  // (FC01, Read Coils) — для сторожа выходов: в покое ожидается, что
  // выключено всё, и это единственный способ узнать, не поднял ли модуль
  // катушку сам (например, сразу после подачи питания). null = ошибка
  // чтения — не путать с "всё выключено".
  static Future<List<bool>?> readCoils() async {
    try {
      final result = await _channel.invokeMethod<List>('readCoils');
      return result?.map((e) => e as bool).toList();
    } catch (e) {
      debugPrint('ModbusService.readCoils error: $e');
      return null;
    }
  }

  // ============================================================
  // СКАНЕР ШИНЫ (задача "сканер шины Modbus") — произвольные
  // адрес/функция/регистр, не только устройства из SLAVE_*.
  // ============================================================

  // Быстрый пробный запрос "занят ли этот адрес" — для перебора диапазона.
  static Future<bool> scanProbe({
    required int slaveId,
    int timeoutMs = 100,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('scanProbe', {
            'slaveId': slaveId,
            'timeoutMs': timeoutMs,
          }) ??
          false;
    } catch (e) {
      debugPrint('ModbusService.scanProbe error: $e');
      return false;
    }
  }

  // funcCode — ровно номер функции Modbus: 0x01 катушки, 0x02 дискретные
  // входы, 0x03 регистры хранения, 0x04 входные регистры.
  static Future<ScanReadResult> scanRead({
    required int slaveId,
    required int funcCode,
    required int startAddr,
    required int count,
    int timeoutMs = 300,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('scanRead', {
        'slaveId': slaveId,
        'funcCode': funcCode,
        'startAddr': startAddr,
        'count': count,
        'timeoutMs': timeoutMs,
      });
      if (result == null) return const ScanReadResult(status: 'no_response');
      final status = result['status'] as String? ?? 'no_response';
      if (status != 'ok') {
        return ScanReadResult(
          status: status,
          exceptionCode: result['exceptionCode'] as int?,
        );
      }
      final raw = (result['values'] as List?) ?? const [];
      if (funcCode == 0x01 || funcCode == 0x02) {
        return ScanReadResult(
          status: 'ok',
          boolValues: raw.map((e) => e as bool).toList(),
        );
      }
      return ScanReadResult(
        status: 'ok',
        intValues: raw.map((e) => e as int).toList(),
      );
    } catch (e) {
      debugPrint('ModbusService.scanRead error: $e');
      return const ScanReadResult(status: 'no_response');
    }
  }

  static Future<bool> scanWriteRegister({
    required int slaveId,
    required int addr,
    required int value,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('scanWriteRegister', {
            'slaveId': slaveId,
            'addr': addr,
            'value': value,
          }) ??
          false;
    } catch (e) {
      debugPrint('ModbusService.scanWriteRegister error: $e');
      return false;
    }
  }

  static Future<bool> scanWriteCoil({
    required int slaveId,
    required int addr,
    required bool value,
  }) async {
    try {
      return await _channel.invokeMethod<bool>('scanWriteCoil', {
            'slaveId': slaveId,
            'addr': addr,
            'value': value,
          }) ??
          false;
    } catch (e) {
      debugPrint('ModbusService.scanWriteCoil error: $e');
      return false;
    }
  }

  // FC15 — запись нескольких катушек одним кадром. Возвращает статус, а не
  // просто bool: важно различать "нет ответа" и "ответил отказом функции"
  // (05 8F 01 — устройство не поддерживает FC15).
  static Future<({String status, int? exceptionCode})> scanWriteMultipleCoils({
    required int slaveId,
    required int addr,
    required List<bool> values,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>(
        'scanWriteMultipleCoils',
        {'slaveId': slaveId, 'addr': addr, 'values': values},
      );
      if (result == null) return (status: 'no_response', exceptionCode: null);
      return (
        status: result['status'] as String? ?? 'no_response',
        exceptionCode: result['exceptionCode'] as int?,
      );
    } catch (e) {
      debugPrint('ModbusService.scanWriteMultipleCoils error: $e');
      return (status: 'no_response', exceptionCode: null);
    }
  }

  // FC16 — запись нескольких регистров одним кадром. Нужна для устройств
  // без FC06 (Chint DDSU666 — по мануалу только 03/16, даже для одного
  // регистра). Статус вместо bool — та же причина, что у
  // scanWriteMultipleCoils: важно различить "нет ответа" от "отказ функции".
  static Future<({String status, int? exceptionCode})>
  scanWriteMultipleRegisters({
    required int slaveId,
    required int addr,
    required List<int> values,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>(
        'scanWriteMultipleRegisters',
        {'slaveId': slaveId, 'addr': addr, 'values': values},
      );
      if (result == null) return (status: 'no_response', exceptionCode: null);
      return (
        status: result['status'] as String? ?? 'no_response',
        exceptionCode: result['exceptionCode'] as int?,
      );
    } catch (e) {
      debugPrint('ModbusService.scanWriteMultipleRegisters error: $e');
      return (status: 'no_response', exceptionCode: null);
    }
  }

  // Перебор скорости порта — на каждой пробует slaveId, возвращает нашедшую
  // скорость или null, если ни на одной ответа не было. Порт закрывается
  // и переоткрывается заново на каждой скорости (иначе это не сработало
  // бы: порт уже открыт на боевой скорости, идемпотентный open() не тронул
  // бы его) и обязательно восстанавливается на originalBaud в конце —
  // независимо от результата, чтобы приложение не осталось без связи.
  static Future<int?> baudSweep({
    required int slaveId,
    List<int> bauds = const [4800, 19200, 38400, 115200],
    String? port,
    int originalBaud = BusParams.baud,
  }) async {
    final usePort = port ?? BusParams.port;
    if (BusPortPolicy.check(usePort) != BusPortCheck.ok) return null;
    try {
      return await _channel.invokeMethod<int>('baudSweep', {
        'slaveId': slaveId,
        'bauds': bauds,
        'port': usePort,
        'originalBaud': originalBaud,
      });
    } catch (e) {
      debugPrint('ModbusService.baudSweep error: $e');
      return null;
    }
  }

  // Диагностика "чётность отличается от ожидаемой" (задача "Chint
  // DDSU666: найти счётчик"). Временно переоткрывает порт с указанной
  // чётностью ('none'/'odd'/'even') — дальнейшие запросы (например,
  // сканер адресов) идут уже через неё. В отличие от baudSweep НЕ
  // восстанавливает ничего сама: вызывать повторно с parity: 'none'
  // после диагностики, иначе приложение останется без связи с боевым
  // модулем на обычных параметрах порта.
  static Future<bool> openWithParity({
    String? port,
    int baud = BusParams.baud,
    required String parity,
  }) async {
    final usePort = port ?? BusParams.port;
    if (BusPortPolicy.check(usePort) != BusPortCheck.ok) return false;
    try {
      return await _channel.invokeMethod<bool>('openWithParity', {
            'port': usePort,
            'baud': baud,
            'parity': parity,
          }) ??
          false;
    } catch (e) {
      debugPrint('ModbusService.openWithParity error: $e');
      return false;
    }
  }

  // Управляемая смена Slave ID (задача "смена Slave ID CWT-BK-1616T-S") —
  // Фаза 1: опознание (если не пропущено) + запись нового адреса +
  // фиксация. Заканчивается ПЕРЕД перезапуском питания модуля — дальше
  // ход только через changeSlaveIdPhase2, после того как оператор снимет
  // и подаст питание. "blocked" отличает "остановлено опознанием, запись
  // даже не начиналась" от прочих отказов (это разные сообщения в UI).
  static Future<ChangeSlaveIdResult> changeSlaveIdPhase1({
    required int oldAddr,
    required int newAddr,
    bool skipIdentification = false,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('changeSlaveIdPhase1', {
        'oldAddr': oldAddr,
        'newAddr': newAddr,
        'skipIdentification': skipIdentification,
      });
      if (result == null) {
        return const ChangeSlaveIdResult(ok: false, log: []);
      }
      return ChangeSlaveIdResult(
        ok: result['ok'] as bool? ?? false,
        log: ((result['log'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        blocked: result['blocked'] as bool? ?? false,
      );
    } catch (e) {
      debugPrint('ModbusService.changeSlaveIdPhase1 error: $e');
      return const ChangeSlaveIdResult(ok: false, log: []);
    }
  }

  // Фаза 2: запускается оператором кнопкой "Продолжить проверку" после
  // снятия/подачи питания на модуль — проверяет новый адрес, контрольным
  // выстрелом убеждается, что старый адрес замолчал, и снимает дамп 16
  // регистров нового адреса.
  static Future<ChangeSlaveIdPhase2Result> changeSlaveIdPhase2({
    required int oldAddr,
    required int newAddr,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('changeSlaveIdPhase2', {
        'oldAddr': oldAddr,
        'newAddr': newAddr,
      });
      if (result == null) {
        return const ChangeSlaveIdPhase2Result(ok: false, log: []);
      }
      return ChangeSlaveIdPhase2Result(
        ok: result['ok'] as bool? ?? false,
        log: ((result['log'] as List?) ?? const [])
            .map((e) => e as String)
            .toList(),
        newAddrOk: result['newAddrOk'] as bool?,
        oldAddrSilent: result['oldAddrSilent'] as bool?,
        dump: (result['dump'] as List?)?.map((e) => e as int).toList(),
      );
    } catch (e) {
      debugPrint('ModbusService.changeSlaveIdPhase2 error: $e');
      return const ChangeSlaveIdPhase2Result(ok: false, log: []);
    }
  }

  // Читает температуру термопары, канал 0-3. Возвращает °C,
  // либо null при ошибке чтения (не путать с настоящим 0°C).
  static Future<double?> readTemperature({int channel = 0}) async {
    try {
      return await _channel.invokeMethod<double>('readTemperature', {
        'channel': channel,
      });
    } catch (e) {
      debugPrint('ModbusService.readTemperature error: $e');
      return null;
    }
  }

  // Отладочная "заморозка" показания термопары (задача "детектор отказа
  // датчика температуры", часть 2, п.11). Подмена целиком на нативной
  // стороне (readTemperature отдаёт последнее прочитанное значение, шину не
  // трогает); живёт до ручного выключения, но не дольше 30 минут
  // (ModbusChannel.TEMPERATURE_FROZEN_AUTO_OFF_MS). Возвращает значение,
  // на котором заморожено, либо null (выключено / заморозить было нечем).
  static Future<double?> setTemperatureFrozen(bool value) async {
    try {
      return await _channel.invokeMethod<double>('setTemperatureFrozen', {
        'value': value,
      });
    } catch (e) {
      debugPrint('ModbusService.setTemperatureFrozen error: $e');
      return null;
    }
  }

  // Реальное состояние заморозки — вкладка "Диагностика" пересоздаётся при
  // переключении, а флаг живёт дольше неё.
  static Future<({bool frozen, double? value})> getTemperatureFrozen() async {
    try {
      final r = await _channel.invokeMethod<Map>('getTemperatureFrozen');
      return (
        frozen: r?['frozen'] as bool? ?? false,
        value: (r?['value'] as num?)?.toDouble(),
      );
    } catch (e) {
      debugPrint('ModbusService.getTemperatureFrozen error: $e');
      return (frozen: false, value: null);
    }
  }

  // Коды активных отладочных режимов — идут в регулярную отправку
  // состояния в облако (SyncService), чтобы оператор видел в веб-панели, что
  // аппарат в отладочном режиме, даже если события о включении давно
  // прошли. Аппарат, принимающий деньги, не должен уметь это спрятать.
  static Future<List<String>> activeDebugModes() async {
    final modes = <String>[];
    if (await getCoinAcceptorSimulatedDown()) {
      modes.add('simulate_coin_acceptor_down');
    }
    if ((await getTemperatureFrozen()).frozen) {
      modes.add('freeze_temperature');
    }
    return modes;
  }

  // Читает данные счётчика энергии DDS6619: voltage (В), current (А),
  // power (Вт), totalEnergy (кВт⋅ч, общий накопленный расход).
  // null = ошибка чтения (не путать с настоящим нулевым потреблением) —
  // раньше здесь была нулевая заглушка на ошибку, из-за которой расход за
  // сессию (Шаг 33, задача 1) в принципе нельзя было отличить от честного
  // "не потребили ничего": разница показаний старт/финиш с подменённым
  // нулём вместо null считалась бы неверно, а не пропускалась.
  static Future<Map<String, double>?> readEnergy() async {
    try {
      final result = await _channel.invokeMethod<Map>('readEnergy');
      if (result == null) return null;
      return result.map((k, v) => MapEntry(k as String, (v as num).toDouble()));
    } catch (e) {
      debugPrint('ModbusService.readEnergy error: $e');
      return null;
    }
  }

  // Расход за текущий календарный месяц (кВт⋅ч).
  static Future<double> getMonthlyEnergy() async {
    try {
      return await _channel.invokeMethod<double>('getMonthlyEnergy') ?? 0.0;
    } catch (e) {
      debugPrint('ModbusService.getMonthlyEnergy error: $e');
      return 0.0;
    }
  }

  // Расход за прошлый (уже завершившийся) календарный месяц (кВт⋅ч).
  static Future<double> getPreviousMonthEnergy() async {
    try {
      return await _channel.invokeMethod<double>('getPreviousMonthEnergy') ??
          0.0;
    } catch (e) {
      debugPrint('ModbusService.getPreviousMonthEnergy error: $e');
      return 0.0;
    }
  }

  // История расхода по месяцам: JSON-строка вида
  // [{"year":2026,"month":7,"kwh":12.34}, ...], не более 12 записей.
  static Future<String> getEnergyHistory() async {
    try {
      return await _channel.invokeMethod<String>('getEnergyHistory') ?? '[]';
    } catch (e) {
      debugPrint('ModbusService.getEnergyHistory error: $e');
      return '[]';
    }
  }

  // Приём оплаты заблокирован (задача "вывод аппарата из обслуживания",
  // требование 8): выставляется AppNotifier при выводе из обслуживания.
  // Проверяется ЗДЕСЬ, в самом платёжном сервисе, а не только на экране
  // ожидания — ни таймеры, ни автовозврат по неактивности, ни отладочные
  // переключатели не должны сделать опрос монетоприёмника достижимым.
  static bool paymentBlocked = false;

  // Запускает фоновый счётчик импульсов монетоприёмника (экран оплаты).
  static Future<void> startPaymentCoinCounting() async {
    if (paymentBlocked) {
      debugPrint('ModbusService.startPaymentCoinCounting: заблокировано '
          '(аппарат выведен из обслуживания)');
      return;
    }
    try {
      await _channel.invokeMethod('startPaymentCoinCounting');
    } catch (e) {
      debugPrint('ModbusService.startPaymentCoinCounting error: $e');
    }
  }

  // Останавливает фоновый счётчик — обязательно вызывать при уходе с экрана оплаты.
  static Future<void> stopPaymentCoinCounting() async {
    try {
      await _channel.invokeMethod('stopPaymentCoinCounting');
    } catch (e) {
      debugPrint('ModbusService.stopPaymentCoinCounting error: $e');
    }
  }

  // Разом: номинал последней принятой монеты (0 = новой монеты нет),
  // счётчик неудачных чтений DI8 за текущее окно оплаты и флаг "приём
  // монет отказал" (задача "контроль цикла по электросчётчику, готовность
  // оплаты" — "отказ вместо недосчёта", п.2-3). down взводится один раз
  // за окно и снимается только новым startPaymentCoinCounting().
  static Future<({int cents, int failureCount, bool down})>
  getCoinAcceptorStatus() async {
    try {
      final result = await _channel.invokeMethod<Map>('getCoinAcceptorStatus');
      return (
        cents: result?['cents'] as int? ?? 0,
        failureCount: result?['failureCount'] as int? ?? 0,
        down: result?['down'] as bool? ?? false,
      );
    } catch (e) {
      debugPrint('ModbusService.getCoinAcceptorStatus error: $e');
      return (cents: 0, failureCount: 0, down: false);
    }
  }

  // Сервисное меню, вкладка "Диагностика" — отладочный переключатель
  // "имитировать отказ монетоприёмника": подделывает getCoinAcceptorStatus()
  // на нативной стороне без единого обращения к шине, чтобы проверить
  // ветку отказа (доплата картой / уход в error.dart) сколько угодно раз
  // одинаково, не рискуя железом. Специально НЕ сбрасывается при уходе с
  // вкладки — тест проверяется на реальном экране оплаты, за пределами
  // сервисного меню; живёт до ручного выключения, но не дольше 30 минут
  // (ModbusChannel.COIN_SIMULATED_DOWN_AUTO_OFF_MS — страховка от забытого
  // тумблера); перезапуск приложения тоже сбрасывает.
  static Future<void> setCoinAcceptorSimulatedDown(bool value) async {
    try {
      await _channel.invokeMethod('setCoinAcceptorSimulatedDown', {
        'value': value,
      });
    } catch (e) {
      debugPrint('ModbusService.setCoinAcceptorSimulatedDown error: $e');
    }
  }

  // Реальное состояние флага выше — вкладка "Диагностика" пересоздаёт своё
  // состояние при каждом переключении (см. комментарий у _simulateCoinDown
  // в service_menu.dart), а флаг переживает это переключение, так что
  // тумблер обязан спросить нативную сторону при инициализации, а не
  // молча считать, что всё выключено.
  static Future<bool> getCoinAcceptorSimulatedDown() async {
    try {
      return await _channel.invokeMethod<bool>(
            'getCoinAcceptorSimulatedDown',
          ) ??
          false;
    } catch (e) {
      debugPrint('ModbusService.getCoinAcceptorSimulatedDown error: $e');
      return false;
    }
  }

  // Один опрос платёжного терминала: читает канал, определяет фронт и
  // защитную паузу на стороне Kotlin (состояние между тиками хранится
  // там), пишет в журнал. Опрашивать часто — обязанность вызывающего
  // (Timer.periodic на стороне Dart), сам метод не заводит поток.
  static Future<TerminalPoll?> pollTerminal({
    required int channel,
    required String mode,
    required int guardMs,
  }) async {
    try {
      final result = await _channel.invokeMethod<Map>('pollTerminal', {
        'channel': channel,
        'mode': mode,
        'guardMs': guardMs,
      });
      if (result == null) return null;
      return TerminalPoll(
        state: result['state'] as bool,
        confirmed: result['confirmed'] as bool,
      );
    } catch (e) {
      debugPrint('ModbusService.pollTerminal error: $e');
      return null;
    }
  }

  // Журнал сигнала терминала — кольцевой буфер строк для калибровки
  // (вкладка "Датчики" сервисного меню).
  static Future<List<String>> getTerminalJournal() async {
    try {
      final raw = await _channel.invokeMethod<List>('getTerminalJournal');
      return raw?.map((e) => e as String).toList() ?? [];
    } catch (e) {
      debugPrint('ModbusService.getTerminalJournal error: $e');
      return [];
    }
  }

  static Future<void> clearTerminalJournal() async {
    try {
      await _channel.invokeMethod('clearTerminalJournal');
    } catch (e) {
      debugPrint('ModbusService.clearTerminalJournal error: $e');
    }
  }
}

// Результат одного pollTerminal(): текущее сырое состояние входа и признак
// "именно этим тиком засчитана оплата" (уже с учётом режима и защитной
// паузы — см. ModbusChannel.pollTerminalEdge на нативной стороне).
class TerminalPoll {
  final bool state;
  final bool confirmed;

  const TerminalPoll({required this.state, required this.confirmed});
}

// Результат scanRead (сканер шины) — статус различает три причины
// неудачи (задача "сканер шины", 1.7), а не сводит их к одному "не
// получилось":
//   'ok'          — данные получены, см. boolValues/intValues
//   'no_response' — устройство не ответило вовсе
//   'bad_crc'     — ответ пришёл, но контрольная сумма не сошлась
//   'exception'   — устройство ответило кодом ошибки, см. exceptionCode
class ScanReadResult {
  final String status;
  final int? exceptionCode;
  final List<bool>? boolValues; // funcCode 0x01/0x02
  final List<int>? intValues; // funcCode 0x03/0x04, беззнаковые 0..65535

  const ScanReadResult({
    required this.status,
    this.exceptionCode,
    this.boolValues,
    this.intValues,
  });
}

// Результат фазы 1 смены Slave ID — построчный лог и итог. "blocked":
// true означает, что запись не начиналась вообще (сигнатура не совпала
// или порт не открыт) — отличается от "ok: false" после уже начатой
// записи, которая требует другого сообщения технику.
class ChangeSlaveIdResult {
  final bool ok;
  final List<String> log;
  final bool blocked;

  const ChangeSlaveIdResult({
    required this.ok,
    required this.log,
    this.blocked = false,
  });
}

// Результат фазы 2 — после того как оператор снял/подал питание на
// модуль и нажал "Продолжить проверку".
class ChangeSlaveIdPhase2Result {
  final bool ok;
  final List<String> log;
  final bool? newAddrOk;
  final bool? oldAddrSilent;
  final List<int>? dump;

  const ChangeSlaveIdPhase2Result({
    required this.ok,
    required this.log,
    this.newAddrOk,
    this.oldAddrSilent,
    this.dump,
  });
}
