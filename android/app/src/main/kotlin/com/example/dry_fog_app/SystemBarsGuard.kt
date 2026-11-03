package com.example.dry_fog_app

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController

// Решение «прятать ли системные панели сейчас» — без Android, для тестов.
// Панель (полоска «Назад» после свайпа снизу) видна дольше delayMs —
// спрятать; не видна — забыть момент появления.
object SystemBarsDecision {
    data class State(val visibleSinceMs: Long?, val hide: Boolean)

    fun next(
        enabled: Boolean,
        barsVisible: Boolean,
        visibleSinceMs: Long?,
        nowMs: Long,
        delayMs: Long,
    ): State {
        if (!enabled || !barsVisible) return State(null, false)
        val since = visibleSinceMs ?: nowMs
        return State(since, nowMs - since >= delayMs)
    }
}

// Сторож системных панелей для IXP101M1 (CARFOG-001, прошивка Lztek): там под
// Lock Task полоска навигации, вызванная свайпом снизу, оставалась на экране
// и перекрывала кнопки. Включается из Dart только для профиля ixp101m1
// (setSystemBarsGuard); на SY156-A510 не включается вовсе — поведение
// прежнее (immersiveSticky Flutter, без сторожа).
//
// Включённый сторож прячет панели (immersive, показ свайпом — временный) при
// включении, в onResume, при получении окном фокуса и раз в секунду, если
// панель видна дольше delayMs.
class SystemBarsGuard(private val activity: Activity) {
    private val handler = Handler(Looper.getMainLooper())
    private var enabled = false
    private var resumed = false
    private var delayMs = DEFAULT_DELAY_MS
    private var visibleSinceMs: Long? = null

    private val tick = object : Runnable {
        override fun run() {
            check()
            if (enabled && resumed) handler.postDelayed(this, TICK_MS)
        }
    }

    fun setEnabled(on: Boolean, hideDelayMs: Long = DEFAULT_DELAY_MS) {
        enabled = on
        delayMs = hideDelayMs.coerceIn(500L, 10_000L)
        visibleSinceMs = null
        handler.removeCallbacks(tick)
        if (!on) return
        hide("включение")
        if (resumed) handler.postDelayed(tick, TICK_MS)
    }

    fun onResume() {
        resumed = true
        if (!enabled) return
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

    private fun check() {
        val s = SystemBarsDecision.next(
            enabled, barsVisible(), visibleSinceMs, SystemClock.elapsedRealtime(), delayMs,
        )
        visibleSinceMs = s.visibleSinceMs
        if (s.hide) {
            hide("панель видна ${delayMs} мс")
            visibleSinceMs = null
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
    }
}
