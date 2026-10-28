
package com.example.android_voice_assistant

import android.Manifest
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.voxrt.sdk.wakeword.VoxrtWakeWordEngine
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

class WakeWordService : Service() {

    companion object {
        const val ACTION_START = "hello.boss.START"
        const val ACTION_STOP = "hello.boss.STOP"
        const val ACTION_LANGUAGE = "hello.boss.LANGUAGE"
        const val EXTRA_LANGUAGE = "language"

        private const val CHANNEL_ID = "hello_boss_listener"
        private const val NOTIFICATION_ID = 4101
        private const val TAG = "WakeWordService"
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val running = AtomicBoolean(false)
    private val capturing = AtomicBoolean(false)

    @Volatile
    private var recorder: AudioRecord? = null

    @Volatile
    private var captureThread: Thread? = null

    private var speechRecognizer: SpeechRecognizer? = null
    private var language = "en-US"
    private var restarting = false

    override fun onBind(intent: Intent?): IBinder? = null

        override fun onCreate() {
        super.onCreate()
        createNotificationChannel()

        // Restore the chosen language if the service was restarted.
        language = getSharedPreferences("hello_boss_prefs", MODE_PRIVATE)
            .getString("language", "en-US") ?: "en-US"
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        when (intent?.action ?: ACTION_START) {
            ACTION_START -> startListeningService()

            ACTION_STOP -> stopListeningService()

           ACTION_LANGUAGE -> {
        language = intent?.getStringExtra(EXTRA_LANGUAGE) ?: "en-US"

    getSharedPreferences("hello_boss_prefs", MODE_PRIVATE)
        .edit()
        .putString("language", language)
        .apply()
    if (running.get() && !capturing.get()) {
        startWakeCapture()
    }
}
        }

        return START_NOT_STICKY
    }

    private fun startListeningService() {
        if (!running.compareAndSet(false, true)) return

        if (
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO
            ) != PackageManager.PERMISSION_GRANTED
        ) {
            running.set(false)
            report("error", "Microphone permission has not been granted")
            stopSelf()
            return
        }

        try {
            startForeground(
                NOTIFICATION_ID,
                buildNotification()
            )

            report("status", "listening")
            startWakeCapture()
        } catch (e: Exception) {
            Log.e(TAG, "Could not start foreground service", e)
            running.set(false)
            report("error", "Service startup failed: ${e.message}")
            stopSelf()
        }
    }

