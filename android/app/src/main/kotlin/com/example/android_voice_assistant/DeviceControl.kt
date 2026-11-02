package com.example.android_voice_assistant

import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Handler
import android.os.Looper
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

            // Direct system setting when access is granted (no dialog at all),
            // Quick Settings tile otherwise.
            Feature.DND -> {
                val nm = ctx.getSystemService(NotificationManager::class.java)

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

            else -> {
                tile(ctx, feature, desired, report)
            }
        }
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
            choices = feature.choices
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