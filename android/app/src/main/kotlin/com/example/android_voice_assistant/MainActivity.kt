
package com.example.android_voice_assistant

import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private var eventSink: EventChannel.EventSink? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        @JvmStatic
        fun emitServiceEvent(type: String, value: String) {
            mainHandler.post {
                eventSink?.success(
                    mapOf(
                        "type" to type,
                        "value" to value
                    )
                )
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hello_boss/wake_word_events"
        ).setStreamHandler(object : EventChannel.StreamHandler {

            override fun onListen(
                arguments: Any?,
                events: EventChannel.EventSink
            ) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "hello_boss/wake_word"
        ).setMethodCallHandler { call, result ->

            when (call.method) {
                "start" -> {
                    try {
                        val intent = Intent(
                            this,
                            WakeWordService::class.java
                        ).apply {
                            action = WakeWordService.ACTION_START
                        }

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }

                        result.success(null)
                    } catch (e: Exception) {
                        result.error(
                            "START_FAILED",
                            e.message,
                            null
                        )
                    }
                }

                "stop" -> {
                    val intent = Intent(
                        this,
                        WakeWordService::class.java
                    ).apply {
                        action = WakeWordService.ACTION_STOP
                    }

                    startService(intent)
                    result.success(null)
                }

                "setLanguage" -> {
                    val language = call.argument<String>("language")
                        ?: "en-US"

                    val intent = Intent(
                        this,
                        WakeWordService::class.java
                    ).apply {
                        action = WakeWordService.ACTION_LANGUAGE
                        putExtra(
                            WakeWordService.EXTRA_LANGUAGE,
                            language
                        )
                    }

                    startService(intent)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }
}
