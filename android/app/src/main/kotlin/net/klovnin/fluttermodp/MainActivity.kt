package net.klovnin.fluttermodp

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "net.klovnin.fluttermodp/libopenmpt"
        private const val FILE_PICKER_REQUEST_CODE = 2001
    }

    private var pendingFilePickerResult: MethodChannel.Result? = null

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
                    "initialize" -> {
                        result.success(
                            mapOf(
                                "success" to true,
                                "message" to "libopenmpt is ready.",
                            ),
                        )
                    }
                    "pickFile" -> pickFile(result)
                    "playFile" -> {
                        val uri = call.argument<String>("uri")
                        val name = call.argument<String>("name") ?: "selected module"
                        if (uri.isNullOrBlank()) {
                            result.error("invalid_arguments", "uri is required", null)
                        } else {
                            startPlaybackService(
                                PlaybackService.ACTION_START,
                                uri = uri,
                                name = name,
                            )
                            result.success(
                                mapOf(
                                    "success" to true,
                                    "message" to "再生を開始しました: $name",
                                ),
                            )
                        }
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

    private fun pickFile(result: MethodChannel.Result) {
        if (pendingFilePickerResult != null) {
            result.error("picker_busy", "ファイル選択は既に実行中です。", null)
            return
        }
        pendingFilePickerResult = result
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            },
            FILE_PICKER_REQUEST_CODE,
        )
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != FILE_PICKER_REQUEST_CODE) return
        val result = pendingFilePickerResult ?: return
        pendingFilePickerResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        try {
            val takeFlags = data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (_: SecurityException) {
            // Some document providers grant only a transient read permission.
        }
        result.success(
            mapOf(
                "uri" to uri.toString(),
                "name" to displayName(uri),
            ),
        )
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf("_display_name"), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return uri.lastPathSegment ?: "selected module"
    }

    private fun startPlaybackService(action: String, uri: String? = null, name: String? = null) {
        val intent = PlaybackService.intent(this, action).apply {
            if (uri != null) putExtra(PlaybackService.EXTRA_URI, uri)
            if (name != null) putExtra(PlaybackService.EXTRA_NAME, name)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

}
