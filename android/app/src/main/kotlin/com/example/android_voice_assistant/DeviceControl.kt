package com.example.android_voice_assistant

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings

enum class TileResult { CHANGED, ALREADY, NOT_FOUND }

object DeviceControl {

    enum class Feature(
        val display: String,
        val tileLabels: List<String> = emptyList(),
        val dialogLabels: List<String> = emptyList(),
        val fallbackAction: String? = null
    ) {
        FLASHLIGHT("Flashlight"),
        SCREENSHOT("Screenshot"),
        WIFI(
            "Wi-Fi",
            listOf("wi-fi", "wifi", "internet"),
            listOf("wi-fi", "wifi"),
            "android.settings.panel.action.WIFI"
        ),
        BLUETOOTH(
            "Bluetooth",
            listOf("bluetooth"),
            fallbackAction = Settings.ACTION_BLUETOOTH_SETTINGS
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
            fallbackAction = Settings.ACTION_AIRPLANE_MODE_SETTINGS
        ),
        HOTSPOT(
            "Hotspot",
            listOf("hotspot"),
            fallbackAction = Settings.ACTION_WIRELESS_SETTINGS
        ),
        MOBILE_DATA(
            "Mobile data",
            listOf("mobile data", "internet"),
            listOf("mobile data"),
            "android.settings.panel.action.INTERNET_CONNECTIVITY"
        ),
        QR_SCANNER("QR scanner", listOf("scan qr", "qr code", "qr scanner")),
        BATTERY_SAVER(
            "Battery saver",
            listOf("battery saver", "power saving"),
            fallbackAction = Settings.ACTION_BATTERY_SAVER_SETTINGS
        ),
        DND(
            "Do Not Disturb",
            listOf("do not disturb", "dnd"),
            fallbackAction = "android.settings.ZEN_MODE_SETTINGS"
        ),
        SCREEN_RECORD("Screen recorder", listOf("screen record")),
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
        QUICK_SHARE("Quick Share", listOf("quick share", "nearby share")),
        DATA_SAVER(
            "Data saver",
            listOf("data saver", "data saving"),
            fallbackAction = "android.settings.DATA_USAGE_SETTINGS"
        )
    }

    /**
     * desired: true = turn on, false = turn off, null = toggle / just trigger.
     * report() is called once with a short message for the user.
     */
    fun execute(
        ctx: Context,
        feature: Feature,
        desired: Boolean?,
        report: (String) -> Unit
    ) {
        when (feature) {
            Feature.FLASHLIGHT -> report(flashlight(ctx, desired))

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

            Feature.AUTO_ROTATE ->
                if (Settings.System.canWrite(ctx)) {
                    report(autoRotate(ctx, desired))
                } else {
                    tile(ctx, feature, desired, report)
                }

            Feature.DND -> {
                val nm = ctx.getSystemService(NotificationManager::class.java)
                if (nm.isNotificationPolicyAccessGranted) {
                    report(doNotDisturb(nm, desired))
                } else {
                    tile(ctx, feature, desired, report)
                }
            }

            else -> tile(ctx, feature, desired, report)
        }
    }

    // ---------- Direct APIs ----------

    private var torchOn = false
    private var torchRegistered = false

    private fun flashlight(ctx: Context, desired: Boolean?): String {
        val cm = ctx.getSystemService(Context.CAMERA_SERVICE) as CameraManager

        val id = cm.cameraIdList.firstOrNull {
            val c = cm.getCameraCharacteristics(it)
            c.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true &&
                c.get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        } ?: return "This phone has no flashlight"

        if (!torchRegistered) {
            cm.registerTorchCallback(
                object : CameraManager.TorchCallback() {
                    override fun onTorchModeChanged(cameraId: String, enabled: Boolean) {
                        if (cameraId == id) torchOn = enabled
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

    private fun doNotDisturb(nm: NotificationManager, desired: Boolean?): String {
        val current =
            nm.currentInterruptionFilter != NotificationManager.INTERRUPTION_FILTER_ALL
        val target = desired ?: !current

        nm.setInterruptionFilter(
            if (target) NotificationManager.INTERRUPTION_FILTER_PRIORITY
            else NotificationManager.INTERRUPTION_FILTER_ALL
        )

        return if (target) "Do Not Disturb on" else "Do Not Disturb off"
    }

    // ---------- Quick Settings tile (via Accessibility) ----------

    private fun tile(
        ctx: Context,
        feature: Feature,
        desired: Boolean?,
        report: (String) -> Unit
    ) {
        val service = VoiceAccessibilityService.instance

        if (service == null) {
            report("Turn on Accessibility first")
            return
        }

        val word = when (desired) {
            true -> "on"
            false -> "off"
            null -> "toggled"
        }

        service.toggleQuickSettingTile(
            feature.tileLabels,
            desired,
            feature.dialogLabels
        ) { result ->
            when (result) {
                TileResult.CHANGED -> report("${feature.display} $word")
                TileResult.ALREADY -> report("${feature.display} is already $word")
                TileResult.NOT_FOUND -> {
                    openFallback(ctx, feature)
                    report(
                        "Could not find the ${feature.display} tile. " +
                            "Opened settings instead."
                    )
                }
            }
        }
    }

    private fun openFallback(ctx: Context, feature: Feature) {
        val action = feature.fallbackAction ?: return

        try {
            ctx.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            // Some phones don't have that settings screen.
        }
    }
}