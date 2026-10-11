package com.example.dry_fog_app

import android.app.Activity
import android.app.ActivityManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import java.lang.ref.WeakReference

// Решения киоска без Android API — проверяются юнит-тестами.
object KioskDecision {
    // Блокировка действует, если приложение — Device Owner, техник включил её
    // и не идёт временный выход (exitUntil — момент SystemClock.elapsedRealtime,
    // до которого блокировка снята; 0 — выхода нет).
    fun shouldLock(deviceOwner: Boolean, lockEnabled: Boolean, exitUntil: Long, now: Long): Boolean =
        deviceOwner && lockEnabled && now >= exitUntil

    fun exitRemainingMs(exitUntil: Long, now: Long): Long =
        if (exitUntil <= now) 0L else exitUntil - now
}

// Киоск через Device Owner (эксперимент device-owner-spike): Lock Task без
// шторки, Home, Overview и меню питания, отключённая строка состояния и
// закреплённая роль HOME. Всё работает, только если приложение назначено
// владельцем устройства; иначе методы возвращают RESULT_NO_DEVICE_OWNER и
// ничего не трогают — приложение ведёт себя как раньше (старый киоск через
// KioskHomeAlias не затрагивается).
//
// Состояние:
//  * «блокировка включена» — SharedPreferences, переживает перезапуск и
//    перезагрузку, применяется в MainActivity.onResume;
//  * временный выход для техника — только в памяти процесса: таймер на
//    главном потоке не зависит от паузы активности, а после перезапуска
//    приложения выхода нет и блокировка включается сразу.
object KioskPolicy {
    private const val TAG = "KioskPolicy"
    private const val PREFS = "kiosk_policy"
    private const val KEY_LOCK_ENABLED = "lock_enabled"
    const val EXIT_WINDOW_MS = 10 * 60 * 1000L

    const val RESULT_OK = "ok"
    const val RESULT_NO_DEVICE_OWNER = "no_device_owner"

    private val handler = Handler(Looper.getMainLooper())
    private var exitUntil = 0L
    private val relockTask = Runnable { relock() }
    // Политики уже применены в этом процессе (не повторять на каждом onResume).
    private var policiesApplied = false
    private var activityRef: WeakReference<Activity>? = null
    // Контекст приложения для таймера, если активности уже нет.
    private var appContext: Context? = null

    // Журнал: строки уходят в AppLog через канал Flutter (MainActivity
    // подключает sink); до подключения копятся здесь.
    private val pendingLog = mutableListOf<String>()
    private var logSink: ((String) -> Unit)? = null

    fun log(context: Context?, message: String) {
        Log.i(TAG, message)
        handler.post {
            val sink = logSink
            if (sink != null) sink(message)
            else if (pendingLog.size < 50) pendingLog.add(message)
        }
    }

    fun attachLogSink(sink: ((String) -> Unit)?) {
        handler.post {
            logSink = sink
            if (sink != null) {
                pendingLog.forEach(sink)
                pendingLog.clear()
            }
        }
    }

    private fun dpm(context: Context) =
        context.getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    private fun admin(context: Context) = ComponentName(context, CarfogAdminReceiver::class.java)

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun isDeviceOwner(context: Context): Boolean = try {
        dpm(context).isDeviceOwnerApp(context.packageName)
    } catch (e: Throwable) {
        false
    }

    fun isLockEnabled(context: Context): Boolean =
        prefs(context).getBoolean(KEY_LOCK_ENABLED, false)

    private fun lockTaskActive(context: Context): Boolean = try {
        val am = context.getSystemService(ActivityManager::class.java)
        am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
    } catch (e: Throwable) {
        false
    }

    fun state(context: Context): Map<String, Any?> {
        val now = SystemClock.elapsedRealtime()
        return mapOf(
            "device_owner" to isDeviceOwner(context),
            "lock_enabled" to isLockEnabled(context),
            "lock_task_active" to lockTaskActive(context),
            "exit_remaining_ms" to KioskDecision.exitRemainingMs(exitUntil, now),
        )
    }

    // ---- вызовы активности ----

    fun onActivityResumed(activity: Activity) {
        activityRef = WeakReference(activity)
        val ctx = activity.applicationContext
        appContext = ctx
        val owner = isDeviceOwner(ctx)
        if (!KioskDecision.shouldLock(owner, isLockEnabled(ctx), exitUntil, SystemClock.elapsedRealtime())) return
        try {
            if (!policiesApplied) applyPolicies(ctx)
            if (!lockTaskActive(ctx)) {
                activity.startLockTask()
                log(ctx, "Lock Task включён")
            }
        } catch (e: Throwable) {
            log(ctx, "ошибка включения блокировки: $e")
        }
    }

    fun onActivityDestroyed(activity: Activity) {
        if (activityRef?.get() === activity) activityRef = null
    }

    // ---- действия техника (вкладка «Киоск») ----

    fun setLockEnabled(activity: Activity, enabled: Boolean): String {
        val ctx = activity.applicationContext
        if (!isDeviceOwner(ctx)) return RESULT_NO_DEVICE_OWNER
        return try {
            prefs(ctx).edit().putBoolean(KEY_LOCK_ENABLED, enabled).commit()
            cancelExit()
            if (enabled) {
                applyPolicies(ctx)
                if (!lockTaskActive(ctx)) activity.startLockTask()
                log(ctx, "блокировка включена техником")
            } else {
                stopLockTask(activity)
                releasePolicies(ctx)
                log(ctx, "блокировка выключена техником")
            }
            RESULT_OK
        } catch (e: Throwable) {
            log(ctx, "ошибка переключения блокировки: $e")
            "error: $e"
        }
    }

