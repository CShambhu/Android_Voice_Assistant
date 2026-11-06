package com.example.android_voice_assistant

import android.app.KeyguardManager
import android.app.NotificationManager
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.location.LocationManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

object DeviceControl {

    private const val TAG = "WifiDebug"

    enum class Feature(
        val display: String,
        val tileLabels: List<String> = emptyList(),
        val dialogLabels: List<String> = emptyList(),
        val fallbackAction: String? = null,
        val tapIcon: Boolean = false,
        val choices: List<String> = emptyList()
    ) {
        FLASHLIGHT("Flashlight"),

        SCREENSHOT("Screenshot"),

        WIFI(
            "Wi-Fi",
            listOf("wi-fi", "wifi", "internet"),
            listOf("wi-fi", "wifi"),
            "android.settings.panel.action.WIFI",
            tapIcon = true
        ),

        BLUETOOTH(
            "Bluetooth",
            listOf("bluetooth"),
            fallbackAction = Settings.ACTION_BLUETOOTH_SETTINGS,
            tapIcon = true
        ),

        LOCATION(
            "Location",
            listOf("location"),
            fallbackAction = Settings.ACTION_LOCATION_SOURCE_SETTINGS
        ),

        AUTO_ROTATE(
            "Auto-rotate",
            listOf("auto-rotate", "auto rotate", "rotation", "portrait"),
            fallbackAction = Settings.ACTION_DISPLAY_SETTINGS
        ),

        AIRPLANE(
            "Airplane mode",
            listOf("airplane", "flight mode", "aeroplane"),
            fallbackAction = Settings.ACTION_AIRPLANE_MODE_SETTINGS,
            tapIcon = true
        ),

        HOTSPOT(
            "Hotspot",
            listOf("hotspot"),
            fallbackAction = Settings.ACTION_WIRELESS_SETTINGS,
            tapIcon = true
        ),

        MOBILE_DATA(
            "Mobile data",
            listOf("mobile data", "internet"),
            listOf("mobile data"),
            "android.settings.panel.action.INTERNET_CONNECTIVITY"
        ),

        QR_SCANNER(
            "QR scanner",
            listOf("scan qr", "qr code", "qr scanner")
        ),

        BATTERY_SAVER(
            "Battery saver",
            listOf("battery saver", "power saving"),
            fallbackAction = Settings.ACTION_BATTERY_SAVER_SETTINGS
        ),

        DND(
            "Do Not Disturb",
            listOf("do not disturb", "dnd"),
            fallbackAction = "android.settings.ZEN_MODE_SETTINGS",
            tapIcon = true,
            // The dialog that appears: pick "Until I turn it off".
            choices = listOf(
                "until i turn it off",
                "until you turn it off",
                "until you turn this off",
                "until turned off"
            )
        ),

        SCREEN_RECORD(
            "Screen recorder",
            listOf("screen record")
        ),

        NFC(
            "NFC",
            listOf("nfc"),
            fallbackAction = "android.settings.panel.action.NFC"
        ),

        DARK_MODE(
            "Dark mode",
            listOf("dark theme", "dark mode"),
            fallbackAction = Settings.ACTION_DISPLAY_SETTINGS
        ),

        CAST(
            "Cast",
            listOf("screen cast", "cast", "smart view"),
            fallbackAction = Settings.ACTION_CAST_SETTINGS
        ),

        QUICK_SHARE(
            "Quick Share",
            listOf("quick share", "nearby share")
        ),

        DATA_SAVER(
            "Data saver",
            listOf("data saver", "data saving"),
            fallbackAction = "android.settings.DATA_USAGE_SETTINGS"
        )
    }

