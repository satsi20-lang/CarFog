package com.example.dry_fog_app

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController

// Решение «что делать с системными панелями сейчас» — без Android, для тестов.
//
// Два признака того, что панель на экране:
//  * barsVisible — вставки окна говорят «панель видна» (панель показана
//    постоянно: окно её не прячет);
//  * lostControl — окно потеряло управление панелью навигации. Так Android
//    показывает панель ВРЕМЕННО (свайп от края): управление отдаётся системе,
//    а во вставках окна панель по-прежнему «скрыта». Скрыть её должен
//    автоскрыватель SystemUI; на IXP101M1 (Lztek) он залипает
//    (mAutoHideSuspended=true, замер 03.11.2026) — панель висит навсегда.
//
// Признак держится delayMs → действие:
//  * HIDE — просто спрятать (постоянный показ);
//  * ABORT_AND_HIDE — «показать и сразу спрятать»: запрос показа от окна
//    прерывает временный показ (InsetsPolicy.checkAbortTransient) и
//    возвращает окну управление, затем панель прячется. Не чаще раза в
//    abortCooldownMs, чтобы панель не мигала, если управление не вернулось.
object SystemBarsDecision {
    enum class Action { NONE, HIDE, ABORT_AND_HIDE }

    data class State(val shownSinceMs: Long?, val action: Action)

    fun next(
        enabled: Boolean,
        barsVisible: Boolean,
        lostControl: Boolean,
        shownSinceMs: Long?,
        lastAbortMs: Long?,
        nowMs: Long,
        delayMs: Long,
        abortCooldownMs: Long,
    ): State {
        if (!enabled || (!barsVisible && !lostControl)) return State(null, Action.NONE)
        val since = shownSinceMs ?: nowMs
        if (nowMs - since < delayMs) return State(since, Action.NONE)
        if (lostControl) {
            val cooled = lastAbortMs == null || nowMs - lastAbortMs >= abortCooldownMs
            return if (cooled) State(null, Action.ABORT_AND_HIDE) else State(since, Action.NONE)
        }
        return State(null, Action.HIDE)
    }
}

// Сторож системных панелей для IXP101M1 (CARFOG-001, прошивка Lztek): там под
// Lock Task полоска навигации, вызванная свайпом снизу, иногда оставалась на
// экране навсегда и перекрывала кнопки. Включается из Dart только для профиля
// ixp101m1 (setSystemBarsGuard); на SY156-A510 не включается вовсе —
// поведение прежнее (immersiveSticky Flutter, без сторожа).
//
// Включённый сторож прячет панели (immersive, показ свайпом — временный) при
// включении, в onResume, при получении окном фокуса и раз в секунду проверяет
// SystemBarsDecision: панель видна или окно без управления панелью 2 с и
// дольше — спрятать (при потере управления — прервать временный показ).
class SystemBarsGuard(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())
    private var enabled = false
    private var resumed = false
    private var delayMs = DEFAULT_DELAY_MS
    private var shownSinceMs: Long? = null
    private var lastAbortMs: Long? = null

    // Управляет ли окно панелью навигации (OnControllableInsetsChanged).
    // До первого сигнала считаем, что управляет.
    private var navControllable = true
    private var controlListenerAdded = false

    private val tick = object : Runnable {
        override fun run() {
            check()
            if (enabled && resumed) handler.postDelayed(this, TICK_MS)
        }
    }

    fun setEnabled(on: Boolean, hideDelayMs: Long = DEFAULT_DELAY_MS) {
        enabled = on
        delayMs = hideDelayMs.coerceIn(500L, 10_000L)
        shownSinceMs = null
        handler.removeCallbacks(tick)
        if (!on) return
        listenControl()
        hide("включение")
        if (resumed) handler.postDelayed(tick, TICK_MS)
    }

    fun onResume() {
        resumed = true
        if (!enabled) return
        listenControl()
        hide("onResume")
        handler.removeCallbacks(tick)
        handler.postDelayed(tick, TICK_MS)
    }

    fun onPause() {
        resumed = false
        handler.removeCallbacks(tick)
    }

    fun onWindowFocusChanged(hasFocus: Boolean) {
        if (enabled && hasFocus) hide("фокус")
    }

    private fun listenControl() {
        if (controlListenerAdded || Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val controller = activity.window?.insetsController ?: return
        controller.addOnControllableInsetsChangedListener { _, types ->
            val now = (types and WindowInsets.Type.navigationBars()) != 0
            if (now != navControllable) {
                android.util.Log.i(
                    TAG,
                    if (now) "управление панелью вернулось окну"
                    else "окно потеряло управление панелью (временный показ)",
                )
            }
            navControllable = now
        }
        controlListenerAdded = true
    }

    private fun check() {
        val now = SystemClock.elapsedRealtime()
        val s = SystemBarsDecision.next(
            enabled = enabled,
            barsVisible = barsVisible(),
            lostControl = !navControllable,
            shownSinceMs = shownSinceMs,
            lastAbortMs = lastAbortMs,
            nowMs = now,
            delayMs = delayMs,
            abortCooldownMs = ABORT_COOLDOWN_MS,
        )
        shownSinceMs = s.shownSinceMs
        when (s.action) {
            SystemBarsDecision.Action.NONE -> {}
            SystemBarsDecision.Action.HIDE -> hide("панель видна $delayMs мс")
            SystemBarsDecision.Action.ABORT_AND_HIDE -> {
                lastAbortMs = now
                abortTransientAndHide()
            }
        }
    }

    private fun barsVisible(): Boolean {
        val decor = activity.window?.decorView ?: return false
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val insets = decor.rootWindowInsets ?: return false
            insets.isVisible(WindowInsets.Type.navigationBars()) ||
                insets.isVisible(WindowInsets.Type.statusBars())
        } else {
            @Suppress("DEPRECATION")
            (decor.systemUiVisibility and View.SYSTEM_UI_FLAG_HIDE_NAVIGATION) == 0
        }
    }

    // Временный показ залип: запрос «показать» прерывает его и возвращает
    // окну управление, следом — «спрятать» (сразу и ещё раз через 150 мс,
    // когда управление уже точно у окна).
    private fun abortTransientAndHide() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            hide("потеря управления")
            return
        }
        val controller = activity.window?.insetsController ?: return
        try {
            controller.show(WindowInsets.Type.systemBars())
            android.util.Log.i(TAG, "временный показ прерван (окно без управления $delayMs мс)")
        } catch (e: Throwable) {
            android.util.Log.e(TAG, "не удалось прервать временный показ: $e")
        }
        hide("после прерывания")
        handler.postDelayed({ if (enabled) hide("после прерывания, повтор") }, 150L)
    }

    private fun hide(reason: String) {
        val window = activity.window ?: return
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                window.insetsController?.let {
                    it.systemBarsBehavior =
                        WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
                    it.hide(WindowInsets.Type.systemBars())
                }
            } else {
                // Те же флаги, что ставит Flutter для immersiveSticky.
                @Suppress("DEPRECATION")
                window.decorView.systemUiVisibility = (
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or
                        View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or
                        View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or
                        View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                        View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                        View.SYSTEM_UI_FLAG_FULLSCREEN
                    )
            }
            android.util.Log.i(TAG, "панели спрятаны ($reason)")
        } catch (e: Throwable) {
            android.util.Log.e(TAG, "не удалось спрятать панели ($reason): $e")
        }
    }

    companion object {
        private const val TAG = "SystemBarsGuard"
        const val DEFAULT_DELAY_MS = 2000L
        const val TICK_MS = 1000L
        const val ABORT_COOLDOWN_MS = 10_000L
    }
}
