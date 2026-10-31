package com.example.android_voice_assistant

import android.accessibilityservice.AccessibilityService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

class VoiceAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: VoiceAccessibilityService? = null
            private set
    }

    private val uiHandler = Handler(Looper.getMainLooper())

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

    fun goHome(): Boolean = performGlobalAction(GLOBAL_ACTION_HOME)

    fun goBack(): Boolean = performGlobalAction(GLOBAL_ACTION_BACK)

    fun openRecentApps(): Boolean = performGlobalAction(GLOBAL_ACTION_RECENTS)

    // ---------------- Phone controls ----------------

    fun captureScreenshot(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            performGlobalAction(GLOBAL_ACTION_TAKE_SCREENSHOT)

    private fun closePanel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            performGlobalAction(GLOBAL_ACTION_DISMISS_NOTIFICATION_SHADE)
        } else {
            performGlobalAction(GLOBAL_ACTION_BACK)
        }
    }

    private fun textOf(node: AccessibilityNodeInfo): String {
        val sb = StringBuilder()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            sb.append(node.stateDescription ?: "").append(' ')
        }

        sb.append(node.text ?: "").append(' ').append(node.contentDescription ?: "")
        return sb.toString().lowercase()
    }

    // true = ON, false = OFF, null = can't tell
    private fun stateOf(node: AccessibilityNodeInfo): Boolean? {
        if (node.isCheckable) return node.isChecked

        val s = textOf(node)

        return when {
            Regex("\\boff\\b").containsMatchIn(s) -> false
            Regex("\\bon\\b").containsMatchIn(s) -> true
            else -> null
        }
    }

    // Finds a node whose text/description contains a label, then returns its clickable parent.
    private fun findClickable(
        root: AccessibilityNodeInfo?,
        labels: List<String>
    ): AccessibilityNodeInfo? {
        if (root == null) return null

        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)

        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            val text = "${node.text ?: ""} ${node.contentDescription ?: ""}".lowercase()

            if (labels.any { text.contains(it) }) {
                var cur: AccessibilityNodeInfo? = node
                while (cur != null && !cur.isClickable) cur = cur.parent
                if (cur != null) return cur
            }

            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { queue.add(it) }
            }
        }

        return null
    }

    /**
     * Opens Quick Settings, finds the tile, taps it (only if needed), then closes the panel.
     * desired: true = ON, false = OFF, null = just tap it.
     */
    fun toggleQuickSettingTile(
        labels: List<String>,
        desired: Boolean?,
        dialogLabels: List<String> = emptyList(),
        onResult: (TileResult) -> Unit
    ) {
        if (!performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)) {
            onResult(TileResult.NOT_FOUND)
            return
        }

        var attempts = 0

        val poll = object : Runnable {
            override fun run() {
                val tile = findClickable(rootInActiveWindow, labels)

                if (tile == null) {
                    attempts++

                    if (attempts < 12) {
                        uiHandler.postDelayed(this, 250)
                    } else {
                        closePanel()
                        onResult(TileResult.NOT_FOUND)
                    }
                    return
                }

                // Pixel's merged "Internet" tile opens a dialog instead of toggling.
                val viaDialog =
                    dialogLabels.isNotEmpty() && textOf(tile).contains("internet")

                if (!viaDialog && desired != null && stateOf(tile) == desired) {
                    closePanel()
                    onResult(TileResult.ALREADY)
                    return
                }

                tile.performAction(AccessibilityNodeInfo.ACTION_CLICK)

                if (viaDialog) {
                    uiHandler.postDelayed(
                        { handleDialog(dialogLabels, desired, onResult) },
                        900
                    )
                } else {
                    uiHandler.postDelayed({
                        closePanel()
                        onResult(TileResult.CHANGED)
                    }, 500)
                }
            }
        }

        uiHandler.postDelayed(poll, 600)
    }

    private fun handleDialog(
        labels: List<String>,
        desired: Boolean?,
        onResult: (TileResult) -> Unit
    ) {
        val target = findClickable(rootInActiveWindow, labels)

        if (target == null) {
            performGlobalAction(GLOBAL_ACTION_BACK)
            closePanel()
            onResult(TileResult.NOT_FOUND)
            return
        }

        val already = desired != null && stateOf(target) == desired

        if (!already) target.performAction(AccessibilityNodeInfo.ACTION_CLICK)

        uiHandler.postDelayed({
            performGlobalAction(GLOBAL_ACTION_BACK)
            closePanel()
            onResult(if (already) TileResult.ALREADY else TileResult.CHANGED)
        }, 600)
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }
}