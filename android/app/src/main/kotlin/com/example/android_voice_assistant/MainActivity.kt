
package com.example.android_voice_assistant

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    private val iconExecutor = Executors.newFixedThreadPool(2)

    // Renders any icon (including adaptive icons) to PNG bytes.
    private fun drawableToPng(drawable: Drawable, size: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)

        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()

        return out.toByteArray()
    }

    override fun onDestroy() {
        iconExecutor.shutdown()
        super.onDestroy()
    }

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

                "setAllowedApps" -> {
                    val packages = call.argument<List<String>>("packages")
                        ?: emptyList()

                    AllowedApps.save(this, packages.toSet())
                    result.success(null)
                }

                "getAllowedApps" -> {
                    result.success(AllowedApps.load(this).toList())
                }

                "getAppIcon" -> {
                    val pkg = call.argument<String>("package")

                    if (pkg == null) {
                        result.success(null)
                    } else {
                        // Draw off the main thread, reply on it.
                        iconExecutor.execute {
                            val png = try {
                                drawableToPng(
                                    packageManager.getApplicationIcon(pkg),
                                    128
                                )
                            } catch (e: Exception) {
                                null
                            }

                            runOnUiThread { result.success(png) }
                        }
                    }
                }

                else -> result.notImplemented()
            }
        }
    }
}