    private fun startWakeCapture() {
        if (!running.get()) return

        if (!capturing.compareAndSet(false, true)) return

        var engine: VoxrtWakeWordEngine? = null
        var audio: AudioRecord? = null

        try {
            engine = VoxrtWakeWordEngine.fromAssetBytes(
                assets,
                "voxrt_wake_word.vxrt"
            )

            engine.setThreshold(0.80f)
engine.setCooldownFrames(100)

            val sampleRate = 16000
            val blockSamples = 1600

            val minBuffer = AudioRecord.getMinBufferSize(
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT
            )

            check(minBuffer > 0) {
                "AudioRecord buffer configuration failed: $minBuffer"
            }

            audio = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                sampleRate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(minBuffer, blockSamples * 4)
            )

            check(audio.state == AudioRecord.STATE_INITIALIZED) {
                "AudioRecord could not initialize"
            }

            recorder = audio

            val activeAudio = audio
            val activeEngine = engine

            captureThread = Thread({
                var detected = false
                val buffer = ShortArray(blockSamples)

                try {
                    activeAudio.startRecording()

                    while (running.get() && capturing.get()) {
                        val count = activeAudio.read(
                            buffer,
                            0,
                            buffer.size,
                            AudioRecord.READ_BLOCKING
                        )

                        if (count < 0) {
                            Log.e(TAG, "AudioRecord.read failed: $count")
                            break
                        }

                        if (count == 0) continue

                        val chunk = if (count == buffer.size) {
                            buffer
                        } else {
                            buffer.copyOf(count)
                        }

                        val detections = activeEngine.processPcm(chunk)

                        if (detections.isNotEmpty()) {
                            Log.i(TAG, "Wake word detected: $detections")
                            detected = true
                            capturing.set(false)
                            break
                        }
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "Wake capture failed", e)

                    mainHandler.post {
                        report(
                            "error",
                            "Wake capture failed: ${e.message}"
                        )
                    }
                } finally {
                    try {
                        if (
                            activeAudio.recordingState ==
                            AudioRecord.RECORDSTATE_RECORDING
                        ) {
                            activeAudio.stop()
                        }
                    } catch (_: Exception) {
                    }

                    try {
                        activeAudio.release()
                    } catch (_: Exception) {
                    }

                    try {
                        activeEngine.close()
                    } catch (_: Exception) {
                    }

                    recorder = null
                    captureThread = null
                    capturing.set(false)

                    if (detected && running.get()) {
                        mainHandler.post {
                            beginCommandRecognition()
                        }
                    } else if (running.get()) {
                        mainHandler.postDelayed({
                            if (
                                running.get() &&
                                !capturing.get() &&
                                !restarting
                            ) {
                                startWakeCapture()
                            }
                        }, 500)
                    }
                }
            }, "VoxRT-WakeCapture")

            captureThread?.start()

        } catch (e: Exception) {
            Log.e(TAG, "Could not start VoxRT", e)

            try {
                audio?.release()
            } catch (_: Exception) {
            }

            try {
                engine?.close()
            } catch (_: Exception) {
            }

            recorder = null
            captureThread = null
            capturing.set(false)

            report("error", "Could not start VoxRT: ${e.message}")
        }
    }

    private fun beginCommandRecognition() {
        if (!running.get() || restarting) return

        restarting = true

        report("wakeWord", "Hey Assistant")
        report("status", "command")

        if (!SpeechRecognizer.isRecognitionAvailable(this)) {
            report("error", "Android speech recognition is unavailable")
            finishCommandPhase()
            return
        }

        try {
            speechRecognizer?.destroy()

            speechRecognizer =
                SpeechRecognizer.createSpeechRecognizer(this)

            speechRecognizer?.setRecognitionListener(
                object : RecognitionListener {

                    override fun onReadyForSpeech(
                        params: android.os.Bundle?
                    ) = Unit

                    override fun onBeginningOfSpeech() = Unit

                    override fun onRmsChanged(rmsdB: Float) = Unit

                    override fun onBufferReceived(buffer: ByteArray?) = Unit

                    override fun onEndOfSpeech() = Unit

                    
override fun onError(error: Int) {
    val message = when (error) {
        SpeechRecognizer.ERROR_AUDIO ->
            "Audio recording error"

        SpeechRecognizer.ERROR_CLIENT ->
            "Speech recognizer client error"

        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
            "Microphone permission missing"

        SpeechRecognizer.ERROR_NO_MATCH ->
            "No speech matched"

        SpeechRecognizer.ERROR_SPEECH_TIMEOUT ->
            "No speech heard in time"

        SpeechRecognizer.ERROR_RECOGNIZER_BUSY ->
            "Recognizer is busy"

        SpeechRecognizer.ERROR_NETWORK ->
            "Network error"

        SpeechRecognizer.ERROR_NETWORK_TIMEOUT ->
            "Network timeout"

        SpeechRecognizer.ERROR_SERVER ->
            "Recognition server error"

        else -> "Speech recognition error code: $error"
    }

    Log.e(TAG, message)
    report("error", message)
    finishCommandPhase()
}


                    override fun onResults(
    results: android.os.Bundle?
) {
    val alternatives = results
        ?.getStringArrayList(
            SpeechRecognizer.RESULTS_RECOGNITION
        )
        .orEmpty()

    Log.i(TAG, "Recognition alternatives: $alternatives")

    val spoken = alternatives.firstOrNull().orEmpty().trim()

    if (spoken.isNotEmpty()) {
        Log.i(TAG, "Recognized command: $spoken")
        report("command", spoken)
        handleCommand(spoken)
    } else {
        Log.w(TAG, "Speech recognizer returned no command")
        report("error", "No command was recognized")
    }

    finishCommandPhase()
}

                    override fun onPartialResults(
                        partialResults: android.os.Bundle?
                    ) = Unit

                    override fun onEvent(
                        eventType: Int,
                        params: android.os.Bundle?
                    ) = Unit
                }
            )

            val request = Intent(
                RecognizerIntent.ACTION_RECOGNIZE_SPEECH
            ).apply {
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                    RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                )
                putExtra(
                    RecognizerIntent.EXTRA_LANGUAGE,
                    language
                )
                putExtra(
                    RecognizerIntent.EXTRA_PARTIAL_RESULTS,
                    false
                )
            }

            speechRecognizer?.startListening(request)

        } catch (e: Exception) {
            Log.e(TAG, "Command recognition failed", e)
            report("error", "Recognition failed: ${e.message}")
            finishCommandPhase()
        }
    }

    private fun handleCommand(spoken: String) {
        val command = spoken.trim().trimEnd('.', '!', '?')
        val normalizedCommand = normalize(command)

        // Stop the Hello Boss listening service.
        if (
            Regex(
                """^(?:(?:hey|hello)\s+(?:boss|assistant)\s+)?(?:please\s+)?(?:close|quit|exit|stop)\s+(?:this app|hello boss|the assistant|listening)(?:\s+service)?$""",
                RegexOption.IGNORE_CASE
            ).matches(command)
        ) {
            report("status", "Stopping Hello Boss")
            stopListeningService()
            return
        }

        // Return to the Android home screen.
        if (
            Regex(
                """^(?:(?:hey|hello)\s+(?:boss|assistant)\s+)?(?:please\s+)?(?:go\s+)?(?:to\s+)?home(?:\s+screen)?$""",
                RegexOption.IGNORE_CASE
            ).matches(command)
        ) {
            goHome()
            return
        }

        // Open Android's app switcher through Accessibility, if supported.
        if (
            Regex(
                """^(?:(?:hey|hello)\s+(?:boss|assistant)\s+)?(?:please\s+)?(?:open|show)\s+(?:recent apps|app switcher)$""",
                RegexOption.IGNORE_CASE
            ).matches(command)
        ) {
            report(
                "error",
                "Opening Recents requires an enabled Accessibility Service."
            )
            return
        }

        // Close/exit commands for other apps.
        val closeMatch = Regex(
            """^(?:(?:hey|hello)\s+(?:boss|assistant)\s+)?(?:please\s+)?(?:close|quit|exit|leave)\s+(.+?)$""",
            RegexOption.IGNORE_CASE
        ).find(command)

        if (closeMatch != null) {
            val requested = closeMatch.groupValues[1]
                .trim()
                .removePrefix("the ")
                .trim()

            if (normalize(requested) in setOf(
                    "thisapp",
                    "helloboss",
                    "theassistant"
                )
            ) {
                report("status", "Stopping Hello Boss")
                stopListeningService()
                return
            }

            closeRequestedApp(requested)
            return
        }

        // Open/launch commands.
        val openMatch = Regex(
            """^(?:(?:hey|hello)\s+(?:boss|assistant)\s+)?(?:please\s+)?(?:open|launch|start|run)\s+(.+?)$""",
            RegexOption.IGNORE_CASE
        ).find(command)

        if (openMatch != null) {
            openRequestedApp(openMatch.groupValues[1].trim())
            return
        }

        report("error", "Command not recognized: $spoken")
    }

    
