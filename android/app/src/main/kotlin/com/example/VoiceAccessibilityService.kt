
package com.example.android_voice_assistant

import android.accessibilityservice.AccessibilityService
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

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // No event processing is needed for Home and Back commands.
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
