package com.example.dry_fog_app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.app.ActivityManager
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Process
import android.os.StatFs
import android.os.SystemClock
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.carfog.dryfog/modbus"
    private val STORAGE_CHANNEL = "com.carfog.dryfog/storage"
    private val SYSTEM_CHANNEL = "com.carfog.dryfog/system"

    // Признак "выведен из обслуживания" — отдельный файл с fsync/атомарным
    // rename и контрольной суммой (см. OutOfServiceStore). filesDir
    // инициализируется только после attachBaseContext, поэтому lazy.
    private val outOfServiceStore by lazy { OutOfServiceStore(filesDir) }
    private var modbusChannel: ModbusChannel? = null

    // true, если этот запуск активности вызван BootReceiver'ом
    // (Шаг 32, задача 1) — читается один раз в onCreate из intent-экстры,
    // отдаётся во Flutter через SYSTEM_CHANNEL.consumeStartReason (задача 6).
    private var startedFromBoot = false

    // Диагностика для задачи "приложение остаётся в фоне при холодном
    // старте" — сведения о ТОМ, как именно был запущен этот процесс,
    // снимаются один раз здесь и уходят во Flutter через
    // SYSTEM_CHANNEL.getLaunchDiagnostics, чтобы попасть в облачное
    // событие app_started и различать случаи без подключения к планшету.
    private var launchAction: String? = null
    private var launchCategories: List<String> = emptyList()
    private var launchIsTaskRoot: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startedFromBoot = intent?.getBooleanExtra(BootReceiver.EXTRA_STARTED_FROM_BOOT, false) == true
        launchAction = intent?.action
        launchCategories = intent?.categories?.toList() ?: emptyList()
        // isTaskRoot вычисляем сразу в onCreate — единственный надёжный
        // момент: singleInstance (см. AndroidManifest.xml) гарантирует
        // единственный экземпляр этой Activity, но сам факт "было ли ДО
        // сих пор запущено что-то ещё под этим же процессом/ролью" — то,
        // что раньше могло создавать второй экземпляр через роль домашнего
        // экрана параллельно с BootReceiver — виднее всего именно здесь.
        launchIsTaskRoot = isTaskRoot
        // Терминал без оператора рядом — экран не должен гаснуть сам
        // (Шаг 32, задача 5). Таймаут экрана в настройках прошивки всё
        // равно стоит выставить в "никогда" отдельно: этот флаг перекрывает
        // не все прошивки/энергосберегающие режимы.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        requestAllFilesAccessIfNeeded()
    }

    // MANAGE_EXTERNAL_STORAGE — особое разрешение, выдаётся только через
    // системный экран настроек, обычным диалогом запросить нельзя.
    // На киоск-терминале это одноразовый шаг при первом запуске/после
    // сброса: техник подтверждает в открывшихся настройках и возвращается
    // в приложение.
    private fun requestAllFilesAccessIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        if (Environment.isExternalStorageManager()) return
        try {
            startActivity(
                Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
        } catch (e: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            } catch (e2: Exception) {
                // Прошивка не поддерживает ни один из вариантов — разрешение
                // придётся выдать вручную (adb или системные настройки).
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Modbus-обмен — блокирующий I/O (таймауты чтения, sleep для
        // межфреймовой паузы и подавления эха). Обычный MethodChannel
        // выполняет onMethodCall на UI-потоке — при нескольких транзакциях
        // подряд (например полный опрос сканера или перебор скорости) это
        // уводит за границу ANR. Фоновая TaskQueue переносит обработку на
        // отдельный поток.
        val taskQueue = flutterEngine.dartExecutor.binaryMessenger
            .makeBackgroundTaskQueue(BinaryMessenger.TaskQueueOptions())
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL,
            StandardMethodCodec.INSTANCE,
            taskQueue
        )
        modbusChannel = ModbusChannel(channel, this)

        // Корневые пути всех примонтированных томов (внутренняя память +
        // SD-карта) через официальный Android API. Нужен, потому что
        // прямой листинг /storage/ из приложения запрещён политикой
        // хранения (Permission denied), даже когда конкретный вложенный
        // путь тома читается нормально — а сама SD-карта монтируется под
        // ID тома (например /storage/DCA3-BA1A), а не под предсказуемым
        // именем вроде sdcard1.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "listVolumeRoots") {
                    result.success(listVolumeRoots())
                } else {
                    result.notImplemented()
                }
            }

        // Киоск-режим (Шаг 32, задачи 3/5/6) — не ходит на Modbus-шину,
        // короткие вызовы к PackageManager/SharedPreferences/Settings,
        // поэтому обычный MethodChannel на платформенном потоке, без
        // фоновой очереди.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SYSTEM_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setKioskHomeEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        setKioskHomeEnabled(enabled)
                        result.success(null)
                    }
                    "openHomeSettings" -> {
                        openHomeSettings()
                        result.success(null)
                    }
                    "consumeStartReason" -> result.success(consumeStartReason())
                    // Каталог файлов приложения — для постоянного журнала
                    // (AppLog), который стартует до runApp.
                    "getFilesDir" -> result.success(filesDir.absolutePath)
                    // Версия Android, модель, аптайм, диск, память, сеть — для
                    // пакета диагностики (R1). Каждая группа в своём try:
                    // сбой одной не лишает остальных.
                    "getDeviceInfo" -> result.success(collectDeviceInfo())
                    // Удалённая команда restart_app: проверка "только в
                    // покое" делается в Dart ДО вызова; здесь — планирование
                    // подъёма через AlarmManager и завершение процесса.
                    "restartApp" -> {
                        result.success(true)
                        restartApp()
                    }
                    // Вывод аппарата из обслуживания (OutOfServiceStore) —
                    // синхронная запись с fsync, ответ приходит только
                    // после подтверждения записи на диск.
                    "writeOutOfService" -> {
                        val json = call.argument<String>("json")
                        result.success(
                            if (json == null) false else outOfServiceStore.write(json)
                        )
                    }
                    "readOutOfService" -> {
                        val r = outOfServiceStore.read()
                        result.success(
                            mapOf("status" to r.status.name.lowercase(), "json" to r.json)
                        )
                    }
                    "clearOutOfService" -> result.success(outOfServiceStore.clear())
                    "getLaunchDiagnostics" -> result.success(
                        mapOf(
                            "intent_action" to launchAction,
                            "intent_categories" to launchCategories,
                            "is_task_root" to launchIsTaskRoot,
                            "started_from_boot" to startedFromBoot,
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    // Включает/выключает роль домашнего экрана у KioskHomeAlias
    // (Шаг 32, задача 3). DONT_KILL_APP обязателен — без него система
    // перезапускает процесс сразу после смены флага, что убило бы
    // приложение прямо в момент переключения тумблера в сервисном меню.
    private fun setKioskHomeEnabled(enabled: Boolean) {
        val alias = ComponentName(this, "$packageName.KioskHomeAlias")
        val state = if (enabled) {
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED
        } else {
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED
        }
        packageManager.setComponentEnabledSetting(alias, state, PackageManager.DONT_KILL_APP)
    }

    // Системный экран "Приложение по умолчанию → Домашний экран" — для
    // кнопки "Открыть системный рабочий стол" (выход из киоска для
    // обслуживания) и сразу после включения тумблера киоск-режима.
    //
    // Одного выбора здесь достаточно, чтобы роль домашнего экрана сразу
    // заработала (проверено вживую), но НЕ достаточно для автоматического
    // восстановления после аварийного завершения без касаний экрана —
    // самостоятельный перезапуск домашнего приложения системой (задача 4)
    // опирается на классический механизм "предпочитаемой activity" для
    // намерения HOME, а не только на роль из RoleManager. Он заполняется
    // диалогом "Только сейчас/Всегда", который Android сам показывает при
    // следующем нажатии "Домой", если предпочтение ещё не разрешилось
    // однозначно — отдельно вызывать его программно не нужно (пробовал:
    // на этой прошивке вариант диалога с подсписком "Use a different app"
    // не закрепляет выбор так же надёжно, как естественный показ системой) —
    // техник просто должен один раз нажать "Домой" после выбора здесь и
    // подтвердить "Всегда", если диалог появится (см. подсказку в
    // сервисном меню).
    private fun openHomeSettings() {
        try {
            startActivity(Intent(Settings.ACTION_HOME_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            })
        } catch (e: Exception) {
            // Прошивка не поддерживает экран — оставляем как есть,
            // технику придётся переключать вручную через настройки Android.
        }
    }

    // Причина этого запуска приложения для облачного журнала (Шаг 32,
    // задача 6): "crash" — если предыдущий процесс упал (DryFogApplication
    // выставил и сохранил флаг через commit()), "boot" — если запущено
    // BootReceiver'ом после включения питания, иначе "normal". Флаг аварии
    // читается и сбрасывается одним вызовом (get-and-reset), как
    // getLastCoinCents в ModbusChannel — иначе следующий обычный запуск
    // снова показал бы "после сбоя".
    private fun consumeStartReason(): String {
        val prefs = getSharedPreferences(
            DryFogApplication.CRASH_PREFS,
            Context.MODE_PRIVATE
        )
        val crashed = prefs.getBoolean(DryFogApplication.KEY_RECOVERED_FROM_CRASH, false)
        if (crashed) {
            prefs.edit().putBoolean(DryFogApplication.KEY_RECOVERED_FROM_CRASH, false).apply()
            return "crash"
        }
        return if (startedFromBoot) "boot" else "normal"
    }

    // Съёмные тома (SD-карта) — первыми, встроенная память — в конце,
    // чтобы вызывающий код по умолчанию находил файлы именно на карте.
    private fun listVolumeRoots(): List<String> {
        val primary = mutableListOf<String>()
        val removable = mutableListOf<String>()
        try {
            val sm = getSystemService(Context.STORAGE_SERVICE) as StorageManager
            for (volume in sm.storageVolumes) {
                val path: String? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    volume.directory?.absolutePath
                } else {
                    // До API 30 путь официально не публикуется — getPath()
                    // скрытый метод, но стабильно присутствует на практике.
                    try {
                        volume.javaClass.getMethod("getPath").invoke(volume) as? String
                    } catch (e: Exception) {
                        null
                    }
                }
                if (path != null) {
                    if (volume.isPrimary) primary.add(path) else removable.add(path)
                }
            }
        } catch (e: Exception) {
            // Возвращаем то, что успели собрать (может быть пусто).
        }
        return removable + primary
    }

    private fun collectDeviceInfo(): Map<String, Any?> {
        val info = mutableMapOf<String, Any?>()
        try {
            info["android_release"] = Build.VERSION.RELEASE
            info["sdk_int"] = Build.VERSION.SDK_INT
            info["model"] = Build.MODEL
            info["manufacturer"] = Build.MANUFACTURER
            info["fingerprint"] = Build.FINGERPRINT
            info["build_type"] = Build.TYPE
            info["uptime_s"] = SystemClock.elapsedRealtime() / 1000
        } catch (e: Throwable) {
            info["device_error"] = e.toString()
        }
        try {
            val st = StatFs(filesDir.absolutePath)
            info["disk_free_bytes"] = st.availableBytes
            info["disk_total_bytes"] = st.totalBytes
        } catch (e: Throwable) {
            info["disk_error"] = e.toString()
        }
        try {
            val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val mi = ActivityManager.MemoryInfo()
            am.getMemoryInfo(mi)
            info["mem_free_bytes"] = mi.availMem
            info["mem_total_bytes"] = mi.totalMem
            info["mem_low"] = mi.lowMemory
        } catch (e: Throwable) {
            info["mem_error"] = e.toString()
        }
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val net = cm.activeNetwork
            val caps = if (net == null) null else cm.getNetworkCapabilities(net)
            if (caps == null) {
                info["net_type"] = "none"
            } else {
                info["net_type"] = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    else -> "other"
                }
                info["net_validated"] =
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val s = caps.signalStrength
                    if (s != NetworkCapabilities.SIGNAL_STRENGTH_UNSPECIFIED) info["net_signal"] = s
                }
            }
            @Suppress("DEPRECATION")
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            @Suppress("DEPRECATION")
            val rssi = wifi?.connectionInfo?.rssi
            if (rssi != null && rssi > -127) info["wifi_rssi_dbm"] = rssi
        } catch (e: Throwable) {
            info["net_error"] = e.toString()
        }
        return info
    }

    // Подъём приложения после завершения процесса — тем же AlarmManager-
    // механизмом, что и после аварии (DryFogApplication.scheduleRestart),
    // но БЕЗ отметки об аварии: причина запуска будет 'normal'. Задержка
    // даёт ответу в Dart уйти и журналу сброситься на диск.
    private fun restartApp() {
        (application as? DryFogApplication)?.scheduleRestart()
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
            Process.killProcess(Process.myPid())
        }, 1500)
    }

    override fun onDestroy() {
        // Освободить порт ДО обнуления: иначе новый экземпляр Activity в том
        // же процессе не сможет открыть шину (см. ModbusChannel.release).
        modbusChannel?.release()
        modbusChannel = null
        super.onDestroy()
    }
}