    private var torchOn = false
    private var torchRegistered = false

    
fun execute(
    ctx: Context,
    feature: Feature,
    desired: Boolean?,
    report: (String) -> Unit
) {
    Log.e(TAG, "EXECUTE: feature=${feature.display}, desired=$desired")

    val keyguard =
        ctx.getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    // Handle controls while the phone is locked.
    if (keyguard.isKeyguardLocked && needsScreen(ctx, feature)) {

        when (feature) {

            Feature.WIFI -> {
                lockedControl(ctx, feature, desired, report)
            }

            Feature.AIRPLANE -> {
                Log.i(TAG, "Locked-screen Airplane mode control")

                withScreenOn(ctx, true) {
                    airplaneMode(ctx, desired, report)
                }
            }

            else -> {
                Log.i(
                    TAG,
                    "Attempting locked-screen Quick Settings: ${feature.display}"
                )

                withScreenOn(ctx, true) {
                    tile(ctx, feature, desired, report)
                }
            }
        }

        return
    }

    // Normal operation when the phone is unlocked.
    withScreenOn(ctx, needsScreen(ctx, feature)) {

        when (feature) {

            Feature.FLASHLIGHT -> {
                report(flashlight(ctx, desired))
            }

            Feature.SCREENSHOT -> {
                val service = VoiceAccessibilityService.instance

                if (service == null) {
                    report("Turn on Accessibility first")
                } else if (service.captureScreenshot()) {
                    report("Screenshot taken")
                } else {
                    report("Could not take a screenshot")
                }
            }

            Feature.LOCATION,
            Feature.BLUETOOTH -> {
                tile(ctx, feature, desired, report)
            }

            Feature.DND -> {
                val nm =
                    ctx.getSystemService(NotificationManager::class.java)

                if (nm.isNotificationPolicyAccessGranted) {
                    try {
                        report(doNotDisturb(nm, desired))
                    } catch (e: Exception) {
                        report("Could not change Do Not Disturb: ${e.message}")
                    }
                } else {
                    tile(ctx, feature, desired, report)
                }
            }

            Feature.AUTO_ROTATE -> {
                if (Settings.System.canWrite(ctx)) {
                    try {
                        report(autoRotate(ctx, desired))
                    } catch (e: Exception) {
                        report("Could not change auto-rotate: ${e.message}")
                    }
                } else {
                    tile(ctx, feature, desired, report)
                }
            }

            Feature.AIRPLANE -> {
                airplaneMode(ctx, desired, report)
            }

            else -> {
                tile(ctx, feature, desired, report)
            }
        }
    }
}


    private fun realState(
    ctx: Context,
    feature: Feature
): Boolean? = try {

    when (feature) {

        Feature.WIFI -> {
            val wifi = ctx.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager

            wifi.isWifiEnabled
        }

        Feature.BLUETOOTH -> {
            val manager = ctx.getSystemService(
                Context.BLUETOOTH_SERVICE
            ) as BluetoothManager

            manager.adapter?.isEnabled
        }

        Feature.LOCATION -> {
            val manager = ctx.getSystemService(
                Context.LOCATION_SERVICE
            ) as LocationManager

            manager.isLocationEnabled
        }

        Feature.AIRPLANE -> {
            isAirplaneOn(ctx)
        }

        Feature.AUTO_ROTATE -> {
            Settings.System.getInt(
                ctx.contentResolver,
                Settings.System.ACCELEROMETER_ROTATION,
                0
            ) == 1
        }

        Feature.MOBILE_DATA -> {
            null
        }

        else -> null
    }

} catch (e: Exception) {
    Log.e(TAG, "Could not read ${feature.display} state", e)
    null
}

private fun verifyState(
    ctx: Context,
    feature: Feature,
    target: Boolean
): Boolean {
    return when (feature) {
        Feature.WIFI,
        Feature.BLUETOOTH,
        Feature.LOCATION,
        Feature.AIRPLANE,
        Feature.AUTO_ROTATE -> realState(ctx, feature) == target

        else -> false
    }
}




    // Locked phone. Samsung (and most phones) ignore Quick Settings taps
    // while locked, so the only way that works is: if the setting is already
    // as requested, say so; otherwise ask the USER to unlock with Android's own
    // prompt, and run the command right after. Hello Boss never sees the PIN.
    private fun lockedControl(
        ctx: Context,
        feature: Feature,
        desired: Boolean?,
        report: (String) -> Unit
    ) {
        val before = realState(ctx, feature)

        if (before != null && desired != null && before == desired) {
            report("${feature.display} is already ${if (desired) "on" else "off"}")
            return
        }

        requestUnlock(ctx, feature, desired, report)
    }