    // Временный выход на EXIT_WINDOW_MS; openSettings — сразу открыть
    // системные настройки. По истечении блокировка включается сама.
    fun temporaryExit(activity: Activity, openSettings: Boolean): String {
        val ctx = activity.applicationContext
        if (!isDeviceOwner(ctx)) return RESULT_NO_DEVICE_OWNER
        return try {
            stopLockTask(activity)
            dpm(ctx).setStatusBarDisabled(admin(ctx), false)
            exitUntil = SystemClock.elapsedRealtime() + EXIT_WINDOW_MS
            handler.removeCallbacks(relockTask)
            handler.postDelayed(relockTask, EXIT_WINDOW_MS)
            val minutes = EXIT_WINDOW_MS / 60000.0
            log(ctx, "временный выход на $minutes мин" + if (openSettings) ", открыты настройки" else "")
            if (openSettings) {
                activity.startActivity(
                    Intent(Settings.ACTION_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
            RESULT_OK
        } catch (e: Throwable) {
            log(ctx, "ошибка временного выхода: $e")
            "error: $e"
        }
    }

    // Снятие Device Owner: сначала выход из Lock Task и отмена всех наших
    // политик, затем clearDeviceOwnerApp.
    fun clearDeviceOwner(activity: Activity): String {
        val ctx = activity.applicationContext
        if (!isDeviceOwner(ctx)) return RESULT_NO_DEVICE_OWNER
        return try {
            cancelExit()
            prefs(ctx).edit().putBoolean(KEY_LOCK_ENABLED, false).commit()
            stopLockTask(activity)
            releasePolicies(ctx)
            @Suppress("DEPRECATION")
            dpm(ctx).clearDeviceOwnerApp(ctx.packageName)
            log(ctx, "Device Owner снят")
            RESULT_OK
        } catch (e: Throwable) {
            log(ctx, "ошибка снятия Device Owner: $e")
            "error: $e"
        }
    }

    // После замены APK: Android возвращает KioskHomeAlias к состоянию из
    // манифеста (выключен) — восстановить роль HOME, если блокировка включена.
    fun onPackageReplaced(context: Context) {
        if (!isDeviceOwner(context) || !isLockEnabled(context)) return
        try {
            val aliasState = context.packageManager
                .getComponentEnabledSetting(ComponentNames.kioskHomeAlias(context))
            log(context, "обновление APK: состояние KioskHomeAlias до восстановления = $aliasState")
            applyPolicies(context)
            log(context, "обновление APK: политики киоска восстановлены")
        } catch (e: Throwable) {
            log(context, "ошибка восстановления после обновления: $e")
        }
    }

    // ---- внутреннее ----

    private fun applyPolicies(ctx: Context) {
        val dpm = dpm(ctx)
        val admin = admin(ctx)
        dpm.setLockTaskPackages(admin, arrayOf(ctx.packageName))
        dpm.setLockTaskFeatures(admin, DevicePolicyManager.LOCK_TASK_FEATURE_NONE)
        dpm.setStatusBarDisabled(admin, true)
        val alias = ComponentNames.kioskHomeAlias(ctx)
        ctx.packageManager.setComponentEnabledSetting(
            alias, PackageManager.COMPONENT_ENABLED_STATE_ENABLED, PackageManager.DONT_KILL_APP
        )
        val home = IntentFilter(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_HOME)
            addCategory(Intent.CATEGORY_DEFAULT)
        }
        dpm.addPersistentPreferredActivity(admin, home, alias)
        policiesApplied = true
    }

    // Отмена наших политик; KioskHomeAlias возвращается к старому тумблеру
    // «Киоск-режим».
    private fun releasePolicies(ctx: Context) {
        val dpm = dpm(ctx)
        val admin = admin(ctx)
        dpm.setStatusBarDisabled(admin, false)
        dpm.clearPackagePersistentPreferredActivities(admin, ctx.packageName)
        dpm.setLockTaskPackages(admin, arrayOf())
        val oldKiosk = PackageUpdateReceiver.readKioskModeEnabled(ctx) ?: false
        ctx.packageManager.setComponentEnabledSetting(
            ComponentNames.kioskHomeAlias(ctx),
            if (oldKiosk) PackageManager.COMPONENT_ENABLED_STATE_ENABLED
            else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
        policiesApplied = false
    }

    private fun stopLockTask(activity: Activity) {
        if (lockTaskActive(activity)) activity.stopLockTask()
    }

    private fun cancelExit() {
        handler.removeCallbacks(relockTask)
        exitUntil = 0L
    }

    // Таймер временного выхода истёк.
    private fun relock() {
        exitUntil = 0L
        val activity = activityRef?.get()
        val ctx = activity?.applicationContext ?: appContext ?: return
        if (!isDeviceOwner(ctx) || !isLockEnabled(ctx)) return
        try {
            applyPolicies(ctx)
            log(ctx, "временный выход истёк, блокировка возвращается")
            // Активность на переднем плане — закрепить сразу; иначе (открыты
            // настройки) поднять её, onResume закрепит. Device Owner не
            // подпадает под запрет запуска активности из фона.
            if (activity != null && activity.hasWindowFocus()) {
                activity.startLockTask()
            } else {
                ctx.startActivity(
                    Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            }
        } catch (e: Throwable) {
            log(ctx, "ошибка возврата блокировки: $e")
        }
    }
}
