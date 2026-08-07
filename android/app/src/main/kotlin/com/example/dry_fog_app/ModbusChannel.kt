package com.example.dry_fog_app

import android.content.Context
import android.content.SharedPreferences
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

class ModbusChannel(private val channel: MethodChannel, private val context: Context) :
    MethodChannel.MethodCallHandler {

    private var modbus: ModbusRtu? = null

    // Slave IDs согласно схеме проекта
    private val SLAVE_DIO = 1        // MBSL16DI16DO
    private val SLAVE_THERMO = 2     // HLS-KWL-4TC
    private val SLAVE_ENERGY = 3     // DDS6619-039

    // Опрос монетоприёмника РЕЖИМА ОПЛАТЫ — работает только между
    // startPaymentCoinCounting()/stopPaymentCoinCounting() (на весь экран
    // оплаты, а не постоянно как раньше), поэтому не конкурирует с обычными
    // вызовами вне этого окна.
    private val lastCoinCents = AtomicInteger(0)
    private var paymentPollingThread: Thread? = null
    private val paymentPollingActive = AtomicBoolean(false)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "open" -> {
                val port = call.argument<String>("port") ?: "/dev/ttyS5"
                val baud = call.argument<Int>("baud") ?: 9600
                modbus = ModbusRtu()
                result.success(modbus!!.open(port, baud))
            }

            "close" -> {
                modbus?.close()
                modbus = null
                result.success(null)
            }

            "isOpen" -> result.success(modbus?.isOpen() == true)

            // Читает все 8 DI датчиков уровня (каналы 0-7)
            "readLevels" -> {
                val di = modbus?.readDiscreteInputs(SLAVE_DIO, 0, 8)
                if (di == null) result.error("MODBUS", "readLevels failed", null)
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
                val ok = modbus?.writeSingleCoil(SLAVE_DIO, ch, on) == true
                result.success(ok)
            }

            // Выключает ВСЕ выходы (safe_all_off)
            "safeAllOff" -> {
                var ok = true
                for (ch in 0..11) {
                    if (modbus?.writeSingleCoil(SLAVE_DIO, ch, false) != true) ok = false
                }
                result.success(ok)
            }

            // Читает температуру термопары (канал 0-3, возвращает °C × 10)
            "readTemperature" -> {
                val ch = call.argument<Int>("channel") ?: 0
                val regs = modbus?.readHoldingRegisters(SLAVE_THERMO, ch, 1)
                if (regs == null) result.error("MODBUS", "readTemperature failed", null)
                else result.success(regs[0].toDouble() / 10.0)
            }

            // Читает данные счётчика энергии DDS6619: напряжение (В), ток (А),
            // мощность (Вт), общий накопленный расход (кВт⋅ч)
            "readEnergy" -> {
                val energy = readEnergyValues()
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
            "getLastCoinCents" -> result.success(getLastCoinCents())

            else -> result.notImplemented()
        }
    }

    // Читает все 4 показателя счётчика энергии одним запросом-набором.
    // null, если хоть одно чтение по шине не удалось.
    private fun readEnergyValues(): Map<String, Double>? {
        val voltageReg = modbus?.readInputRegisters(SLAVE_ENERGY, 0x0000, 1)
        val currentReg = modbus?.readInputRegisters(SLAVE_ENERGY, 0x0003, 1)
        val powerReg = modbus?.readInputRegisters(SLAVE_ENERGY, 0x0008, 1)
        // Общий счётчик энергии — 32-битное значение (Long) в двух регистрах.
        val totalRegs = modbus?.readInputRegisters(SLAVE_ENERGY, 0x001D, 2)
        if (voltageReg == null || currentReg == null || powerReg == null || totalRegs == null) {
            return null
        }
        val highWord = totalRegs[0]
        val lowWord = totalRegs[1]
        val totalEnergy = ((highWord.toLong() shl 16) or lowWord.toLong()) * 0.01

        return mapOf(
            "voltage" to voltageReg[0].toDouble() / 10.0,
            "current" to currentReg[0].toDouble() / 100.0,
            "power" to powerReg[0].toDouble(),
            "totalEnergy" to totalEnergy
        )
    }

    private fun getMonthlyEnergy(): Double? {
        val totalEnergy = readEnergyValues()?.get("totalEnergy") ?: return null

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
    // одной монеты; пауза >350мс без новых импульсов завершает монету и
    // определяет номинал по количеству накопленных импульсов. Не запускает
    // второй поток, если один уже работает.
    private fun startPaymentCoinCounting() {
        if (paymentPollingActive.get()) return
        paymentPollingActive.set(true)
        paymentPollingThread = Thread {
            var previousState = false
            var pulseCount = 0
            var lastPulseTime = 0L
            while (paymentPollingActive.get()) {
                val current = modbus?.readDiscreteInputs(SLAVE_DIO, 8, 1, timeoutMs = 150L)
                    ?.getOrNull(0)
                val now = System.currentTimeMillis()
                if (current != null) {
                    if (!previousState && current) {
                        // Восходящий фронт — один импульс монеты.
                        pulseCount++
                        lastPulseTime = now
                    }
                    previousState = current
                }
                // Диагностика (лог CoinDebug с таймштампами) показала: реальные
                // паузы МЕЖДУ импульсами внутри одной монеты у этого приёмника
                // доходят до ~430мс. Порог завершения серии должен быть заметно
                // больше этого максимума, иначе монету рвёт на части (короткий
                // порог 350мс, который стоял здесь раньше, был ниже этого и
                // приводил именно к такому разрыву).
                if (pulseCount > 0 && now - lastPulseTime > 600) {
                    // Два номинала: 1-2 импульса → 1€, 3 и более → 2€
                    // (калибровка по реальному железу — см. docs/coin_acceptor.md).
                    val cents = if (pulseCount <= 2) 100 else 200
                    lastCoinCents.set(cents)
                    pulseCount = 0
                }
                try {
                    Thread.sleep(80)
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

    private fun getLastCoinCents(): Int = lastCoinCents.getAndSet(0)
}
