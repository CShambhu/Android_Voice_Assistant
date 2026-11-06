package com.example.android_voice_assistant

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.Locale

enum class TileResult { CHANGED, ALREADY, NOT_FOUND, FAILED }

class VoiceAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: VoiceAccessibilityService? = null
            private set

        // Filter logcat with this tag to see what the Quick Settings panel
        // looked like when a phone control failed.
        private const val TILE_TAG = "HelloBossTiles"
    }

    private val uiHandler = Handler(Looper.getMainLooper())

    // Option to pick if the tile opens a choice dialog (e.g. Do Not Disturb:
    // "Until I turn it off"). Set by toggleQuickSettingTile.
    private var choiceLabels: List<String> = emptyList()

    /** What the panel contained the last time a tile could not be found. */
    @Volatile
    var lastPanelDump: String = ""
        private set

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
    val parts = mutableListOf<String>()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        node.stateDescription?.toString()?.let(parts::add)
    }

    node.text?.toString()?.let(parts::add)
    node.contentDescription?.toString()?.let(parts::add)

    return parts.joinToString(" ").lowercase(Locale.ROOT)
}


private fun stateOf(node: AccessibilityNodeInfo): Boolean? {

    // Use Android's actual checked state.
    if (node.isCheckable) {
        return node.isChecked
    }

    // Use selected state only when the node is explicitly selected.
    if (node.isSelected) {
        return true
    }

    // Accessibility descriptions are manufacturer-dependent.
    // Do not guess the state from words such as ON/OFF.
    return null
}


    // Every window we can read, Quick Settings (SystemUI) first.
    // Hello Boss's own screen is skipped so a "Wi-Fi" label in our own
    // list can't be tapped by mistake.
    private fun systemRoots(): List<AccessibilityNodeInfo> {
        val roots = ArrayList<AccessibilityNodeInfo>()

        try {
            for (window in windows) {
                window.root?.let { roots.add(it) }
            }
        } catch (e: Exception) {
            Log.w(TILE_TAG, "Could not read windows", e)
        }

        rootInActiveWindow?.let { roots.add(it) }

        return roots
            .filter { it.packageName?.toString() != packageName }
            .sortedByDescending {
                it.packageName?.toString()
                    ?.contains("systemui", ignoreCase = true) == true
            }
    }

    private fun findClickable(
    labels: List<String>
): AccessibilityNodeInfo? {

    val candidates = ArrayList<AccessibilityNodeInfo>()
    val minTileSize = (40 * resources.displayMetrics.density).toInt()

    for (root in systemRoots()) {
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(root)

        while (queue.isNotEmpty()) {
            val node = queue.removeFirst()
            val text = textOf(node)

            if (node.isVisibleToUser &&
                labels.any { label ->
                    text.contains(label, ignoreCase = true)
                }
            ) {
                var clickable: AccessibilityNodeInfo? = node

                while (clickable != null && !clickable.isClickable) {
                    clickable = clickable.parent
                }

                if (clickable != null && clickable.isVisibleToUser) {
                    val bounds = Rect()
                    clickable.getBoundsInScreen(bounds)

                    // Reject small status-bar icons and unrelated controls.
                    if (bounds.width() >= minTileSize &&
                        bounds.height() >= minTileSize
                    ) {
                        candidates.add(clickable)
                    }
                }
            }

            for (i in 0 until node.childCount) {
                node.getChild(i)?.let { queue.add(it) }
            }
        }

        if (candidates.isNotEmpty()) break
    }

    return candidates.firstOrNull { it.isLongClickable }
        ?: candidates.firstOrNull()
}


    // Writes what the panel contained to logcat (tag: HelloBossTiles).
    private fun logPanelLabels(reason: String) {
        val seen = LinkedHashSet<String>()

        for (root in systemRoots()) {
            val queue = ArrayDeque<AccessibilityNodeInfo>()
            queue.add(root)

            while (queue.isNotEmpty() && seen.size < 80) {
                val node = queue.removeFirst()
                val text =
                    "${node.text ?: ""} ${node.contentDescription ?: ""}".trim()

                if (text.isNotEmpty()) seen.add(text)

                for (i in 0 until node.childCount) {
                    node.getChild(i)?.let { queue.add(it) }
                }
            }
        }

        lastPanelDump = seen.take(25).joinToString(" | ")

        Log.i(TILE_TAG, "$reason. Labels on screen: $seen")
    }

    private fun gesture(
        x1: Float,
        y1: Float,
        x2: Float,
        y2: Float,
        durationMs: Long
    ): Boolean {
        val path = Path().apply {
            moveTo(x1, y1)
            if (x1 != x2 || y1 != y2) lineTo(x2, y2)
        }

        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)

        return try {
            dispatchGesture(
                GestureDescription.Builder().addStroke(stroke).build(),
                null,
                null
            )
        } catch (e: Exception) {
            Log.w(TILE_TAG, "Gesture failed", e)
            false
        }
    }

    // Plain screen tap on a node, for tiles that ignore ACTION_CLICK.
    private fun tap(node: AccessibilityNodeInfo): Boolean {
        val bounds = Rect()
        node.getBoundsInScreen(bounds)

        if (bounds.isEmpty) return false

        return gesture(bounds.exactCenterX(), bounds.exactCenterY(),
            bounds.exactCenterX(), bounds.exactCenterY(), 60)
    }

    // Some tiles (Flight mode, Hotspot, Dark mode...) sit on the panel's
    // 2nd page. Swipe the tile area sideways to reach them. The swipe height
    // changes on every try, because one fixed height can miss the tile grid.
    private var swipeTry = 0

    private fun showNextTilePage() {
        // Best case: the pager can scroll itself.
        for (root in systemRoots()) {
            val queue = ArrayDeque<AccessibilityNodeInfo>()
            queue.add(root)

            while (queue.isNotEmpty()) {
                val node = queue.removeFirst()

                val canScrollSideways = node.actionList.any {
                    it.id == AccessibilityNodeInfo.AccessibilityAction
                        .ACTION_SCROLL_LEFT.id
                }

                if (canScrollSideways && node.isVisibleToUser &&
                    node.performAction(
                        AccessibilityNodeInfo.AccessibilityAction
                            .ACTION_SCROLL_LEFT.id
                    )
                ) {
                    Log.i(TILE_TAG, "Next tile page: pager scroll")
                    return
                }

                for (i in 0 until node.childCount) {
                    node.getChild(i)?.let { queue.add(it) }
                }
            }
        }

        // Otherwise swipe with a finger gesture.
        val metrics = resources.displayMetrics
        val heights = floatArrayOf(0.25f, 0.32f, 0.20f, 0.28f)
        val y = metrics.heightPixels * heights[swipeTry % heights.size]
        swipeTry++

        Log.i(TILE_TAG, "Next tile page: swipe at y=${y.toInt()}")

        gesture(
            metrics.widthPixels * 0.88f,
            y,
            metrics.widthPixels * 0.12f,
            y,
            160
        )
    }

    // A real on/off switch (not a Quick Settings tile, which is a plain
    // Button). Samsung's Wi-Fi dialog has a switch whose only text is "On"/"Off",
    // so we can't search for the word "wifi" there.
    private fun findDialogSwitch(labels: List<String>): AccessibilityNodeInfo? {
        val switches = ArrayList<AccessibilityNodeInfo>()

        for (root in systemRoots()) {
            val queue = ArrayDeque<AccessibilityNodeInfo>()
            queue.add(root)

            while (queue.isNotEmpty()) {
                val node = queue.removeFirst()

                val label = textOf(node).trim()

                val realSwitch = node.isCheckable &&
                    node.className?.toString() != "android.widget.Button"

                // Some dialogs show a switch that is only labelled "On"/"Off".
                val onOffLabel = label == "on" || label == "off"

                if ((realSwitch || onOffLabel) && node.isVisibleToUser) {
                    switches.add(node)
                }

                for (i in 0 until node.childCount) {
                    node.getChild(i)?.let { queue.add(it) }
                }
            }
        }

        Log.i(TILE_TAG, "Dialog switches found: ${switches.size}")

        for (sw in switches) {
            Log.i(
                TILE_TAG,
                "  switch class=${sw.className} text='${textOf(sw).trim()}' " +
                    "near='${nearbyText(sw).take(80)}' checked=${sw.isChecked} " +
                    "clickable=${sw.isClickable}"
            )
        }

        // 1) a switch that names the feature (Pixel: "Wi-Fi").
        switches.firstOrNull { sw ->
            val t = textOf(sw)
            labels.any { t.contains(it) }
        }?.let { return it }

        // 2) a switch sitting in the same row/card as the feature's name.
        switches.firstOrNull { sw ->
            val t = nearbyText(sw)
            labels.any { t.contains(it) }
        }?.let { return it }

        // 3) Samsung: the only switch in the dialog is the Wi-Fi one.
        val wifiFeature = labels.any { it.contains("wi") }
        return if (wifiFeature && switches.size == 1) switches[0] else null
    }

    // Text of the views around a node (its row / card), to tell which
    // feature a switch belongs to.
    private fun nearbyText(node: AccessibilityNodeInfo): String {
        var parent: AccessibilityNodeInfo? = node.parent
        var levels = 0

        while (parent != null && levels < 2) {
            parent = parent.parent ?: break
            levels++
        }

        val start = parent ?: return ""
        val sb = StringBuilder()
        val queue = ArrayDeque<AccessibilityNodeInfo>()
        queue.add(start)
        var seen = 0

        while (queue.isNotEmpty() && seen < 30) {
            val n = queue.removeFirst()
            seen++
            sb.append(textOf(n)).append(' ')

            for (i in 0 until n.childCount) {
                n.getChild(i)?.let { queue.add(it) }
            }
        }

        return sb.toString()
    }

    private fun clickNode(node: AccessibilityNodeInfo): Boolean {
        var cur: AccessibilityNodeInfo? = node
        while (cur != null && !cur.isClickable) cur = cur.parent

        return (cur ?: node).performAction(AccessibilityNodeInfo.ACTION_CLICK) ||
            tap(node)
    }

    // Pulls the Quick Settings panel down with two swipes from the top edge,
    // like a finger does. Works on the lock screen, where the global
    // "open Quick Settings" action can end up on the PIN screen.
    private fun swipeDownPanel(): Boolean {

    val metrics = resources.displayMetrics
    val x = metrics.widthPixels / 2f

    Log.i(TILE_TAG, "Opening Quick Settings with lock-screen swipe")

    return gesture(
        x,
        5f,
        x,
        metrics.heightPixels * 0.75f,
        350
    )
}

    // True when the lock screen's PIN / password / pattern entry is showing.
    private fun pinScreenShown(): Boolean {
        return findByText {
            it.contains("enter pin") ||
                it.contains("pin edit box") ||
                it.contains("enter your password") ||
                it.contains("draw your pattern")
        } != null
    }

    /**
     * Opens Quick Settings, finds the tile, taps it (only if needed), checks
     * that it really changed, then closes the panel.
     * desired: true = ON, false = OFF, null = just tap it.
     */
    fun toggleQuickSettingTile(
        labels: List<String>,
        desired: Boolean?,
        dialogLabels: List<String> = emptyList(),
        tapIcon: Boolean = false,
        choices: List<String> = emptyList(),
        openBySwipe: Boolean = true,
        onResult: (TileResult) -> Unit
    ) {
        // On the lock screen, pull the panel down the way a finger does.
        // Otherwise use Android's own "open Quick Settings" action.
        val opened = if (openBySwipe) {
            swipeDownPanel()
        } else {
            performGlobalAction(GLOBAL_ACTION_QUICK_SETTINGS)
        }

        if (!opened) {
            Log.w(TILE_TAG, "Could not open Quick Settings")
            onResult(TileResult.NOT_FOUND)
            return
        }

        var attempts = 0
        swipeTry = 0
        choiceLabels = choices

        val poll = object : Runnable {
            override fun run() {
                val tile = findClickable(labels)

                if (tile == null) {
                    attempts++

                    // The lock screen is asking for the PIN: the panel is not
                    // reachable. Stop early; the caller can ask the user to unlock.
                    if (openBySwipe && attempts >= 2 && pinScreenShown()) {
                        Log.i(TILE_TAG, "Lock screen is asking for the PIN")
                        closePanel()
                        onResult(TileResult.NOT_FOUND)
                        return
                    }

                    // Lock screen: the panel sometimes does not open on the
                    // first swipe. If it still is not there, pull it down again.
                    if (openBySwipe && (attempts == 4 || attempts == 9)) {
                        Log.i(TILE_TAG, "Panel not open yet, pulling it down again")
                        swipeDownPanel()
                    }

                    // Not on the first page? Look at the next pages.
                    if (attempts == 3 || attempts == 6 || attempts == 9 || attempts == 12) {
                        showNextTilePage()
                    }

                    if (attempts < 16) {
                        uiHandler.postDelayed(this, 300)
                    } else {
                        logPanelLabels("Tile $labels not found")
                        closePanel()
                        onResult(TileResult.NOT_FOUND)
                    }
                    return
                }

                val before = stateOf(tile)

                Log.i(
                    TILE_TAG,
                    "Found tile for $labels: state=$before text='${textOf(tile)}'"
                )

                // Pixel's merged "Internet" tile shows Wi-Fi AND mobile data,
                // so its state can't be trusted. Other tiles can.
                val mergedInternetTile = textOf(tile).contains("internet")

                if (!mergedInternetTile && desired != null && before == desired) {
                    closePanel()
                    onResult(TileResult.ALREADY)
                    return
                }

                // Wi-Fi etc.: tap the tile's icon, which toggles directly and
                // never opens the dialog. (Pixel's merged "Internet" tile has no
                // such icon, so it keeps using the dialog.)
                if (tapIcon && !mergedInternetTile) {
                    tapTileIcon(labels, desired, false, onResult)
                    return
                }

                val clicked = tile.performAction(AccessibilityNodeInfo.ACTION_CLICK) ||
                    tap(tile)

                Log.i(TILE_TAG, "Tapped tile for $labels: ok=$clicked")

                uiHandler.postDelayed({
                    afterTileTap(
                        labels, desired, dialogLabels, clicked, before, onResult
                    )
                }, if (dialogLabels.isNotEmpty()) 1000L else 700L)
            }
        }

        uiHandler.postDelayed(poll, 700)
    }


    private fun afterTileTap(
    labels: List<String>,
    desired: Boolean?,
    dialogLabels: List<String>,
    clicked: Boolean,
    before: Boolean?,
    onResult: (TileResult) -> Unit
) {

    if (!clicked) {
        closePanel()
        onResult(TileResult.FAILED)
        return
    }

    if (dialogLabels.isNotEmpty()) {

        val sw = findDialogSwitch(dialogLabels)

        if (sw != null) {
            useDialogSwitch(
                sw,
                dialogLabels,
                desired,
                onResult
            )
            return
        }

        Log.i(
            TILE_TAG,
            "Dialog switch not found for $labels"
        )

        tapTileIcon(
            labels,
            desired,
            true,
            onResult
        )

        return
    }

    uiHandler.postDelayed({

        val tile = findClickable(labels)
        val after = tile?.let { stateOf(it) }

        closePanel()

        val verified = when {
            desired != null && after != null ->
                after == desired

            desired == null && before != null && after != null ->
                before != after

            else -> false
        }

        if (verified) {
            onResult(TileResult.CHANGED)
        } else {
            Log.w(
                TILE_TAG,
                "Tile action could not be verified. " +
                    "before=$before after=$after desired=$desired"
            )

            onResult(TileResult.FAILED)
        }

    }, 1000)
}

    // First visible node whose text satisfies the test (or its clickable parent).
    private fun findByText(test: (String) -> Boolean): AccessibilityNodeInfo? {
        for (root in systemRoots()) {
            val queue = ArrayDeque<AccessibilityNodeInfo>()
            queue.add(root)

            while (queue.isNotEmpty()) {
                val node = queue.removeFirst()

                if (node.isVisibleToUser && test(textOf(node).trim())) {
                    var cur: AccessibilityNodeInfo? = node
                    while (cur != null && !cur.isClickable) cur = cur.parent
                    return cur ?: node
                }

                for (i in 0 until node.childCount) {
                    node.getChild(i)?.let { queue.add(it) }
                }
            }
        }

        return null
    }

    // The tile opened a dialog with several options. Pick the wanted one
    // ("Until I turn it off"), press its confirm button if there is one, then
    // check the tile. Returns false if no such dialog is on screen.
    private fun answerChoiceDialog(
        labels: List<String>,
        before: Boolean?,
        desired: Boolean?,
        onResult: (TileResult) -> Unit
    ): Boolean {
        val choice = findByText { t ->
            choiceLabels.any { t.contains(it) } ||
                (t.contains("until") && t.contains("off") && !t.contains("alarm"))
        }

        if (choice == null) {
            logPanelLabels("No choice option for $choiceLabels")
            return false
        }

        Log.i(TILE_TAG, "Choosing option: '${textOf(choice).trim()}'")
        clickNode(choice)

        uiHandler.postDelayed({
            // Some phones need a confirm button after choosing.
            val confirm = findByText { t ->
                t == "turn on" || t == "turn on now" || t == "done" ||
                    t == "ok" || t == "start" || t == "start now"
            }

            if (confirm != null) {
                Log.i(TILE_TAG, "Confirming: '${textOf(confirm).trim()}'")
                clickNode(confirm)
            }

            uiHandler.postDelayed({
                val after = findClickable(labels)?.let { stateOf(it) }

                closePanel()

                val ok = when {
    after == null -> false

    desired != null ->
        after == desired

    before != null ->
        after != before

    else -> false
}

onResult(
    if (ok) TileResult.CHANGED
    else TileResult.FAILED
)
            }, 900)
        }, 500)

        return true
    }

    // Closes any dialog, then taps the left part of the tile (its icon).
    private fun tapTileIcon(
        labels: List<String>,
        desired: Boolean?,
        closeDialogFirst: Boolean,
        onResult: (TileResult) -> Unit
    ) {
        if (closeDialogFirst) performGlobalAction(GLOBAL_ACTION_BACK)

        uiHandler.postDelayed({
            val tile = findClickable(labels)

            if (tile == null) {
                logPanelLabels("Tile $labels lost after closing dialog")
                closePanel()
                onResult(TileResult.FAILED)
                return@postDelayed
            }

            val before = stateOf(tile)

            if (desired != null && before == desired) {
                closePanel()
                onResult(TileResult.ALREADY)
                return@postDelayed
            }

            val b = Rect()
            tile.getBoundsInScreen(b)

            // Wide tile (icon + label): tap the icon on the left.
            // Round icon-only tile: tap its centre.
            val x = if (b.width() > b.height() * 1.5f) {
                b.left + b.height() * 0.5f
            } else {
                b.exactCenterX()
            }

            val tapped = gesture(x, b.exactCenterY(), x, b.exactCenterY(), 60)

            Log.i(TILE_TAG, "Tapped tile icon at ${b.toShortString()}: $tapped")

            uiHandler.postDelayed({
                // A choice dialog (Do Not Disturb: "Until I turn it off")?
                if (tapped && desired != false && choiceLabels.isNotEmpty() &&
                    answerChoiceDialog(labels, before, desired, onResult)
                ) {
                    return@postDelayed
                }

                val after = findClickable(labels)?.let { stateOf(it) }

                // If this opened the dialog again, close it.
                if (findDialogSwitch(labels) != null) {
                    performGlobalAction(GLOBAL_ACTION_BACK)
                }

                closePanel()

val ok = tapped && when {
    desired != null && after != null ->
        after == desired

    desired == null && before != null && after != null ->
        before != after

    else -> false
}

                onResult(if (ok) TileResult.CHANGED else TileResult.FAILED)
            }, 1200)
        }, if (closeDialogFirst) 600L else 0L)
    }

    private fun useDialogSwitch(
        sw: AccessibilityNodeInfo,
        dialogLabels: List<String>,
        desired: Boolean?,
        onResult: (TileResult) -> Unit
    ) {
        val current = stateOf(sw)

        Log.i(TILE_TAG, "Dialog switch state=$current, wanted=$desired")

        if (desired != null && current == desired) {
            performGlobalAction(GLOBAL_ACTION_BACK)
            closePanel()
            onResult(TileResult.ALREADY)
            return
        }

        val clicked = clickNode(sw)

        Log.i(TILE_TAG, "Dialog switch clicked: $clicked")

        uiHandler.postDelayed({
            val updated = findDialogSwitch(dialogLabels)?.let { stateOf(it) }

            performGlobalAction(GLOBAL_ACTION_BACK)
            closePanel()

           val verified = when {
    !clicked -> false

    desired != null ->
        updated != null && updated == desired

    current != null && updated != null ->
        current != updated

    else -> false
}

onResult(
    if (verified) TileResult.CHANGED
    else TileResult.FAILED
)
        }, 1200)
    }

    // Taps the on/off switch of whatever Settings page is on screen
    // (used for the Airplane mode page, which needs no Quick Settings tile).
    fun toggleSwitchOnScreen(
        labels: List<String>,
        desired: Boolean?,
        onResult: (TileResult) -> Unit
    ) {
        var attempts = 0

        val finder = object : Runnable {
            override fun run() {
                val sw = findPageSwitch(labels)

                if (sw == null) {
                    attempts++

                    if (attempts < 8) {
                        uiHandler.postDelayed(this, 500)
                    } else {
                        Log.i(TILE_TAG, "No switch found on the page")
                        onResult(TileResult.NOT_FOUND)
                    }
                    return
                }

                val current = stateOf(sw)
                Log.i(TILE_TAG, "Page switch state=$current, wanted=$desired")

                if (desired != null && current == desired) {
                    onResult(TileResult.ALREADY)
                    return
                }

                val clicked = clickNode(sw)
                Log.i(TILE_TAG, "Page switch clicked: $clicked")

                uiHandler.postDelayed({

    val updatedSwitch = findPageSwitch(labels)
    val updated = updatedSwitch?.let { stateOf(it) }

    val verified = when {
        !clicked -> false

        desired != null ->
            updated != null && updated == desired

        current != null && updated != null ->
            current != updated

        else -> false
    }

    onResult(
        if (verified) TileResult.CHANGED
        else TileResult.FAILED
    )

}, 1000)
            }
        }

        uiHandler.postDelayed(finder, 800)
    }

    // The main switch on a Settings page: prefer one that names the feature,
    // otherwise the top-most visible switch.
    private fun findPageSwitch(labels: List<String>): AccessibilityNodeInfo? {
        val switches = ArrayList<AccessibilityNodeInfo>()

        for (root in systemRoots()) {
            val queue = ArrayDeque<AccessibilityNodeInfo>()
            queue.add(root)

            while (queue.isNotEmpty()) {
                val node = queue.removeFirst()
                val label = textOf(node).trim()

                val realSwitch = node.isCheckable &&
                    node.className?.toString() != "android.widget.Button"

                if ((realSwitch || label == "on" || label == "off") &&
                    node.isVisibleToUser
                ) {
                    switches.add(node)
                }

                for (i in 0 until node.childCount) {
                    node.getChild(i)?.let { queue.add(it) }
                }
            }
        }

        Log.i(TILE_TAG, "Page switches found: ${switches.size}")

        for (sw in switches) {
            Log.i(
                TILE_TAG,
                "  switch class=${sw.className} text='${textOf(sw).trim()}' " +
                    "near='${nearbyText(sw).take(80)}' checked=${sw.isChecked}"
            )
        }

        switches.firstOrNull { sw ->
            val t = textOf(sw) + " " + nearbyText(sw)
            labels.any { t.contains(it) }
        }?.let { return it }

        return switches.minByOrNull {
            val r = Rect()
            it.getBoundsInScreen(r)
            r.top
        }
    }

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }
}