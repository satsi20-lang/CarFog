package com.example.dry_fog_app

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class ModbusChannel(private val channel: MethodChannel, private val context: Context) :
    MethodChannel.MethodCallHandler {

    // Порт принадлежит процессу (BusPortRegistry), а не этому экземпляру:
    // канал видит его, только пока он владелец (последний открывший).
    private val registry get() = ProcessBus.registry
    private val modbus: ModbusRtu? get() = registry.busFor(this)

    init {
        ProcessBus.init(context)
    }

    // Slave IDs согласно схеме проекта
    private val SLAVE_DIO = 5        // CWT-BK-1616 (плата BSM-1616RB), адрес сменён с 1 на 5
    private val SLAVE_THERMO = 1     // HLS-KWL-4TC заводской адрес, конфликт устранён
    private val SLAVE_ENERGY = 3     // DDS6619-039

    // Показания энергосчётчика, прочитанные недавно — переиспользуются между
    // readEnergy() и getMonthlyEnergy(), чтобы не гонять по шине один и тот же
    // набор из 4 транзакций дважды подряд (см. readEnergyValues()).
    private var energyCache: Map<String, Double>? = null
    private var energyCacheTime: Long = 0L
    private val ENERGY_CACHE_MAX_AGE_MS = 2000L

    companion object {
        // Открытый объект работы с шиной (один на процесс, BusPortRegistry) —
        // нужен аварийному обработчику (DryFogApplication) для прямого доступа
        // к порту в обход MethodChannel/Flutter, когда Dart уже нерабочий.
        val activeBus: ModbusRtu? get() = ProcessBus.registry.current

        // Дублирует SLAVE_DIO как доступный статически — тот же адрес,
        // аварийному обработчику нужен вне экземпляра ModbusChannel.
        const val SLAVE_DIO_STATIC = 5

        private const val TAG = "ModbusChannel"

        // Эталонная сигнатура модуля ввода-вывода CWT-BK-1616 (плата
        // BSM-1616RB) — регистры 0x000C-0x000F, сняты дампом живого модуля
        // 2026-09-27 при смене адреса 1→5 (задача "правки визарда смены
        // Slave ID по итогам живого прогона"). Природа значений не
        // установлена (похоже на версию прошивки/серийный номер), но они
        // стабильны и не совпадают с другими устройствами на шине —
        // используются только чтобы отличить модуль ввода-вывода от
        // постороннего устройства на указанном адресе перед опасной
        // записью в служебные регистры.
        val DIO_SIGNATURE = intArrayOf(0x4307, 0x312D, 0x4D54, 0x4354)

        // Монетоприёмник — калибровка импульсов DI8. Зеркало
        // CoinAcceptorCalibration (lib/models/bus_map.dart) — платформенный
        // канал не даёт общий файл констант, см. заголовок bus_map.dart.
        // Приёмник физически заменён 2026-08-21 (docs/coin_acceptor.md):
        // 1 импульс → 1€, 2 и более → 2€. Старая калибровка (2/4 импульса)
        // относилась к демонтированному устройству.
        const val COIN_CENTS_FOR_1_PULSE = 100
        const val COIN_CENTS_FOR_2_PLUS_PULSES = 200
        const val COIN_POLL_INTERVAL_MS = 80L
        const val COIN_POLL_TIMEOUT_MS = 150L
        // Пауза между импульсами внутри одной монеты, после которой серия
        // считается завершённой — подобрано по факту (см. bus_map.dart:
        // реальные паузы доходили до ~430 мс, порог 350 мс рвал монету).
        const val COIN_SERIES_GAP_MS = 600L
        // Порог неудачных чтений ПОДРЯД (уже после немедленного повтора
        // каждой), после которого окно приёма монет закрывается — "отказ
        // вместо недосчёта" (задача "готовность оплаты", п.3). Не измерено,
        // взято по порядку величины: при таймауте 150 мс на попытку это
        // около 1,5 с устойчивой тишины на шине — достаточно, чтобы
        // отличить реальную проблему связи от одиночного сбоя.
        const val COIN_MAX_CONSECUTIVE_FAILURES = 5

        // Страховка отладочного тумблера "имитировать отказ монетоприёмника"
        // (задача "контроль цикла по электросчётчику", фаза 2) — 30 минут с
        // огромным запасом хватает на любой реальный тест на стенде, а
        // аппарат, забытый в этом режиме на смену, не должен молча терять
        // монетную выручку.
        const val COIN_SIMULATED_DOWN_AUTO_OFF_MS = 30 * 60 * 1000L

        // То же правило для отладочного тумблера "заморозить показание
        // температуры" (задача "детектор отказа датчика температуры"):
        // подмена показания термопары на аппарате, который принимает
        // деньги, не должна уметь спрятаться и жить месяцами.
        const val TEMPERATURE_FROZEN_AUTO_OFF_MS = 30 * 60 * 1000L

        // Термопара HLS-KWL-4TC — регистр знаковый (см. readHoldingRegisters,
        // возвращает беззнаковое 0..65535). toShort() реинтерпретирует как
        // знаковое 16-бит перед делением на 10, иначе -7.6°C превращается в
        // бессмысленные +6546.0°C (задача "контроль цикла по электросчётчику").
        fun parseThermocoupleRaw(raw: Int): Double = raw.toShort().toDouble() / 10.0
    }

    // Единственная точка фактического открытия порта (задача "починить
    // обмен по шине", 1.1-1.4). @Synchronized — защита от одновременного
    // вызова из разных мест (1.3); MethodChannel-вызовы и так сериализованы
    // через общую фоновую очередь, но это дешёвая и явная гарантия, а не
    // расчёт на побочное свойство очереди.
    //
    // Идемпотентно: если порт уже открыт и жив — просто отвечает true, не
    // трогая существующий экземпляр (не закрывает, не создаёт новый, не
    // перезапускает stty на уже открытом порту — вторая беда из описания
    // задачи). Если переоткрытие действительно нужно (порт не был открыт,
    // либо предыдущий экземпляр закрыт/мёртв) — старый экземпляр сначала
    // явно закрывается, чтобы не терять файловый дескриптор.
    //
    // Каждое фактическое открытие/закрытие — в лог с причиной (1.4): по
    // логу сразу видно, сколько раз порт реально переоткрывался, не
    // вычисляя это по косвенным симптомам вроде "устройство не отвечает".
    //
    // Возвращает ModbusRtu.OpenResult, а не Boolean (задача "эксклюзивное
    // открытие последовательного порта") — "порт занят другим процессом"
    // раньше было неотличимо от "порт не найден"/"нет прав": оба варианта
    // одинаково молча проваливались в один и тот же false.
    @Synchronized
    private fun openPort(port: String, baud: Int, reason: String): ModbusRtu.OpenResult {
        // Идемпотентность и владение — в BusPortRegistry (задача
        // "устойчивость шины"): порт, уже открытый этим процессом (в том
        // числе другим движком Flutter), переиспользуется, а не даёт
        // PORT_BUSY с собственным PID.
        val result = registry.open(this, port, baud)
        when (result) {
            is ModbusRtu.OpenResult.Ok ->
                Log.d(TAG, "openPort: порт открыт ($port, причина: $reason)")
            is ModbusRtu.OpenResult.Busy -> Log.e(
                TAG,
                "openPort: порт занят другим процессом ($port, причина: $reason, " +
                    "pid=${result.holderPid})"
            )
            is ModbusRtu.OpenResult.Failed ->
                Log.e(TAG, "openPort: не удалось открыть ($port, причина: $reason)")
        }
        return result
    }

    // Процедура смены Slave ID (задача "правки визарда смены Slave ID по
    // итогам живого прогона" — переписана после живого теста на реальном
    // модуле, старая версия ошибочно трактовала два штатных признака как
    // отказ). Разбита на две фазы с остановкой между ними: применение
    // нового адреса требует снятия и подачи питания на модуль, и сколько
    // это займёт у оператора — неизвестно, поэтому Dart-сторона хранит
    // состояние между фазами не в памяти, а в SharedPreferences (переживает
    // не только сворачивание, но и перезапуск процесса).
    //
    // Фаза 1 — опознание (если не пропущено) + запись адреса + фиксация:
    //  1а. Код скорости 0x0002: значение 3 — это Chint DDSU666 (счётчик,
    //      следующий на этой шине), а не модуль ввода-вывода — стоп сразу,
    //      без чтения сигнатуры (дешевле).
    //  1б. Чтение сигнатуры 0x000C-0x000F по oldAddr, сверка с DIO_SIGNATURE.
    //     Несовпадение или отказ чтения — стоп, запись не начинается вообще.
    //  2. Запись newAddr в 0x0000 на oldAddr (FC06) — эхо должно прийти,
    //     это подтверждено на живом модуле; код исключения или тишина здесь
    //     — реальная ошибка, стоп.
    //  3. Пауза 200 мс.
    //  4. Фиксация: запись 111 в 0x0009 на oldAddr (FC06). Код исключения —
    //     ошибка, стоп. Тишина — ШТАТНОЕ поведение (модуль в этот момент
    //     пишет EEPROM и не обслуживает UART), не ошибка, идём дальше.
    // Регистр 0x0009 командный и самоочищающийся — всегда читается как 0,
    // поэтому здесь и не должно быть никакой проверки чтением этого
    // регистра ни в фазе 1, ни в фазе 2.
    private fun changeSlaveIdPhase1(
        oldAddr: Int,
        newAddr: Int,
        skipIdentification: Boolean,
    ): Map<String, Any?> {
        val log = mutableListOf<String>()
        val bus = modbus
        if (bus == null) {
            log.add("Порт не открыт — операция невозможна.")
            return mapOf("ok" to false, "log" to log, "blocked" to true)
        }

        if (!skipIdentification) {
            // Второй слой опознания, перед сигнатурой: код скорости в
            // 0x0002 — тот же регистр, что и у модуля ввода-вывода, но
            // разная кодировка у разных производителей. CWT-BK-1616 отдаёт
            // 96 (9600 бод / 100), счётчик Chint DDSU666 — 3 (собственная
            // кодировка производителя, тоже 9600 бод). Следующее устройство
            // на этой шине — именно DDSU666, дешевле поймать это одним
            // регистром, чем читать все четыре сигнатуры ради того же
            // вывода.
            log.add("Опознание: проверка кода скорости (0x0002) по адресу $oldAddr…")
            val speedProbe = bus.scanTransact(oldAddr, 0x03, 0x0002, 1, 300L)
            if (speedProbe.status == "ok" && speedProbe.data != null) {
                val speedCode =
                    ((speedProbe.data[0].toInt() and 0xFF) shl 8) or
                        (speedProbe.data[1].toInt() and 0xFF)
                if (speedCode == 3) {
                    log.add(
                        "Код скорости 0x0002 = 3 — кодировка энергосчётчика Chint " +
                            "DDSU666 (модуль ввода-вывода вернул бы 96 на той же " +
                            "скорости). На адресе $oldAddr отвечает энергосчётчик, " +
                            "а не модуль ввода-вывода. Запись отменена."
                    )
                    return mapOf("ok" to false, "log" to log, "blocked" to true)
                }
            }

            log.add("Опознание: чтение сигнатуры (0x000C–0x000F) по адресу $oldAddr…")
            val sig = bus.scanTransact(oldAddr, 0x03, 0x000C, 4, 300L)
            if (sig.status != "ok" || sig.data == null) {
                log.add(
                    "Не удалось прочитать сигнатуру (${sig.status}) — " +
                        "на адресе $oldAddr нет ответа. Запись отменена."
                )
                return mapOf("ok" to false, "log" to log, "blocked" to true)
            }
            val values = IntArray(4) { i ->
                ((sig.data[i * 2].toInt() and 0xFF) shl 8) or (sig.data[i * 2 + 1].toInt() and 0xFF)
            }
            if (!values.contentEquals(DIO_SIGNATURE)) {
                val got = values.joinToString(" ") { "0x%04X".format(it) }
                log.add(
                    "Сигнатура не совпадает (получено $got) — на адресе $oldAddr " +
                        "отвечает устройство с другой сигнатурой. Это не модуль " +
                        "ввода-вывода. Запись отменена."
                )
                return mapOf("ok" to false, "log" to log, "blocked" to true)
            }
            log.add("Сигнатура совпадает — это модуль ввода-вывода.")
        } else {
            log.add("Опознание пропущено оператором.")
        }

        log.add("Запись нового ID=$newAddr на адрес $oldAddr…")
        val writeId = bus.scanWriteSingleRegister(oldAddr, 0x0000, newAddr, 300L)
        when (writeId.status) {
            "ok" -> log.add("Эхо получено — команда принята.")
            "exception" -> {
                log.add(
                    "Устройство вернуло код ошибки ${writeId.exceptionCode} на запись " +
                        "адреса — операция остановлена."
                )
                return mapOf("ok" to false, "log" to log, "blocked" to false)
            }
            else -> {
                log.add(
                    "Нет ответа на запись адреса (${writeId.status}) — операция остановлена."
                )
                return mapOf("ok" to false, "log" to log, "blocked" to false)
            }
        }

        Thread.sleep(200)
        log.add("Пауза 200 мс выдержана.")

        log.add("Фиксация: запись 111 в 0x0009 на адресе $oldAddr…")
        val fix = bus.scanWriteSingleRegister(oldAddr, 0x0009, 111, 300L)
        when (fix.status) {
            "ok" -> log.add("Эхо получено на команду фиксации.")
            "exception" -> {
                log.add(
                    "Устройство вернуло код ошибки ${fix.exceptionCode} на фиксацию — " +
                        "операция остановлена."
                )
                return mapOf("ok" to false, "log" to log, "blocked" to false)
            }
            else -> log.add(
                "Ответ на команду фиксации не получен — это штатное поведение, " +
                    "модуль пишет EEPROM."
            )
        }

        return mapOf("ok" to true, "log" to log, "blocked" to false)
    }

    // Фаза 2 — запускается оператором кнопкой "Продолжить проверку" после
    // снятия и подачи питания на модуль:
    //  1. Чтение 0x0000 по newAddr — совпадение со значением newAddr,
    //     подтверждение.
    //  2. Контрольный выстрел: чтение 0x0000 по oldAddr — здесь ДОЛЖНА быть
    //     тишина. Если старый адрес отвечает — отдельная явная ошибка:
    //     модуль на двух адресах даст наложение кадров на общей шине.
    //  3. Дамп 16 регистров по newAddr — для проверки, что скорость и
    //     чётность не изменились вместе с адресом.
    private fun changeSlaveIdPhase2(oldAddr: Int, newAddr: Int): Map<String, Any?> {
        val log = mutableListOf<String>()
        val bus = modbus
        if (bus == null) {
            log.add("Порт не открыт — операция невозможна.")
            return mapOf("ok" to false, "log" to log)
        }

        log.add("Проверка нового адреса $newAddr…")
        val newRead = bus.scanTransact(newAddr, 0x03, 0x0000, 1, 300L)
        val newValue = if (newRead.status == "ok" && newRead.data != null) {
            ((newRead.data[0].toInt() and 0xFF) shl 8) or (newRead.data[1].toInt() and 0xFF)
        } else {
            null
        }
        val newOk = newValue == newAddr
        log.add(
            if (newOk) "Новый адрес отвечает, ID=$newValue — подтверждено."
            else "Новый адрес не отвечает корректно (${newRead.status}" +
                (if (newValue != null) ", получено $newValue" else "") + ")."
        )

        log.add("Контрольный выстрел: проверка, что старый адрес $oldAddr молчит…")
        val oldRead = bus.scanTransact(oldAddr, 0x03, 0x0000, 1, 300L)
        val oldSilent = oldRead.status == "no_response"
        log.add(
            if (oldSilent) "Старый адрес молчит — конфликта нет."
            else "ОШИБКА: старый адрес $oldAddr всё ещё отвечает (${oldRead.status}). " +
                "Модуль, откликающийся на двух адресах, даст наложение кадров на общей шине."
        )

        var dump: List<Int>? = null
        if (newOk) {
            val dumpRead = bus.scanTransact(newAddr, 0x03, 0x0000, 16, 300L)
            if (dumpRead.status == "ok" && dumpRead.data != null) {
                dump = (0 until 16).map { i ->
                    ((dumpRead.data[i * 2].toInt() and 0xFF) shl 8) or
                        (dumpRead.data[i * 2 + 1].toInt() and 0xFF)
                }
                log.add("Дамп 16 регистров по адресу $newAddr прочитан.")
            } else {
                log.add("Не удалось прочитать дамп настроек (${dumpRead.status}).")
            }
        }

        return mapOf(
            "ok" to (newOk && oldSilent),
            "log" to log,
            "newAddrOk" to newOk,
            "oldAddrSilent" to oldSilent,
            "dump" to dump,
        )
    }

    // Опрос монетоприёмника РЕЖИМА ОПЛАТЫ — работает только между
    // startPaymentCoinCounting()/stopPaymentCoinCounting() (на весь экран
    // оплаты, а не постоянно как раньше), поэтому не конкурирует с обычными
    // вызовами вне этого окна.
    private val lastCoinCents = AtomicInteger(0)
    private var paymentPollingThread: Thread? = null
    private val paymentPollingActive = AtomicBoolean(false)
    // "Отказ вместо недосчёта" (задача "контроль цикла по электросчётчику,
    // температурный режим, готовность оплаты") — coinFailureCount копится
    // за всё окно оплаты (для записи в отчёт о транзакции), coinAcceptorDown
    // взводится один раз при COIN_MAX_CONSECUTIVE_FAILURES неудачах подряд
    // и снимается только новым startPaymentCoinCounting().
    private val coinFailureCount = AtomicInteger(0)
    private val coinAcceptorDown = AtomicBoolean(false)

    // Отладочный переключатель сервисного меню ("имитировать отказ
    // монетоприёмника") — подделывает getCoinAcceptorStatus() без единого
    // обращения к шине. Воспроизводится сколько угодно раз одинаково, не
    // зависит от того, как именно отваливается реальная связь, и не
    // рискует железом — в отличие от физического разрыва RS485. Сознательно
    // НЕ сбрасывается при уходе с вкладки "Диагностика" — тест проверяется
    // на реальном экране оплаты, за пределами этой вкладки.
    //
    // Но аппарат с домашним экраном работает месяцами без перезапуска —
    // если техник забудет выключить тумблер, приём монет молча перестанет
    // работать на неопределённый срок, и никто не поймёт почему (задача
    // "контроль цикла по электросчётчику", фаза 2, страховка). Поэтому
    // здесь, а не только в Dart-коде тумблера — гарантия автосброса через
    // COIN_SIMULATED_DOWN_AUTO_OFF_MS, которая переживёт даже полный
    // перезапуск сервисного меню/экрана оплаты. Правило одно и то же для
    // любых будущих отладочных переключателей на этом аппарате: то, что
    // принимает деньги, не должно уметь спрятаться в отладочном режиме.
    private val coinAcceptorSimulatedDown = AtomicBoolean(false)
    private val coinSimulatedDownAutoOffHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val coinSimulatedDownAutoOffRunnable = Runnable {
        coinAcceptorSimulatedDown.set(false)
    }

    // Отладочная "заморозка" показания термопары (задача "детектор отказа
    // датчика температуры", часть 2, п.11) — readTemperature() отдаёт
    // ПОСЛЕДНЕЕ успешно прочитанное значение вместо шины, как залипший
    // датчик. Нужна, чтобы проверить детекторы, не вынимая термопару из
    // клеммника. Те же правила, что у тумблера монетоприёмника: живёт до
    // ручного выключения, но не дольше TEMPERATURE_FROZEN_AUTO_OFF_MS,
    // состояние читается Dart-ом (вкладка "Диагностика" и регулярная
    // отправка состояния в облако) — спрятаться не может.
    @Volatile private var lastTemperatureC: Double? = null
    private val temperatureFrozen = AtomicBoolean(false)
    @Volatile private var frozenTemperatureC: Double? = null
    private val temperatureFreezeAutoOffHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val temperatureFreezeAutoOffRunnable = Runnable {
        temperatureFrozen.set(false)
        frozenTemperatureC = null
    }

    // Платёжный терминал (задача "терминал") — в отличие от монетоприёмника,
    // здесь НЕТ своего потока: правило проекта на этот шаг прямо запрещает
    // заводить новые потоки под обработчики, опрос ведёт Dart через
    // Timer.periodic, каждый тик — один вызов "pollTerminal" через уже
    // существующую фоновую очередь канала. Состояние между тиками просто
    // живёт в полях экземпляра — тот же ModbusChannel обслуживает все тики
    // подряд, пока жив FlutterEngine.
    private var terminalLastState = false
    private var terminalStateChangedAt = 0L
    private var terminalLastConfirmedAt = 0L
    private val terminalJournal = ArrayDeque<String>()
    private val TERMINAL_JOURNAL_MAX = 300
    private val terminalTimeFormat =
        java.text.SimpleDateFormat("HH:mm:ss.SSS", java.util.Locale.US)

    init {
        channel.setMethodCallHandler(this)
    }

    // Порт приходит из Dart аргументом. Молчаливой подстановки чужого порта
    // нет: без аргумента или с недопустимым/запрещённым узлом — ошибка.
    private fun requirePort(call: MethodCall, result: MethodChannel.Result): String? {
        val port = call.argument<String>("port")
        if (port == null) {
            result.error("NO_PORT", "port не передан", null)
            return null
        }
        if (!BusPortPolicy.isAllowed(port)) {
            result.error("BAD_PORT", "порт не допускается", null)
            return null
        }
        return port
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            // Идемпотентно (задача "починить обмен по шине" 1.1) — раньше
            // каждый вызов "open" безусловно создавал новый ModbusRtu и
            // терял предыдущий БЕЗ close(), не освобождая символьное
            // устройство. При повторных вызовах (в частности, из цикла
            // StartupService на шаге 37) на одном порту шины копились
            // открытые дескрипторы, и ответ мог вычитываться не из того
            // дескриптора, который отправлял запрос — снаружи это выглядит
            // как "устройство не отвечает", хотя физически (индикатор на
            // модуле мигает) запросы доходят.
            "open" -> {
                val port = requirePort(call, result) ?: return
                val baud = call.argument<Int>("baud") ?: 9600
                val opened = openPort(port, baud, "explicit open() call")
                result.success(
                    when (opened) {
                        is ModbusRtu.OpenResult.Ok -> mapOf("ok" to true)
                        is ModbusRtu.OpenResult.Busy -> mapOf(
                            "ok" to false,
                            "code" to "PORT_BUSY",
                            "pid" to opened.holderPid,
                        )
                        is ModbusRtu.OpenResult.Failed -> mapOf("ok" to false)
                    }
                )
            }

            "close" -> {
                if (modbus != null) {
                    Log.d(TAG, "close: закрываю порт (явный вызов close())")
                }
                registry.close(this)
                result.success(null)
            }

            "isOpen" -> result.success(modbus?.isOpen() == true)

            // Состояние сторожа шины (без обмена по шине): ошибки подряд,
            // счётчик успехов, события переоткрытия — для BusWatchdogService.
            "busHealth" -> result.success(registry.health(this))

            // Читает ВСЕ 16 DI одной транзакцией — один запрос на 16 входов
            // стоит по времени столько же, сколько на 8 (время уходит на
            // служебную часть кадра, не на число бит). Каналы 0-7 — уровни
            // канистр, 8 — монетоприёмник, 10 (по умолчанию, настраивается)
            // — платёжный терминал. Раньше уровни читались отдельным
            // 8-битным запросом ("readLevels") — теперь то же самое отдаёт
            // этот же более широкий запрос, разбор по каналам делает Dart.
            "readAllInputs" -> {
                val di = modbus?.readDiscreteInputs(SLAVE_DIO, 0, 16)
                if (di == null) result.error("MODBUS", "readAllInputs failed", null)
                else result.success(di.map { it })
            }

            // Читает DI монетоприёмника (канал 8), одиночный запрос, таймаут 500мс
            "readCoin" -> {
                val di = modbus?.readDiscreteInputs(SLAVE_DIO, 8, 1, timeoutMs = 500L)
                if (di == null) result.error("MODBUS", "readCoin failed", null)
                else result.success(di[0])
            }

            // Устанавливает один DO (0-based: насос 0-7, компрессор 8, ТЭН 9, LED зел 10, LED кр 11)
            "setDO" -> {
                val ch = call.argument<Int>("channel") ?: return result.error("ARG", "no channel", null)
                val on = call.argument<Boolean>("value") ?: false
                val ok = modbus?.writeSingleCoil(SLAVE_DIO, ch, on, timeoutMs = 150L) == true
                result.success(ok)
            }

            // Выключает нагрузки (safe_all_off) одним кадром FC15 вместо
            // прежних 12 отдельных FC05 (задача "свести карту шины и
            // каналов", живой замер 27.09.2026: кадр 05 0F 00 00 00 0A ...,
            // ответ 05 0F 00 00 00 0A D4 48). Раньше обрыв связи посреди
            // цикла из 12 запросов мог оставить часть выходов поднятой —
            // ровно то, от чего должен защищать сторож выходов. Один кадр —
            // либо проходит целиком, либо нет, середины не бывает.
            //
            // Диапазон 0..9 (насосы 0-7, компрессор 8, ТЭН 9) НАМЕРЕННО не
            // включает 10/11 (индикаторные LED): красный индикатор должен
            // продолжать сигнализировать аварию, а не гаснуть вместе с
            // нагрузками при каждом safeAllOff. Таймаут 150 мс — этот путь
            // вызывается в повторяющемся цикле при старте, пока шина не
            // ответит, и должен быстро проваливаться на мёртвой шине.
            "safeAllOff" -> {
                val r = modbus?.scanWriteMultipleCoils(
                    SLAVE_DIO,
                    0,
                    List(10) { false },
                    timeoutMs = 150L,
                ) ?: ModbusRtu.ScanResult("no_response")
                result.success(r.status == "ok")
            }

            // Читает фактическое состояние всех 12 используемых выходов
            // одной транзакцией — для сторожа выходов (задача "сторож
            // выходов"): в покое ожидается, что выключено всё, и если
            // модуль поднял катушку сам (после подачи питания, до того как
            // safeAllOff успел отработать) — это единственный способ узнать
            // об этом, не полагаясь на память приложения о том, что оно
            // само куда-то писало.
            "readCoils" -> {
                val coils = modbus?.readCoils(SLAVE_DIO, 0, 12, timeoutMs = 150L)
                if (coils == null) result.error("MODBUS", "readCoils failed", null)
                else result.success(coils.toList())
            }

            // ============================================================
            // СКАНЕР ШИНЫ (задача "сканер шины Modbus") — техник работает с
            // произвольным устройством/адресом/функцией, не только с теми,
            // что зашиты в SLAVE_*. Свой поток не заводится (правило
            // проекта) — вызывается часто, коротко, через уже существующую
            // фоновую очередь, как и остальной обмен.
            // ============================================================

            // Быстрый пробный запрос "кто-нибудь ответил на этот адрес" —
            // для перебора диапазона (задача 2). FC03, 1 регистр с адреса
            // 0 — не важно, поддерживает ли устройство именно этот регистр:
            // и успешный ответ, и код ошибки устройства одинаково означают
            // "адрес занят", разбирает это scanTransact ниже.
            "scanProbe" -> {
                val slaveId = call.argument<Int>("slaveId")
                    ?: return result.error("ARG", "no slaveId", null)
                val timeoutMs = (call.argument<Int>("timeoutMs") ?: 100).toLong()
                val r = modbus?.scanTransact(slaveId, 0x03, 0, 1, timeoutMs)
                    ?: ModbusRtu.ScanResult("no_response")
                result.success(r.status != "no_response")
            }

            // Произвольное чтение (задача 1): funcCode ровно как в
            // документации устройства — 0x01 катушки, 0x02 дискретные
            // входы, 0x03 регистры хранения, 0x04 входные регистры.
            // Статус разбирает три разные причины неудачи (задача 1.7) —
            // Dart-сторона показывает их отдельно, а не как один "не
            // получилось".
            "scanRead" -> {
                val slaveId = call.argument<Int>("slaveId")
                    ?: return result.error("ARG", "no slaveId", null)
                val funcCode = call.argument<Int>("funcCode")
                    ?: return result.error("ARG", "no funcCode", null)
                val startAddr = call.argument<Int>("startAddr") ?: 0
                val count = call.argument<Int>("count") ?: 1
                val timeoutMs = (call.argument<Int>("timeoutMs") ?: 300).toLong()
                val r = modbus?.scanTransact(slaveId, funcCode, startAddr, count, timeoutMs)
                    ?: ModbusRtu.ScanResult("no_response")
                if (r.status != "ok") {
                    result.success(mapOf("status" to r.status, "exceptionCode" to r.exceptionCode))
                } else {
                    val data = r.data!!
                    if (funcCode == 0x01 || funcCode == 0x02) {
                        val values = (0 until count).map { i ->
                            val byteIdx = i / 8
                            val bitIdx = i % 8
                            (data[byteIdx].toInt() and (1 shl bitIdx)) != 0
                        }
                        result.success(mapOf("status" to "ok", "values" to values))
                    } else {
                        val values = (0 until count).map { i ->
                            ((data[i * 2].toInt() and 0xFF) shl 8) or (data[i * 2 + 1].toInt() and 0xFF)
                        }
                        result.success(mapOf("status" to "ok", "values" to values))
                    }
                }
            }

            // Запись одиночного регистра/катушки (задача 3) — опасный
            // раздел, подтверждение показывает Dart-сторона ДО вызова.
            "scanWriteRegister" -> {
                val slaveId = call.argument<Int>("slaveId")
                    ?: return result.error("ARG", "no slaveId", null)
                val addr = call.argument<Int>("addr")
                    ?: return result.error("ARG", "no addr", null)
                val value = call.argument<Int>("value")
                    ?: return result.error("ARG", "no value", null)
                val ok = modbus?.writeSingleRegister(slaveId, addr, value, timeoutMs = 200L) == true
                result.success(ok)
            }

            "scanWriteCoil" -> {
                val slaveId = call.argument<Int>("slaveId")
                    ?: return result.error("ARG", "no slaveId", null)
                val addr = call.argument<Int>("addr")
                    ?: return result.error("ARG", "no addr", null)
                val value = call.argument<Boolean>("value") ?: false
                val ok = modbus?.writeSingleCoil(slaveId, addr, value, timeoutMs = 200L) == true
                result.success(ok)
            }

            // FC15 — запись нескольких катушек одним кадром. Статус разбирает
            // три исхода отдельно (как и scanRead), потому что для этого теста
            // важно различить "не ответил" от "ответил отказом" (05 8F 01 —
            // функция не поддерживается).
            "scanWriteMultipleCoils" -> {
                val slaveId = call.argument<Int>("slaveId")
                    ?: return result.error("ARG", "no slaveId", null)
                val addr = call.argument<Int>("addr")
                    ?: return result.error("ARG", "no addr", null)
                val values = call.argument<List<Boolean>>("values")
                    ?: return result.error("ARG", "no values", null)
                val r = modbus?.scanWriteMultipleCoils(slaveId, addr, values, timeoutMs = 300L)
                    ?: ModbusRtu.ScanResult("no_response")
                result.success(mapOf("status" to r.status, "exceptionCode" to r.exceptionCode))
            }

            // FC16 — запись нескольких регистров одним кадром. Нужна для
            // устройств без FC06 (Chint DDSU666 — заявляет в мануале только
            // 03 на чтение и 16 на запись, даже для одного регистра).
            "scanWriteMultipleRegisters" -> {
                val slaveId = call.argument<Int>("slaveId")
                    ?: return result.error("ARG", "no slaveId", null)
                val addr = call.argument<Int>("addr")
                    ?: return result.error("ARG", "no addr", null)
                val values = call.argument<List<Int>>("values")
                    ?: return result.error("ARG", "no values", null)
                val r = modbus?.scanWriteMultipleRegisters(slaveId, addr, values, timeoutMs = 300L)
                    ?: ModbusRtu.ScanResult("no_response")
                result.success(mapOf("status" to r.status, "exceptionCode" to r.exceptionCode))
            }

            // Перебор скорости порта — диагностика "живой ли адрес на другой
            // скорости, если 9600 молчит" (задача "починить обмен по шине",
            // живая калибровка). Открытие идемпотентно (openPort), но само по
            // себе это не поможет здесь: порт уже открыт на боевой скорости,
            // и идемпотентный вызов с другой скоростью просто ничего не
            // сделает. Поэтому здесь порт закрывается явно перед каждой
            // пробой и восстанавливается на исходной скорости в конце —
            // ЛЮБОЙ исход (нашли или нет) не должен оставить приложение без
            // рабочего соединения.
            "baudSweep" -> {
                val port = requirePort(call, result) ?: return
                val slaveId = call.argument<Int>("slaveId") ?: 5
                val bauds = (call.argument<List<Int>>("bauds"))
                    ?: listOf(4800, 19200, 38400, 115200)
                val originalBaud = call.argument<Int>("originalBaud") ?: 9600

                registry.close(this)

                var foundBaud: Int? = null
                for (baud in bauds) {
                    val bus = ModbusRtu(context)
                    if (bus.open(port, baud) == ModbusRtu.OpenResult.Ok) {
                        val probe = bus.scanTransact(slaveId, 0x03, 0, 1, 200L)
                        if (probe.status != "no_response") {
                            foundBaud = baud
                        }
                    }
                    bus.close()
                    if (foundBaud != null) break
                }

                // Возвращаем рабочую скорость независимо от результата —
                // остальное приложение не должно остаться без связи из-за
                // диагностики.
                openPort(port, originalBaud, "восстановление после перебора скорости")
                result.success(foundBaud)
            }

            // Диагностика "чётность отличается от ожидаемой" (задача "Chint
            // DDSU666: найти счётчик") — временно переоткрывает порт с
            // указанной чётностью, чтобы сканер адресов мог поработать на
            // ней (сам сканер шлёт запросы через уже открытый modbus, см.
            // scanProbe/scanRead — отдельного параметра чётности у них нет).
            // Как и baudSweep, не восстанавливает ничего сама — вызывающая
            // сторона обязана вызвать этот же метод с parity="none" после
            // диагностики, иначе приложение останется без связи с боевым
            // модулем.
            "openWithParity" -> {
                val port = requirePort(call, result) ?: return
                val baud = call.argument<Int>("baud") ?: 9600
                val parity = call.argument<String>("parity") ?: "none"

                // Реестр сам закрывает прежний объект, если параметры другие.
                val ok = registry.open(this, port, baud, parity) == ModbusRtu.OpenResult.Ok
                result.success(ok)
            }

            // Управляемая смена Slave ID нового модуля — фаза 1 (опознание
            // + запись адреса + фиксация), см. changeSlaveIdPhase1.
            "changeSlaveIdPhase1" -> {
                val oldAddr = call.argument<Int>("oldAddr")
                    ?: return result.error("ARG", "no oldAddr", null)
                val newAddr = call.argument<Int>("newAddr")
                    ?: return result.error("ARG", "no newAddr", null)
                val skipIdentification = call.argument<Boolean>("skipIdentification") ?: false
                result.success(changeSlaveIdPhase1(oldAddr, newAddr, skipIdentification))
            }

            // Фаза 2 — запускается оператором после снятия/подачи питания
            // на модуль, см. changeSlaveIdPhase2.
            "changeSlaveIdPhase2" -> {
                val oldAddr = call.argument<Int>("oldAddr")
                    ?: return result.error("ARG", "no oldAddr", null)
                val newAddr = call.argument<Int>("newAddr")
                    ?: return result.error("ARG", "no newAddr", null)
                result.success(changeSlaveIdPhase2(oldAddr, newAddr))
            }

            // Читает температуру термопары (канал 0-3, возвращает °C × 10).
            // Регистр знаковый (термопара может отдавать отрицательные
            // значения и коды "нет датчика" вроде -500.0°C) — readHoldingRegisters
            // возвращает беззнаковое 0..65535, поэтому обязательно приводим
            // через toShort() перед делением, иначе, например, -12.4°C
            // превращается в бессмысленные +6541.2°C.
            "readTemperature" -> {
                val frozen = frozenTemperatureC
                if (temperatureFrozen.get() && frozen != null) {
                    // Отладочная заморозка — шины нет вообще, как у залипшего
                    // датчика, который продолжает отдавать одно и то же.
                    result.success(frozen)
                } else {
                    val ch = call.argument<Int>("channel") ?: 0
                    val regs = modbus?.readHoldingRegisters(SLAVE_THERMO, ch, 1)
                    if (regs == null) result.error("MODBUS", "readTemperature failed", null)
                    else {
                        val value = parseThermocoupleRaw(regs[0])
                        lastTemperatureC = value
                        result.success(value)
                    }
                }
            }

            // Включает/выключает отладочную заморозку показания термопары.
            // Возвращает значение, на котором заморожено (null при
            // выключении или если заморозить было нечем — ни одного
            // успешного чтения и шина не отвечает).
            "setTemperatureFrozen" -> {
                val on = call.argument<Boolean>("value") ?: false
                result.success(setTemperatureFrozen(on))
            }

            // Реальное состояние заморозки — вкладка "Диагностика"
            // пересоздаётся при переключении, а флаг живёт дольше неё.
            "getTemperatureFrozen" -> result.success(
                mapOf(
                    "frozen" to temperatureFrozen.get(),
                    "value" to frozenTemperatureC,
                )
            )

            // Читает данные счётчика энергии DDS6619: напряжение (В), ток (А),
            // мощность (Вт), общий накопленный расход (кВт⋅ч). Всегда
            // свежее чтение (forceFresh=true) — это то значение, которым
            // затем переиспользуется getMonthlyEnergy() в этом же цикле опроса.
            "readEnergy" -> {
                val energy = readEnergyValues(forceFresh = true)
                if (energy == null) result.error("MODBUS", "readEnergy failed", null)
                else result.success(energy)
            }

            // Расход за текущий календарный месяц (кВт⋅ч): текущий общий счётчик
            // минус значение-снимок, зафиксированное в начале месяца
            "getMonthlyEnergy" -> {
                val monthly = getMonthlyEnergy()
                if (monthly == null) result.error("MODBUS", "getMonthlyEnergy failed", null)
                else result.success(monthly)
            }

            // История расхода по месяцам (JSON-массив), максимум 12 последних записей
            "getEnergyHistory" -> {
                val prefs = context.getSharedPreferences("energy_meter_prefs", Context.MODE_PRIVATE)
                result.success(prefs.getString("monthly_history", "[]"))
            }

            // Расход за предыдущий (уже завершившийся) месяц — последняя запись истории
            "getPreviousMonthEnergy" -> {
                val prefs = context.getSharedPreferences("energy_meter_prefs", Context.MODE_PRIVATE)
                val historyJson = prefs.getString("monthly_history", "[]") ?: "[]"
                val kwh = try {
                    val array = JSONArray(historyJson)
                    if (array.length() == 0) 0.0
                    else array.getJSONObject(array.length() - 1).getDouble("kwh")
                } catch (e: Exception) {
                    0.0
                }
                result.success(kwh)
            }

            // Запускает фоновый счётчик импульсов монетоприёмника для экрана оплаты
            "startPaymentCoinCounting" -> {
                startPaymentCoinCounting()
                result.success(null)
            }

            // Останавливает фоновый счётчик (обязательно вызывать при уходе с экрана оплаты)
            "stopPaymentCoinCounting" -> {
                stopPaymentCoinCounting()
                result.success(null)
            }

            // Номинал последней принятой монеты в центах (0 = новой монеты нет)
            "getCoinAcceptorStatus" -> result.success(getCoinAcceptorStatus())

            // Сервисное меню, отладочный переключатель "имитировать отказ
            // монетоприёмника" — см. setCoinAcceptorSimulatedDown().
            "setCoinAcceptorSimulatedDown" -> {
                setCoinAcceptorSimulatedDown(call.argument<Boolean>("value") ?: false)
                result.success(null)
            }

            // Флаг живёт в памяти нативного слоя дольше, чем виджет вкладки
            // "Диагностика" (сознательно не сбрасывается при уходе с неё,
            // см. коммент у setCoinAcceptorSimulatedDown в service_menu.dart)
            // — при пересоздании вкладки тумблер должен показать РЕАЛЬНОЕ
            // состояние, а не всегда "выключено".
            "getCoinAcceptorSimulatedDown" -> result.success(coinAcceptorSimulatedDown.get())

            // Один опрос платёжного терминала — читает канал, сравнивает с
            // прошлым известным состоянием, при фронте пишет в журнал и, если
            // фронт "тот самый" (по режиму) и не попал в защитную паузу —
            // засчитывает оплату. Вызывается часто (Dart Timer.periodic), но
            // сам не заводит поток — см. комментарий у полей terminal* выше.
            "pollTerminal" -> {
                val ch = call.argument<Int>("channel") ?: 10
                val mode = call.argument<String>("mode") ?: "edge"
                val guardMs = (call.argument<Int>("guardMs") ?: 3000).toLong()
                // Узкое однобитное чтение с ЯВНЫМ коротким таймаутом — это
                // окончательное решение, не временное. История: короткое
                // время был вариант с широким 16-битным чтением здесь же
                // (переиспользовать снимок с readAllInputs) — контрольный
                // тест дал 5 из 5 пойманных оплат на узком чтении против 0
                // из 5 на широком, и разница была не в ширине запроса
                // (8 байт что так, что так, разница в один байт ответа —
                // на 9600 бод это около миллисекунды). Настоящая причина:
                // в узком варианте таймаут стоял явно (150 мс), а при
                // переходе на широкое чтение параметр забыли передать, и
                // подставилось значение по умолчанию (500 мс, см.
                // ModbusRtu.readDiscreteInputs). На успешном чтении разницы
                // нет, но каждая неудачная попытка блокировала общий лок
                // шины (ioLock, см. ModbusRtu.sendAndReceive) втрое дольше,
                // а рядом непрерывно опрашивает поток монетоприёмника
                // (paymentPollingThread) — устойчивый рост задержки съедал
                // короткие импульсы терминала. Подробности и цифры теста —
                // docs/payment_terminal.md.
                val di = modbus?.readDiscreteInputs(SLAVE_DIO, ch, 1, timeoutMs = 150L)
                if (di == null) {
                    result.error("MODBUS", "pollTerminal failed", null)
                } else {
                    val raw = di[0]
                    result.success(
                        mapOf(
                            "state" to raw,
                            "confirmed" to pollTerminalEdge(raw, mode, guardMs),
                        )
                    )
                }
            }

            // Журнал сигнала терминала — кольцевой буфер строк для калибровки
            // (см. pollTerminalEdge/addTerminalLog). Не зависит от того, кто
            // именно опрашивает канал — экран оплаты, вкладка "Датчики" или
            // фоновая проверка вне экрана оплаты.
            "getTerminalJournal" -> result.success(terminalJournal.toList())

            "clearTerminalJournal" -> {
                terminalJournal.clear()
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // Читает все 4 показателя счётчика энергии одним запросом-набором.
    // null, если хоть одно чтение по шине не удалось.
    //
    // forceFresh=false переиспользует значение, прочитанное не позднее
    // ENERGY_CACHE_MAX_AGE_MS назад, вместо повторного похода по шине —
    // без этого readEnergy() и getMonthlyEnergy() (вызываются подряд из
    // одного и того же цикла опроса в _readEnergy(), см. service_menu.dart)
    // гоняли одни и те же 4 транзакции дважды, и при неотвечающем счётчике
    // (таймаут 500мс на каждую) это держало общую последовательную очередь
    // Modbus занятой до ~4 секунд лишний раз — за это время любой другой
    // вызов (например setDO тумблера насоса) просто ждал своей очереди.
    // Блок измерений DDSU666 начинается с 0x2000, каждая величина — IEEE-754
    // float32 в двух регистрах, старшее слово первым (сверено вживую
    // 27.09.2026: 0x436D199A и 0x436CE666 на двух последовательных чтениях
    // дали ~237,1 В и ~236,6 В — реалистичный разброс сетевого напряжения).
    // Только FC03 — счётчик по документации поддерживает исключительно 03
    // на чтение и 16 на запись, FC04 (readInputRegisters) он не
    // поддерживает вовсе; прежняя реализация ходила через FC04 по
    // смещениям 0x0000/0x0003/0x0008/0x001D — те пришли из того же
    // недостоверного источника, что и ошибочное прочтение 0x0002 как
    // скорости (задача "Chint DDSU666: найти счётчик"), реальный мануал
    // их не подтвердил. Молчаливый результат старого кода — не "0", а
    // null на каждом чтении: readInputRegisters возвращал null на
    // неподдерживаемой функции, и UI просто не обновлял дефолтные нули.
    private fun readEnergyFloat(addr: Int): Double? {
        val regs = modbus?.readHoldingRegisters(SLAVE_ENERGY, addr, 2) ?: return null
        val bits = (regs[0].toLong() shl 16) or (regs[1].toLong() and 0xFFFF)
        return Float.fromBits(bits.toInt()).toDouble()
    }

    private fun readEnergyValues(forceFresh: Boolean = false): Map<String, Double>? {
        val cached = energyCache
        val now = System.currentTimeMillis()
        if (!forceFresh && cached != null && now - energyCacheTime < ENERGY_CACHE_MAX_AGE_MS) {
            return cached
        }

        val voltage = readEnergyFloat(0x2000) ?: return null
        val current = readEnergyFloat(0x2002) ?: return null
        val power = readEnergyFloat(0x2004) ?: return null
        val totalEnergy = readEnergyFloat(0x4000) ?: return null

        val result = mapOf(
            "voltage" to voltage,
            "current" to current,
            "power" to power,
            "totalEnergy" to totalEnergy
        )
        energyCache = result
        energyCacheTime = now
        return result
    }

    private fun getMonthlyEnergy(): Double? {
        val totalEnergy = readEnergyValues(forceFresh = false)?.get("totalEnergy") ?: return null

        val prefs = context.getSharedPreferences("energy_meter_prefs", Context.MODE_PRIVATE)
        val cal = Calendar.getInstance()
        val currentYear = cal.get(Calendar.YEAR)
        val currentMonth = cal.get(Calendar.MONTH)

        val baselineYear = prefs.getInt("baseline_year", -1)
        val baselineMonth = prefs.getInt("baseline_month", -1)
        var baseline = java.lang.Double.longBitsToDouble(
            prefs.getLong("monthly_baseline", java.lang.Double.doubleToRawLongBits(0.0))
        )

        if (currentMonth != baselineMonth || currentYear != baselineYear) {
            if (baselineMonth == -1) {
                // Первый запуск — нет завершённого месяца для истории, и нет
                // смысла обнулять baseline текущим значением счётчика: весь
                // totalEnergy, что уже накоплен на счётчике, считаем расходом
                // текущего месяца, а не "теряем" его в стартовом снимке.
                baseline = 0.0
            } else {
                val lastMonthUsage = totalEnergy - baseline
                appendMonthlyHistory(prefs, baselineYear, baselineMonth, lastMonthUsage)
                baseline = totalEnergy
            }
            prefs.edit()
                .putLong("monthly_baseline", java.lang.Double.doubleToRawLongBits(baseline))
                .putInt("baseline_month", currentMonth)
                .putInt("baseline_year", currentYear)
                .apply()
        }

        return totalEnergy - baseline
    }

    // Добавляет запись о завершившемся месяце в "monthly_history" (JSON-массив),
    // храня не более 12 последних записей (самые старые обрезаются).
    private fun appendMonthlyHistory(prefs: SharedPreferences, year: Int, month: Int, kwh: Double) {
        val historyJson = prefs.getString("monthly_history", "[]") ?: "[]"
        val array = try {
            JSONArray(historyJson)
        } catch (e: Exception) {
            JSONArray()
        }

        val entry = JSONObject()
        entry.put("year", year)
        entry.put("month", month + 1) // Calendar.MONTH — 0-based, храним как 1-12
        entry.put("kwh", kwh)
        array.put(entry)

        val trimmed = JSONArray()
        val start = maxOf(0, array.length() - 12)
        for (i in start until array.length()) {
            trimmed.put(array.get(i))
        }

        prefs.edit().putString("monthly_history", trimmed.toString()).apply()
    }

    // Запускает фоновый поток, опрашивающий DI8 (монетоприёмник) на время
    // экрана оплаты. Считает импульсы (переход false→true = один импульс)
    // одной монеты; пауза без новых импульсов дольше COIN_SERIES_GAP_MS
    // завершает монету и определяет номинал по количеству накопленных
    // импульсов. Не запускает второй поток, если один уже работает.
    //
    // "Отказ вместо недосчёта" (задача "контроль цикла по электросчётчику,
    // готовность оплаты", п.4): неудачное чтение тика немедленно повторяется
    // один раз (импульс короткий, обычные 80 мс до следующего тика рискуют
    // его целиком пропустить). Если и повтор не удался — считаем это
    // неудачей: копим в coinFailureCount (уходит в отчёт о транзакции) и,
    // при нескольких подряд, взводим coinAcceptorDown и ОБНУЛЯЕМ текущую
    // незавершённую серию импульсов, не пытаясь угадать её номинал —
    // раньше именно тут двухевровая монета молча становилась одноевровой.
    private fun startPaymentCoinCounting() {
        if (paymentPollingActive.get()) return
        paymentPollingActive.set(true)
        // Монета, принятая после последнего опроса прошлого окна (или во
        // время имитации отказа), не должна достаться следующему клиенту.
        lastCoinCents.set(0)
        coinFailureCount.set(0)
        coinAcceptorDown.set(false)
        paymentPollingThread = Thread {
            var previousState = false
            var pulseCount = 0
            var lastPulseTime = 0L
            var consecutiveFailures = 0
            while (paymentPollingActive.get()) {
                var current = modbus?.readDiscreteInputs(
                    SLAVE_DIO, 8, 1, timeoutMs = COIN_POLL_TIMEOUT_MS
                )?.getOrNull(0)
                if (current == null) {
                    current = modbus?.readDiscreteInputs(
                        SLAVE_DIO, 8, 1, timeoutMs = COIN_POLL_TIMEOUT_MS
                    )?.getOrNull(0)
                }
                val now = System.currentTimeMillis()
                if (current != null) {
                    consecutiveFailures = 0
                    if (!previousState && current) {
                        // Восходящий фронт — один импульс монеты.
                        pulseCount++
                        lastPulseTime = now
                    }
                    previousState = current
                } else {
                    consecutiveFailures++
                    coinFailureCount.incrementAndGet()
                    if (consecutiveFailures >= COIN_MAX_CONSECUTIVE_FAILURES) {
                        pulseCount = 0
                        coinAcceptorDown.set(true)
                    }
                }
                if (pulseCount > 0 && now - lastPulseTime > COIN_SERIES_GAP_MS) {
                    val cents = if (pulseCount <= 1) {
                        COIN_CENTS_FOR_1_PULSE
                    } else {
                        COIN_CENTS_FOR_2_PLUS_PULSES
                    }
                    lastCoinCents.set(cents)
                    pulseCount = 0
                }
                try {
                    Thread.sleep(COIN_POLL_INTERVAL_MS)
                } catch (e: InterruptedException) {
                    // Поток останавливается — выходим из цикла на следующей проверке флага.
                }
            }
        }.apply { start() }
    }

    private fun stopPaymentCoinCounting() {
        paymentPollingActive.set(false)
        paymentPollingThread?.join(500)
        paymentPollingThread = null
    }

    // Заменяет прежний getLastCoinCents(): отдаёт разом номинал, счётчик
    // неудачных чтений за окно и флаг отказа приёма — payment.dart решает,
    // что делать, по всем трём сразу, одной транзакцией метод-канала.
    // Имитация (см. coinAcceptorSimulatedDown) подделывает результат ДО
    // любого обращения к реальным полям — cents всегда 0, чтобы тест не
    // мог случайно кому-то зачислить баланс.
    private fun getCoinAcceptorStatus(): Map<String, Any> {
        if (coinAcceptorSimulatedDown.get()) {
            return mapOf(
                "cents" to 0,
                "failureCount" to COIN_MAX_CONSECUTIVE_FAILURES,
                "down" to true,
            )
        }
        return mapOf(
            "cents" to lastCoinCents.getAndSet(0),
            "failureCount" to coinFailureCount.get(),
            "down" to coinAcceptorDown.get(),
        )
    }

    // Сервисное меню: включает/выключает "заморозку" показания термопары
    // (задача "детектор отказа датчика температуры", п.11): readTemperature
    // отдаёт последнее прочитанное значение, шину не трогает. Каждое
    // включение (пере)заводит таймер автосброса на
    // TEMPERATURE_FROZEN_AUTO_OFF_MS (30 мин) — страховка от забытого
    // тумблера. Возвращает значение, на котором заморожено, либо null.
    private fun setTemperatureFrozen(value: Boolean): Double? {
        temperatureFreezeAutoOffHandler.removeCallbacks(temperatureFreezeAutoOffRunnable)
        if (!value) {
            temperatureFrozen.set(false)
            frozenTemperatureC = null
            return null
        }
        // "Последнее значение" — то, что реально прочитано до этого; если
        // ещё ни разу не читали, читаем один раз прямо сейчас.
        var base = lastTemperatureC
        if (base == null) {
            val regs = modbus?.readHoldingRegisters(SLAVE_THERMO, 0, 1)
            if (regs != null) base = parseThermocoupleRaw(regs[0])
        }
        if (base == null) return null
        frozenTemperatureC = base
        temperatureFrozen.set(true)
        temperatureFreezeAutoOffHandler.postDelayed(
            temperatureFreezeAutoOffRunnable,
            TEMPERATURE_FROZEN_AUTO_OFF_MS,
        )
        return base
    }

    private fun setCoinAcceptorSimulatedDown(value: Boolean) {
        coinAcceptorSimulatedDown.set(value)
        coinSimulatedDownAutoOffHandler.removeCallbacks(coinSimulatedDownAutoOffRunnable)
        if (value) {
            coinSimulatedDownAutoOffHandler.postDelayed(
                coinSimulatedDownAutoOffRunnable,
                COIN_SIMULATED_DOWN_AUTO_OFF_MS,
            )
        }
    }

    // Один тик опроса терминала: обновляет terminalLastState, пишет фронт в
    // журнал (с длительностью предыдущего состояния — по этому можно
    // восстановить форму сигнала, задача 3.3), и решает, засчитывать ли
    // оплату.
    //
    // Режимы (форма сигнала не измерена заранее, отсюда оба):
    //  - "edge"  — короткий импульс на каждую оплату: считаем по
    //    восходящему фронту (false→true).
    //  - "level" — вход удерживается на время транзакции: считаем по
    //    НИСХОДЯЩЕМУ фронту (true→false) — то есть когда терминал
    //    отпускает линию после завершения транзакции, а не в момент её
    //    начала. Если на практике окажется иначе — это ровно то, ради
    //    чего затевался журнал: смотрим записи и меняем логику здесь.
    // Защитная пауза (guardMs) отсчитывается от последней ЗАСЧИТАННОЙ
    // оплаты, не от последнего фронта — так дребезг вокруг границы паузы
    // не запускает её заново на каждый мелкий скачок.
    private fun pollTerminalEdge(raw: Boolean, mode: String, guardMs: Long): Boolean {
        if (raw == terminalLastState) return false

        val now = System.currentTimeMillis()
        val heldMs = now - terminalStateChangedAt
        addTerminalLog(
            "фронт ${if (terminalLastState) 1 else 0}→${if (raw) 1 else 0} " +
                "(предыдущее состояние держалось ${heldMs} мс)"
        )
        terminalStateChangedAt = now

        // raw уже гарантированно отличается от terminalLastState (проверено
        // выше) — значит это либо восходящий (false→true), либо нисходящий
        // (true→false) фронт, третьего не дано. "edge" хочет восходящий
        // (qualifies = raw), "level" — нисходящий (qualifies = !raw).
        val qualifies = if (mode == "level") !raw else raw
        terminalLastState = raw
        if (!qualifies) return false

        val sinceLastConfirm = now - terminalLastConfirmedAt
        if (sinceLastConfirm < guardMs) {
            addTerminalLog(
                "отклонено защитной паузой (прошло ${sinceLastConfirm} мс из ${guardMs} мс)"
            )
            return false
        }

        terminalLastConfirmedAt = now
        addTerminalLog("ОПЛАТА ЗАСЧИТАНА (режим $mode)")
        return true
    }

    // Движок Flutter этого экземпляра уничтожается вместе с Activity
    // (MainActivity.onDestroy): Dart больше не управляет шиной. Раньше порт
    // и его блокировка оставались за этим экземпляром, и пересозданная
    // Activity (после обесточивания приложение стартовало дважды — оба раза
    // в одном процессе) получала "порт занят" от СВОЕГО ЖЕ PID: шина у
    // видимого экрана оставалась мёртвой до ручного перезапуска. Здесь:
    // остановить опрос монет, по возможности погасить выходы (нагрузки не
    // должны остаться включёнными без управляющего), закрыть порт.
    fun release() {
        paymentPollingActive.set(false)
        coinAcceptorAutoOffHandlerCleanup()
        // Порт у другого (более нового) движка — не закрываем и не гасим
        // выходы под ним: он уже управляет аппаратом.
        val released = registry.release(this) { bus ->
            try {
                bus.scanWriteMultipleCoils(SLAVE_DIO, 0, List(10) { false }, timeoutMs = 150L)
            } catch (e: Throwable) {
                Log.e(TAG, "release: safeAllOff не удался: $e")
            }
        }
        if (released) {
            Log.w(TAG, "release: порт освобождён (движок уничтожен)")
        } else {
            Log.w(TAG, "release: порт принадлежит другому каналу — не трогаю")
        }
    }

    private fun coinAcceptorAutoOffHandlerCleanup() {
        temperatureFreezeAutoOffHandler.removeCallbacks(temperatureFreezeAutoOffRunnable)
        coinSimulatedDownAutoOffHandler.removeCallbacks(coinSimulatedDownAutoOffRunnable)
    }

    private fun addTerminalLog(line: String) {
        val ts = terminalTimeFormat.format(java.util.Date())
        terminalJournal.addLast("$ts $line")
        while (terminalJournal.size > TERMINAL_JOURNAL_MAX) {
            terminalJournal.removeFirst()
        }
    }
}
