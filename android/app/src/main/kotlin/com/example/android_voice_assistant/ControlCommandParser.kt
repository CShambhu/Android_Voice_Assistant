package com.example.android_voice_assistant

import android.content.Context
import com.example.android_voice_assistant.DeviceControl.Feature

object ControlCommandParser {

    // More specific phrases first. Matching is whole-word, so "broadcast" won't match "cast".
    private val keywords: List<Pair<Feature, List<String>>> = listOf(
        Feature.FLASHLIGHT to listOf("flashlight", "flash light", "torch"),
        Feature.SCREENSHOT to listOf("screenshot", "screen shot"),
        Feature.SCREEN_RECORD to listOf(
            "screen record", "screen recording", "screen recorder", "record screen"
        ),
        Feature.QUICK_SHARE to listOf("quick share", "nearby share"),
        Feature.QR_SCANNER to listOf("qr", "qr code", "qr scanner"),
        Feature.WIFI to listOf("wifi", "wi fi"),
        Feature.BLUETOOTH to listOf("bluetooth"),
        Feature.LOCATION to listOf("location", "gps"),
        Feature.AUTO_ROTATE to listOf(
            "auto rotate", "autorotate", "rotation", "screen rotation"
        ),
        Feature.AIRPLANE to listOf(
            "airplane mode", "flight mode", "aeroplane mode", "airplane"
        ),
        Feature.HOTSPOT to listOf("hotspot", "hot spot"),
        Feature.MOBILE_DATA to listOf("mobile data", "cellular data"),
        Feature.BATTERY_SAVER to listOf("battery saver", "power saving", "power saver"),
        Feature.DND to listOf("do not disturb", "dnd"),
        Feature.NFC to listOf("nfc"),
        Feature.DARK_MODE to listOf("dark mode", "dark theme"),
        Feature.CAST to listOf("screen cast", "screencast", "cast"),
        Feature.DATA_SAVER to listOf("data saver", "data saving")
    )

    // These just fire an action; no on/off word needed.
    private val triggers = setOf(
        Feature.SCREENSHOT,
        Feature.SCREEN_RECORD,
        Feature.QR_SCANNER,
        Feature.QUICK_SHARE,
        Feature.CAST
    )

    private val onWords = setOf("on", "enable", "enabled", "activate", "start")
    private val offWords = setOf("off", "disable", "disabled", "deactivate", "stop")

    /** @return true if the text was a device-control command (report() will be called). */
    fun handle(ctx: Context, spoken: String, report: (String) -> Unit): Boolean {
        val text = " " + spoken.lowercase()
            .replace(Regex("[^a-z0-9\\u0900-\\u097F]+"), " ").trim() + " "

        val feature = keywords.firstOrNull { (_, list) ->
            list.any { text.contains(" $it ") }
        }?.first ?: return false

        val words = text.trim().split(" ").toSet()

        val desired: Boolean? = when {
            words.any { it in offWords } -> false
            words.any { it in onWords } -> true
            else -> null
        }

        val isTrigger = feature in triggers
        val hasVerb = desired != null || "toggle" in words || "switch" in words
        if (!isTrigger && !hasVerb) return false

        // The phone must support it, and the user must have ticked it.
        if (!DeviceFeatures.isSupported(ctx, feature)) {
            report("This phone has no ${feature.display}")
            return true
        }

        if (feature !in DeviceFeatures.loadAllowed(ctx)) {
            report(
                "${feature.display} is not in your selected phone controls, " +
                    "so Hello Boss won't change it."
            )
            return true
        }

        DeviceControl.execute(ctx, feature, if (isTrigger) null else desired, report)
        return true
    }
}