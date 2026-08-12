package net.klovnin.fluttermodp

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "net.klovnin.fluttermodp/libopenmpt"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                val loadError = NativeOpenMpt.loadError
                if (loadError != null) {
                    result.success(
                        mapOf(
                            "success" to false,
                            "message" to "Could not load native libraries: $loadError",
                        ),
                    )
                    return@setMethodCallHandler
                }

                when (call.method) {
                    "initialize", "play" -> {
                        startPlaybackService(PlaybackService.ACTION_START)
                        result.success(
                            mapOf(
                                "success" to true,
                                "message" to "Background playback service started.",
                            ),
                        )
                    }
                    "pause" -> {
                        startService(PlaybackService.intent(this, PlaybackService.ACTION_PAUSE))
                        result.success(true)
                    }
                    "stop" -> {
                        startService(PlaybackService.intent(this, PlaybackService.ACTION_STOP))
                        result.success(true)
                    }
                    "seek" -> {
                        val positionMs = call.argument<Number>("positionMs")?.toLong()
                        if (positionMs == null || positionMs < 0L) {
                            result.error("invalid_arguments", "positionMs must be non-negative", null)
                        } else {
                            val intent = PlaybackService.intent(this, PlaybackService.ACTION_SEEK)
                                .putExtra(PlaybackService.EXTRA_POSITION_MS, positionMs)
                            startService(intent)
                            result.success(true)
                        }
                    }
                    "status" -> result.success(PlaybackService.statusMessage)
                    else -> result.notImplemented()
                }
            }
    }

    private fun startPlaybackService(action: String) {
        val intent = PlaybackService.intent(this, action)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }
}
