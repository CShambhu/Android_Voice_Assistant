package com.example.android_voice_assistant

import android.content.Context

/**
 * The apps the user chose in "Choose your apps". Stored natively so the
 * background WakeWordService can read it even when the Flutter UI is gone.
 * Nothing selected (or never configured) means Hello Boss controls no apps.
 */
object AllowedApps {
    private const val PREFS = "hello_boss_prefs"
    private const val KEY = "allowed_packages"

    fun load(context: Context): Set<String> {
        val stored = context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getStringSet(KEY, null)

        // Copy: the set returned by SharedPreferences must not be modified.
        return stored?.toSet() ?: emptySet()
    }

    fun save(context: Context, packages: Set<String>) {
        context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putStringSet(KEY, HashSet(packages))
            .apply()
    }
}