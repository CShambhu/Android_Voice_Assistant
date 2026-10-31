package com.example.android_voice_assistant

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import com.example.android_voice_assistant.DeviceControl.Feature

/** Detects which phone controls exist on THIS device, and stores the user's choice. */
object DeviceFeatures {

    private const val PREFS = "hello_boss_features"
    private const val KEY_ALLOWED = "allowed_features"

    private fun hasPackage(ctx: Context, pkg: String): Boolean =
        try {
            ctx.packageManager.getPackageInfo(pkg, 0)
            true
        } catch (_: Exception) {
            false
        }

    fun isSupported(ctx: Context, f: Feature): Boolean {
        val pm = ctx.packageManager
        val wifi = pm.hasSystemFeature(PackageManager.FEATURE_WIFI)
        val telephony = pm.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)

        return when (f) {
            Feature.FLASHLIGHT -> pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_FLASH)
            Feature.SCREENSHOT -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.P
            Feature.WIFI -> wifi
            Feature.HOTSPOT -> wifi
            Feature.BLUETOOTH -> pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)
            Feature.LOCATION -> pm.hasSystemFeature(PackageManager.FEATURE_LOCATION)
            Feature.AUTO_ROTATE -> pm.hasSystemFeature(PackageManager.FEATURE_SENSOR_ACCELEROMETER)
            Feature.AIRPLANE -> telephony || wifi ||
                pm.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)
            Feature.MOBILE_DATA -> telephony
            Feature.QR_SCANNER -> pm.hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)
            Feature.BATTERY_SAVER -> true
            Feature.DND -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
            Feature.SCREEN_RECORD -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.R
            Feature.NFC -> pm.hasSystemFeature(PackageManager.FEATURE_NFC)
            Feature.DARK_MODE -> Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
            Feature.CAST -> wifi
            Feature.QUICK_SHARE ->
                hasPackage(ctx, "com.google.android.gms") ||
                    hasPackage(ctx, "com.samsung.android.app.sharelive")
            Feature.DATA_SAVER ->
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.N && (telephony || wifi)
        }
    }

    private fun example(f: Feature): String = when (f) {
        Feature.FLASHLIGHT -> "turn on flashlight"
        Feature.SCREENSHOT -> "take a screenshot"
        Feature.WIFI -> "turn off Wi-Fi"
        Feature.BLUETOOTH -> "turn on Bluetooth"
        Feature.LOCATION -> "turn on location"
        Feature.AUTO_ROTATE -> "turn off auto rotate"
        Feature.AIRPLANE -> "turn on airplane mode"
        Feature.HOTSPOT -> "turn on hotspot"
        Feature.MOBILE_DATA -> "turn off mobile data"
        Feature.QR_SCANNER -> "scan QR"
        Feature.BATTERY_SAVER -> "turn on battery saver"
        Feature.DND -> "turn on do not disturb"
        Feature.SCREEN_RECORD -> "start screen recording"
        Feature.NFC -> "turn on NFC"
        Feature.DARK_MODE -> "turn on dark mode"
        Feature.CAST -> "cast"
        Feature.QUICK_SHARE -> "quick share"
        Feature.DATA_SAVER -> "turn on data saver"
    }

    /** Only the controls this phone really supports. */
    fun list(ctx: Context): List<Map<String, String>> =
        Feature.values()
            .filter { isSupported(ctx, it) }
            .map { mapOf("id" to it.name, "name" to it.display, "example" to example(it)) }

    fun loadAllowed(ctx: Context): Set<Feature> {
        val saved = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY_ALLOWED, emptySet()) ?: emptySet()

        return saved
            .mapNotNull { id -> Feature.values().firstOrNull { it.name == id } }
            .filter { isSupported(ctx, it) }
            .toSet()
    }

    fun saveAllowed(ctx: Context, ids: Set<String>) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putStringSet(KEY_ALLOWED, ids).apply()
    }
}