private fun closeRequestedApp(requested: String) {
    // Only apps the user selected can be closed; this reports its own
    // errors (nothing selected / not selected / not found / ambiguous).
    val target = resolveSelectedApp(requested, "close") ?: return

    val label = target.first
    val pkg = target.second

     val accessibility = VoiceAccessibilityService.instance
    val front = accessibility?.foregroundPackage

    Log.i(
        TAG,
        "Close $label ($pkg): front=$front, accessibility=${accessibility != null}"
    )

    // Android only lets us end an app that is NOT on screen. If the app is
    // in front (or we can't tell which app is), go Home first, then close it.
    val maybeInFront = front == null || front == pkg

    if (accessibility != null && maybeInFront) {
        if (!accessibility.goHome()) {
            report("error", "Could not leave $label to close it")
            return
        }

        mainHandler.postDelayed({ killApp(label, pkg) }, 1200)
        return
    }

    killApp(
        label,
        pkg,
        if (accessibility == null) {
            ". If it was on screen, turn on Hello Boss Voice Controls in Accessibility settings."
        } else {
            ""
        }
    )
}

private fun killApp(label: String, pkg: String, note: String = "") {
    try {
        val manager = getSystemService(ActivityManager::class.java)
        manager.killBackgroundProcesses(pkg)
        Log.i(TAG, "killBackgroundProcesses($pkg) called")
        report("status", "Closed $label$note")
    } catch (e: Exception) {
        Log.e(TAG, "Could not close $label", e)
        report("error", "Could not close $label: ${e.message}")
    }
}