    private fun requestUnlock(
        ctx: Context,
        feature: Feature,
        desired: Boolean?,
        report: (String) -> Unit
    ) {
        val word = when (desired) {
            true -> "on"
            false -> "off"
            null -> "toggled"
        }

        try {
            ctx.startActivity(
                Intent(ctx, UnlockActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    .putExtra(UnlockActivity.EXTRA_FEATURE, feature.name)
                    .putExtra(UnlockActivity.EXTRA_DESIRED, desired?.toString() ?: "")
            )

            report("Unlock your phone to turn ${feature.display} $word")
        } catch (e: Exception) {
            Log.e(TAG, "Could not show the unlock prompt", e)
            report("${feature.display} needs the phone unlocked first")
        }
    }

    // Quick Settings tiles need a lit screen. Direct APIs (torch, DND with
    // access, auto-rotate with permission) work with the screen off.
    private fun needsScreen(ctx: Context, feature: Feature): Boolean =
        when (feature) {
            Feature.FLASHLIGHT -> false
            Feature.DND ->
                !ctx.getSystemService(NotificationManager::class.java)
                    .isNotificationPolicyAccessGranted
            Feature.AUTO_ROTATE -> !Settings.System.canWrite(ctx)
            else -> true
        }

    // Wakes the screen if it is off, then runs the action.
    // This does NOT unlock a PIN/pattern/fingerprint lock.
    @Suppress("DEPRECATION")
private fun withScreenOn(
    ctx: Context,
    needed: Boolean,
    action: () -> Unit
) {
    val pm = ctx.getSystemService(
        Context.POWER_SERVICE
    ) as PowerManager

    if (!needed || pm.isInteractive) {
        action()
        return
    }

    try {
        val wakeLock = pm.newWakeLock(
            PowerManager.SCREEN_BRIGHT_WAKE_LOCK,
            "HelloBoss:WakeScreen"
        )

        wakeLock.acquire(5_000)

        Handler(Looper.getMainLooper()).postDelayed({
            try {
                if (wakeLock.isHeld) {
                    wakeLock.release()
                }
            } catch (_: Exception) {
            }

            action()
        }, 1000)

    } catch (e: Exception) {
        Log.e(TAG, "Could not wake screen", e)
        action()
    }
}

    // ----------------------------------------
    // AIRPLANE MODE
    // ----------------------------------------
    //
    // Why there is no direct toggle:
    //  - Writing Settings.Global.AIRPLANE_MODE_ON needs WRITE_SECURE_SETTINGS,
    //    which only system apps (or an ADB grant) can hold.
    //  - Even with it, the radios only react through the system's own
    //    connectivity service (needs NETWORK_AIRPLANE_MODE, a system-only
    //    permission); the old AIRPLANE_MODE broadcast is protected.
    //  - A Device Owner can only block the setting
    //    (UserManager.DISALLOW_AIRPLANE_MODE), not change it.
    // So: tap the Flight mode tile through Accessibility if the tile exists
    // (no dialog), else open Android's own Airplane mode page. Either way the
    // REAL resulting state is what gets reported.

    private fun isAirplaneOn(ctx: Context): Boolean =
        Settings.Global.getInt(
            ctx.contentResolver,
            Settings.Global.AIRPLANE_MODE_ON,
            0
        ) == 1

    private fun airplaneMode(
        ctx: Context,
        desired: Boolean?,
        report: (String) -> Unit
    ) {
        val now = isAirplaneOn(ctx)
        val target = desired ?: !now
        val word = if (target) "on" else "off"

        if (now == target) {
            report("Airplane mode is already $word")
            return
        }

        val tileService = VoiceAccessibilityService.instance

        // Best way, no page at all: tap the Flight mode tile in Quick Settings.
        if (tileService != null) {
            tileService.toggleQuickSettingTile(
                labels = Feature.AIRPLANE.tileLabels,
                desired = target,
                dialogLabels = Feature.AIRPLANE.dialogLabels,
                tapIcon = Feature.AIRPLANE.tapIcon,
                choices = Feature.AIRPLANE.choices
            ) { result ->
                if (result == TileResult.NOT_FOUND) {
                    airplaneViaPage(ctx, target, report)
                } else {
                    Handler(Looper.getMainLooper()).postDelayed({
                        val actual = isAirplaneOn(ctx)
                        report(
                            if (actual == target) "Airplane mode $word"
                            else "Tried to turn Airplane mode $word, but it is " +
                                "still ${if (actual) "on" else "off"}."
                        )
                    }, 1000)
                }
            }
            return
        }

        airplaneViaPage(ctx, target, report)
    }

    // Fallback when there is no Flight mode tile: Airplane mode page.
    private fun airplaneViaPage(
        ctx: Context,
        target: Boolean,
        report: (String) -> Unit
    ) {
        val word = if (target) "on" else "off"

        // Open Android's own Airplane mode page.
        try {
            ctx.startActivity(
                Intent(Settings.ACTION_AIRPLANE_MODE_SETTINGS)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        } catch (e: Exception) {
            Log.e(TAG, "Could not open Airplane mode settings", e)
            report("Airplane mode settings could not be opened.")
            return
        }

        val service = VoiceAccessibilityService.instance

        if (service == null) {
            watchAirplaneMode(ctx, target)
            report(
                "Turn on Hello Boss in Accessibility for one-step switching. " +
                    "For now, tap the switch to turn Airplane mode $word."
            )
            return
        }

        // Tap the switch on that page for the user, then leave the page.
        service.toggleSwitchOnScreen(
            labels = listOf("airplane", "flight", "aeroplane"),
            desired = target
        ) { _ ->
            Handler(Looper.getMainLooper()).postDelayed({
                val actual = isAirplaneOn(ctx)

                if (actual == target) {
                    service.goBack()
                    report("Airplane mode $word")
                } else {
                    watchAirplaneMode(ctx, target)
                    report(
                        "I could not tap the switch. Tap it yourself to " +
                            "turn Airplane mode $word."
                    )
                }
            }, 1200)
        }
    }

    // Waits (up to 60 s) for the real setting to change, then says so.
    private fun watchAirplaneMode(ctx: Context, target: Boolean) {
        val appCtx = ctx.applicationContext
        val handler = Handler(Looper.getMainLooper())
        var done = false

        lateinit var observer: ContentObserver

        fun stop() {
            if (done) return
            done = true
            try {
                appCtx.contentResolver.unregisterContentObserver(observer)
            } catch (_: Exception) {
            }
        }

        observer = object : ContentObserver(handler) {
            override fun onChange(selfChange: Boolean) {
                val on = isAirplaneOn(appCtx)

                if (on == target) {
                    MainActivity.emitServiceEvent(
                        "status",
                        if (on) "Airplane mode is now ON"
                        else "Airplane mode is now OFF"
                    )
                    stop()
                }
            }
        }

        appCtx.contentResolver.registerContentObserver(
            Settings.Global.getUriFor(Settings.Global.AIRPLANE_MODE_ON),
            false,
            observer
        )

        handler.postDelayed({
            if (!done) {
                MainActivity.emitServiceEvent(
                    "status",
                    "Airplane mode did not change " +
                        "(still ${if (isAirplaneOn(appCtx)) "ON" else "OFF"})"
                )
                stop()
            }
        }, 60_000)
    }

    // ----------------------------------------
    // FLASHLIGHT
    // ----------------------------------------

    private fun flashlight(ctx: Context, desired: Boolean?): String {
        val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager

        val id = cm.cameraIdList.firstOrNull {
            val characteristics = cm.getCameraCharacteristics(it)

            characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true &&
                characteristics.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        } ?: return "This phone has no flashlight"

        if (!torchRegistered) {
            cm.registerTorchCallback(
                object : CameraManager.TorchCallback() {
                    override fun onTorchModeChanged(
                        cameraId: String,
                        enabled: Boolean
                    ) {
                        if (cameraId == id) {
                            torchOn = enabled
                        }
                    }
                },
                Handler(Looper.getMainLooper())
            )

            torchRegistered = true
        }

        val target = desired ?: !torchOn

        return try {
            cm.setTorchMode(id, target)
            torchOn = target

            if (target) "Flashlight on" else "Flashlight off"
        } catch (e: Exception) {
            "Could not use the flashlight: ${e.message}"
        }
    }

    // ----------------------------------------
    // AUTO ROTATE
    // ----------------------------------------

    private fun autoRotate(ctx: Context, desired: Boolean?): String {
        val cr = ctx.contentResolver

        val current =
            Settings.System.getInt(cr, Settings.System.ACCELEROMETER_ROTATION, 0) == 1

        val target = desired ?: !current

        Settings.System.putInt(
            cr,
            Settings.System.ACCELEROMETER_ROTATION,
            if (target) 1 else 0
        )

        return if (target) "Auto-rotate on" else "Auto-rotate off"
    }

    // ----------------------------------------
    // DO NOT DISTURB
    // ----------------------------------------

    private fun doNotDisturb(nm: NotificationManager, desired: Boolean?): String {
        val current =
            nm.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL

        val target = desired ?: !current

        if (current == target) {
            return if (target) {
                "Do Not Disturb is already ON"
            } else {
                "Do Not Disturb is already OFF"
            }
        }

        nm.setInterruptionFilter(
            if (target) {
                NotificationManager.INTERRUPTION_FILTER_PRIORITY
            } else {
                NotificationManager.INTERRUPTION_FILTER_ALL
            }
        )

        val actual =
            nm.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL

        return if (actual == target) {
            if (target) "Do Not Disturb turned ON" else "Do Not Disturb turned OFF"
        } else {
            "Android did not change Do Not Disturb"
        }
    }

    // ----------------------------------------
    // QUICK SETTINGS TILE CONTROL
    // ----------------------------------------

    private fun tile(
        ctx: Context,
        feature: Feature,
        desired: Boolean?,
        report: (String) -> Unit
    ) {
        Log.e(TAG, "TILE FUNCTION CALLED: feature=${feature.display}, desired=$desired")

        val service = VoiceAccessibilityService.instance

        if (service == null) {
            Log.e(TAG, "Accessibility service is NULL")
            report("Turn on Accessibility first")
            return
        }

        val word = when (desired) {
            true -> "on"
            false -> "off"
            null -> "toggled"
        }

        service.toggleQuickSettingTile(
            labels = feature.tileLabels,
            desired = desired,
            dialogLabels = feature.dialogLabels,
            tapIcon = feature.tapIcon,
            choices = feature.choices,
            openBySwipe = true
        ) { result ->

            Log.e(
                TAG,
                "TILE CALLBACK: feature=${feature.display}, result=$result"
            )

            when (result) {

                TileResult.CHANGED -> {
                    report("${feature.display} $word")
                }

                TileResult.ALREADY -> {
                    report("${feature.display} is already $word")
                }

                TileResult.NOT_FOUND -> {
                    openFallback(ctx, feature)

                    report(
                        "Could not find the ${feature.display} tile in Quick " +
                            "Settings. Check that the tile is added to your panel. " +
                            "Opened settings instead. Panel showed: " +
                            service.lastPanelDump.take(250)
                    )
                }

                TileResult.FAILED -> {
                    report(
                        "Tried to turn ${feature.display} $word, " +
                            "but could not verify the change. " +
                            "Your phone may require manual operation."
                    )
                }
            }
        }
    }

    // ----------------------------------------
    // FALLBACK SETTINGS
    // ----------------------------------------

    private fun openFallback(ctx: Context, feature: Feature) {
        val action = feature.fallbackAction ?: return

        try {
            Log.e(TAG, "Opening fallback settings: $action")

            ctx.startActivity(
                Intent(action).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "Could not open fallback settings", e)
        }
    }
}