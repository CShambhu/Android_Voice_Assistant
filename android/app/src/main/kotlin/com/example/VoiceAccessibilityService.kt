
package com.example.android_voice_assistant

import android.accessibilityservice.AccessibilityService
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent

class VoiceAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: VoiceAccessibilityService? = null
            private set
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    /** Package of the app currently in front (best effort). */
    @Volatile
    var foregroundPackage: String? = null
        private set

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        if (event?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            return
        }

        val pkg = event.packageName?.toString() ?: return

        // Ignore system UI and the keyboard: they overlay the real app.
        if (pkg == "com.android.systemui") return

        val keyboard = Settings.Secure
            .getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.substringBefore('/')

        if (pkg == keyboard) return

                // Ignore the speech recognizer too: its window can appear while
        // Hello Boss listens and would hide the real app in front.
        val recognizer = Settings.Secure
            .getString(contentResolver, "voice_recognition_service")
            ?.substringBefore('/')

        if (pkg == recognizer) return

        foregroundPackage = pkg
    }

    override fun onInterrupt() {
        // Required by AccessibilityService.
    }

    fun goHome(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_HOME)
    }

    fun goBack(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_BACK)
    }

    fun openRecentApps(): Boolean {
        return performGlobalAction(GLOBAL_ACTION_RECENTS)
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }
}