/**
 * Finds the ONE installed app the user asked for, but only among the apps
 * they selected. Returns null (after reporting why) otherwise.
 */
private fun resolveSelectedApp(
    requested: String,
    verb: String
): Triple<String, String, Intent>? {
    val requestedName = normalize(requested)

    if (requestedName.isBlank()) {
        report("error", "Please say an app name")
        return null
    }

    val allowed = AllowedApps.load(this)

    if (allowed.isEmpty()) {
        report(
            "error",
            "No apps are selected. Choose the apps Hello Boss may control first."
        )
        return null
    }

    return try {
        val pm = packageManager

        val candidates = pm.getInstalledApplications(
            PackageManager.GET_META_DATA
        ).mapNotNull { app ->
            val launchIntent =
                pm.getLaunchIntentForPackage(app.packageName)
                    ?: return@mapNotNull null

            Triple(
                pm.getApplicationLabel(app).toString(),
                app.packageName,
                launchIntent
            )
        }

        val matches = findMatches(
            candidates.filter { it.second in allowed },
            requestedName
        )

        when {
            matches.size == 1 -> matches.first()

            matches.size > 1 -> {
                report(
                    "error",
                    "Multiple apps match '$requested'. Say the full app name."
                )
                null
            }

            findMatches(candidates, requestedName).isNotEmpty() -> {
                report(
                    "error",
                    "$requested is not in your selected apps, so Hello Boss won't $verb it."
                )
                null
            }

            else -> {
                report("error", "No app matched: $requested")
                null
            }
        }
    } catch (e: Exception) {
        Log.e(TAG, "Could not look up $requested", e)
        report("error", "Could not look up $requested: ${e.message}")
        null
    }
}

    
private fun goHome() {
    val accessibility = VoiceAccessibilityService.instance

    if (accessibility == null) {
        report(
            "error",
            "Enable Hello Boss Voice Controls in Android Accessibility settings first."
        )

        try {
            startActivity(
                Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "Could not open Accessibility settings", e)
        }

        return
    }

    if (accessibility.goHome()) {
        report("status", "Home screen opened")
    } else {
        report("error", "Android could not perform the Home action")
    }
}


    private fun openRequestedApp(requested: String) {
        val requestedName = normalize(requested)

        if (requestedName.isBlank()) {
            report("error", "Please say an app name")
            return
        }

                val allowed = AllowedApps.load(this)

        if (allowed.isEmpty()) {
            report(
                "error",
                "No apps are selected. Choose the apps Hello Boss may control first."
            )
            return
        }
        
        try {
            val pm = packageManager

            val candidates = pm.getInstalledApplications(
                PackageManager.GET_META_DATA
            ).mapNotNull { app ->
                val launchIntent =
                    pm.getLaunchIntentForPackage(app.packageName)
                        ?: return@mapNotNull null

                val label = pm.getApplicationLabel(app).toString()

                Triple(label, app.packageName, launchIntent)
            }

                        // Hello Boss may only control the apps the user selected.
            val allowedCandidates = candidates.filter {
                it.second in allowed
            }

            val matches = findMatches(allowedCandidates, requestedName)

            if (matches.isEmpty() &&
                findMatches(candidates, requestedName).isNotEmpty()
            ) {
                report(
                    "error",
                    "$requested is not in your selected apps, so Hello Boss won't open it."
                )
                return
            }

            when (matches.size) {
                0 -> {
                    report(
                        "error",
                        "No launchable app matched: $requested"
                    )
                }

                                1 -> {
                    val selected = matches.first()

                    if (launchApp(selected.first, selected.third)) {
                        report("launched", selected.first)
                        report("status", "Opened ${selected.first}")
                    }
                }

                else -> {
                    report(
                        "error",
                        "Multiple apps match '$requested'. Say the full app name."
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Could not open app", e)
            report("error", "Could not open app: ${e.message}")
        }
    }

        /**
     * Starts [intent] even when another app is currently in the foreground.
     *
     * Android 10+ silently drops startActivity() calls from an app that has
     * no visible window (a foreground service does not count). Hello Boss
     * only has a visible window for the very first command, which is why the
     * 2nd/3rd app never opened. Apps holding "Display over other apps"
     * (SYSTEM_ALERT_WINDOW) are exempt, so we require it and tell the user
     * how to grant it instead of failing silently.
     */
    private fun launchApp(label: String, intent: Intent): Boolean {
        intent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        )

        val canStartFromBackground =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.Q ||
                Settings.canDrawOverlays(this)

        if (!canStartFromBackground) {
            // The launch may still work if Hello Boss happens to be visible,
            // so try it, but make the missing permission obvious.
            Log.w(TAG, "Overlay permission missing; background launch may be blocked")
            report(
                "error",
                "Allow \"Display over other apps\" for Hello Boss so it can " +
                    "open $label while another app is open."
            )

            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        android.net.Uri.parse("package:$packageName")
                    ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
            } catch (e: Exception) {
                Log.e(TAG, "Could not open overlay permission settings", e)
            }

            return false
        }

        return try {
            // Prefer the accessibility service's context when it is enabled:
            // it is bound by the system and is the most reliable launcher.
            val launcher: android.content.Context =
                VoiceAccessibilityService.instance ?: this

            launcher.startActivity(intent)
            true
        } catch (e: Exception) {
            Log.e(TAG, "Could not launch $label", e)
            report("error", "Could not open $label: ${e.message}")
            false
        }
    }

        /** Exact label match first, then partial match, within [pool]. */
    private fun findMatches(
        pool: List<Triple<String, String, Intent>>,
        requestedName: String
    ): List<Triple<String, String, Intent>> {
        val exact = pool.filter { normalize(it.first) == requestedName }
        if (exact.isNotEmpty()) return exact

        return pool.filter {
            val appName = normalize(it.first)

            // A label with no a-z/0-9 characters (e.g. Nepali) normalizes
            // to "" and would otherwise partially match every request.
            appName.isNotEmpty() &&
                (appName.contains(requestedName) ||
                    requestedName.contains(appName))
        }
    }

    private fun normalize(value: String): String {
        return value.lowercase(Locale.ROOT)
            .replace(Regex("[^a-z0-9]"), "")
    }

    private fun finishCommandPhase() {
    // Ignore duplicate callbacks from the same recognition session.
    if (!restarting) return

    restarting = false

    val recognizer = speechRecognizer
    speechRecognizer = null

    try {
        recognizer?.cancel()
    } catch (e: Exception) {
        Log.w(TAG, "Could not cancel recognizer", e)
    }

    try {
        recognizer?.destroy()
    } catch (e: Exception) {
        Log.w(TAG, "Could not destroy recognizer", e)
    }

    if (!running.get()) return

        // Delay "listening" so the result of the command (Opened / Closed /
    // error message) stays visible instead of being replaced instantly.
    mainHandler.postDelayed({
        if (running.get()) report("status", "listening")
    }, 3000)

    mainHandler.postDelayed({
        if (!running.get()) return@postDelayed

        // Do not start another capture while one is active.
        if (capturing.get()) return@postDelayed

        Log.i(TAG, "Restarting wake-word capture")
        startWakeCapture()
    }, 1000)
}

    private fun stopListeningService() {
        running.set(false)
        capturing.set(false)

        mainHandler.removeCallbacksAndMessages(null)

        try {
            recorder?.stop()
        } catch (_: Exception) {
        }

        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null

        restarting = false

        stopForeground(STOP_FOREGROUND_REMOVE)
        report("status", "stopped")
        stopSelf()
    }

    private fun buildNotification(): Notification {
        val launchIntent =
            packageManager.getLaunchIntentForPackage(packageName)

        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or
                    PendingIntent.FLAG_IMMUTABLE
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("Hello Boss is listening")
            .setContentText("Say Hey Assistant to give a command")
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(pendingIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Wake-word listening",
                NotificationManager.IMPORTANCE_LOW
            )

            getSystemService(NotificationManager::class.java)
                .createNotificationChannel(channel)
        }
    }

    private fun report(type: String, value: String) {
        MainActivity.emitServiceEvent(type, value)
    }

    override fun onDestroy() {
        running.set(false)
        capturing.set(false)

        mainHandler.removeCallbacksAndMessages(null)

        try {
            recorder?.stop()
        } catch (_: Exception) {
        }

        speechRecognizer?.cancel()
        speechRecognizer?.destroy()
        speechRecognizer = null

        try {
            recorder?.release()
        } catch (_: Exception) {
        }

        recorder = null

        super.onDestroy()
    }
}
