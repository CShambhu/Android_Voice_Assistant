package com.example.android_voice_assistant

import android.app.Activity
import android.app.KeyguardManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager

// Shows Android's OWN unlock screen over the lock screen. The user unlocks
// with their fingerprint / face / PIN; Hello Boss never sees or enters it.
// After a successful unlock the pending command runs.
class UnlockActivity : Activity() {

    companion object {
        const val EXTRA_FEATURE = "feature"
        const val EXTRA_DESIRED = "desired"
        private const val TAG = "HelloBossUnlock"
        private const val MAX_TRIES = 3
        // A "cancel" sooner than this after asking is Android refusing a
        // request made too early, not the user pressing Back.
        private const val TOO_FAST_MS = 1500L
    }

    private val handler = Handler(Looper.getMainLooper())
    private var feature: DeviceControl.Feature? = null
    private var desired: Boolean? = null
    private var tries = 0
    private var finished = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.e(TAG, "UnlockActivity opened")

        @Suppress("DEPRECATION")
        window.addFlags(
            WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        )

        feature = try {
            DeviceControl.Feature.valueOf(intent.getStringExtra(EXTRA_FEATURE) ?: "")
        } catch (e: Exception) {
            null
        }

        if (feature == null) {
            finishOnce()
            return
        }

        desired = when (intent.getStringExtra(EXTRA_DESIRED)) {
            "true" -> true
            "false" -> false
            else -> null
        }
    }

    // Ask only once the window really has focus; asking in onCreate is
    // what made Android cancel the request straight away.
    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)

        if (hasFocus && tries == 0 && feature != null && !finished) {
            handler.postDelayed({ askToUnlock() }, 400)
        }
    }

    private fun askToUnlock() {
        if (finished || isDestroyed) return

        val f = feature ?: return
        tries++
        val askedAt = SystemClock.elapsedRealtime()

        Log.i(TAG, "Asking to unlock (try $tries)")

        val keyguard = getSystemService(KEYGUARD_SERVICE) as KeyguardManager

        keyguard.requestDismissKeyguard(
            this,
            object : KeyguardManager.KeyguardDismissCallback() {

                override fun onDismissSucceeded() {
                    Log.i(TAG, "Unlocked by the user, running ${f.display}")
                    finishOnce()

                    Handler(Looper.getMainLooper()).postDelayed({
                        DeviceControl.execute(
                            applicationContext,
                            f,
                            desired
                        ) { message ->
                            MainActivity.emitServiceEvent("status", message)
                        }
                    }, 700)
                }

                override fun onDismissCancelled() {
                    val fast = SystemClock.elapsedRealtime() - askedAt < TOO_FAST_MS

                    if (fast && tries < MAX_TRIES && !finished) {
                        Log.i(TAG, "Android cancelled too early, trying again")
                        handler.postDelayed({ askToUnlock() }, 600)
                    } else {
                        Log.i(TAG, "Unlock cancelled")
                        finishOnce()
                    }
                }

                override fun onDismissError() {
                    Log.e(TAG, "Unlock prompt failed")
                    finishOnce()
                }
            }
        )
    }

    private fun finishOnce() {
        if (finished) return
        finished = true
        handler.removeCallbacksAndMessages(null)
        finish()
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }
}