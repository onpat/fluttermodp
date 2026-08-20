package net.klovnin.fluttermodp

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "net.klovnin.fluttermodp/libopenmpt"
        private const val PICK_MODULES_REQUEST_CODE = 2001
        private const val OPEN_PLAYLIST_REQUEST_CODE = 2002
        private const val SAVE_PLAYLIST_REQUEST_CODE = 2003
    }

    private lateinit var playlistStore: PlaylistStore
    private lateinit var renderSettingsStore: RenderSettingsStore
    private var pendingDocumentResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        playlistStore = PlaylistStore(this)
        renderSettingsStore = RenderSettingsStore(this)
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initialize" -> {
                        val loadError = NativeOpenMpt.loadError
                        result.success(
                            mapOf(
                                "success" to (loadError == null),
                                "message" to (loadError?.let { "Could not load native libraries: $it" }
                                    ?: "libopenmpt is ready."),
                            ),
                        )
                    }
                    "getPlaylist" -> result.success(PlaybackService.state(this))
                    "getRenderSettings" -> result.success(renderSettingsStore.snapshot().toMap())
                    "setRenderSettings" -> {
                        val raw = call.arguments as? Map<*, *>
                        val updates = raw?.entries
                            ?.associate { it.key.toString() to it.value }
                            ?: emptyMap()
                        val settings = renderSettingsStore.updateFromMap(updates)
                        notifyRenderSettingsChanged()
                        result.success(settings.toMap())
                    }
                    "pickFiles", "pickFile" -> pickModules(result)
                    "loadPlaylist" -> openPlaylist(result)
                    "savePlaylist" -> savePlaylist(result)
                    "removeTrack" -> {
                        val index = call.argument<Number>("index")?.toInt() ?: -1
                        playlistStore.remove(index)
                        notifyPlaylistChanged()
                        result.success(PlaybackService.state(this))
                    }
                    "clearPlaylist" -> {
                        playlistStore.clear()
                        notifyPlaylistChanged()
                        result.success(PlaybackService.state(this))
                    }
                    "setRepeatOne" -> {
                        playlistStore.setRepeatOne(call.argument<Boolean>("enabled") == true)
                        notifyRepeatChanged()
                        result.success(PlaybackService.state(this))
                    }
                    "setRepeatPlaylist" -> {
                        playlistStore.setRepeatPlaylist(call.argument<Boolean>("enabled") == true)
                        notifyRepeatChanged()
                        result.success(PlaybackService.state(this))
                    }
                    "playFile" -> playLegacyFile(call, result)
                    "play" -> {
                        startPlaybackService(PlaybackService.ACTION_PLAY)
                        result.success(true)
                    }
                    "playIndex" -> {
                        val index = call.argument<Number>("index")?.toInt() ?: -1
                        if (index !in playlistStore.snapshot().entries.indices) {
                            result.error("invalid_arguments", "index is outside the playlist", null)
                        } else {
                            startPlaybackService(PlaybackService.ACTION_PLAY_INDEX, index = index)
                            result.success(true)
                        }
                    }
                    "pause" -> {
                        sendIfRunning(PlaybackService.ACTION_PAUSE)
                        result.success(true)
                    }
                    "stop" -> {
                        sendIfRunning(PlaybackService.ACTION_STOP)
                        result.success(true)
                    }
                    "next" -> {
                        if (PlaybackService.isRunning) {
                            startService(PlaybackService.intent(this, PlaybackService.ACTION_NEXT))
                        } else if (playlistStore.snapshot().entries.isNotEmpty()) {
                            startPlaybackService(PlaybackService.ACTION_NEXT)
                        }
                        result.success(true)
                    }
                    "previous" -> {
                        if (PlaybackService.isRunning) {
                            startService(PlaybackService.intent(this, PlaybackService.ACTION_PREVIOUS))
                        } else if (playlistStore.snapshot().entries.isNotEmpty()) {
                            startPlaybackService(PlaybackService.ACTION_PREVIOUS)
                        }
                        result.success(true)
                    }
                    "seek" -> {
                        val positionMs = call.argument<Number>("positionMs")?.toLong()
                        if (positionMs == null || positionMs < 0L) {
                            result.error("invalid_arguments", "positionMs must be non-negative", null)
                        } else if (PlaybackService.isRunning) {
                            val intent = PlaybackService.intent(this, PlaybackService.ACTION_SEEK)
                                .putExtra(PlaybackService.EXTRA_POSITION_MS, positionMs)
                            startService(intent)
                            result.success(true)
                        } else {
                            result.success(false)
                        }
                    }
                    "status" -> result.success(PlaybackService.statusMessage)
                    "startHttpServer" -> {
                        val port = call.argument<Number>("port")?.toInt() ?: 8080
                        startPlaybackService(PlaybackService.ACTION_START_HTTP, httpPort = port)
                        result.success(true)
                    }
                    "stopHttpServer" -> {
                        if (PlaybackService.isHttpServerRunning || PlaybackService.isRunning) {
                            startService(PlaybackService.intent(this, PlaybackService.ACTION_STOP_HTTP))
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun pickModules(result: MethodChannel.Result) {
        if (!beginDocumentOperation(result)) return
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            },
            PICK_MODULES_REQUEST_CODE,
        )
    }

    private fun openPlaylist(result: MethodChannel.Result) {
        if (!beginDocumentOperation(result)) return
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            },
            OPEN_PLAYLIST_REQUEST_CODE,
        )
    }

    private fun savePlaylist(result: MethodChannel.Result) {
        if (!beginDocumentOperation(result)) return
        startActivityForResult(
            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "audio/x-mpegurl"
                putExtra(Intent.EXTRA_TITLE, "playlist.m3u")
                addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            },
            SAVE_PLAYLIST_REQUEST_CODE,
        )
    }

    private fun beginDocumentOperation(result: MethodChannel.Result): Boolean {
        if (pendingDocumentResult != null) {
            result.error("picker_busy", "別のファイル操作を実行中です。", null)
            return false
        }
        pendingDocumentResult = result
        return true
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode !in setOf(PICK_MODULES_REQUEST_CODE, OPEN_PLAYLIST_REQUEST_CODE, SAVE_PLAYLIST_REQUEST_CODE)) {
            return
        }
        val result = pendingDocumentResult ?: return
        pendingDocumentResult = null
        if (resultCode != RESULT_OK) {
            result.success(null)
            return
        }
        try {
            when (requestCode) {
                PICK_MODULES_REQUEST_CODE -> importSelectedModules(data, result)
                OPEN_PLAYLIST_REQUEST_CODE -> importPlaylist(data?.data, data?.flags ?: 0, result)
                SAVE_PLAYLIST_REQUEST_CODE -> exportPlaylist(data?.data, result)
            }
        } catch (error: Exception) {
            result.error("document_error", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun importSelectedModules(data: Intent?, result: MethodChannel.Result) {
        val uris = buildList {
            data?.clipData?.let { clip ->
                for (index in 0 until clip.itemCount) add(clip.getItemAt(index).uri)
            }
            data?.data?.let(::add)
        }.distinct()
        if (uris.isEmpty()) {
            result.success(null)
            return
        }
        uris.forEach { takeReadPermission(it, data?.flags ?: 0) }
        playlistStore.add(uris.map { PlaylistEntry(it.toString(), displayName(it)) })
        notifyPlaylistChanged()
        result.success(stateWithMessage("${uris.size}曲を追加しました。"))
    }

    private fun importPlaylist(uri: Uri?, flags: Int, result: MethodChannel.Result) {
        requireNotNull(uri) { "プレイリストが選択されていません。" }
        takeReadPermission(uri, flags)
        val lines = contentResolver.openInputStream(uri)?.bufferedReader(Charsets.UTF_8)?.use {
            it.readLines()
        } ?: error("プレイリストを読み込めませんでした。")
        val entries = lines.mapIndexedNotNull { index, rawLine ->
            val value = rawLine.removePrefix("\uFEFF").trim()
            if (value.isEmpty() || value.startsWith('#')) return@mapIndexedNotNull null
            val entryUri = Uri.parse(value)
            val name = try {
                displayName(entryUri)
            } catch (_: Exception) {
                Uri.decode(value.substringAfterLast('/')).ifBlank { "Track ${index + 1}" }
            }
            PlaylistEntry(value, name)
        }
        playlistStore.replace(entries)
        notifyPlaylistChanged()
        result.success(stateWithMessage("${entries.size}曲を読み込みました。"))
    }

    private fun exportPlaylist(uri: Uri?, result: MethodChannel.Result) {
        requireNotNull(uri) { "保存先が選択されていません。" }
        val entries = playlistStore.snapshot().entries
        val contents = entries.joinToString(separator = "\n", postfix = if (entries.isEmpty()) "" else "\n") {
            it.uri
        }
        contentResolver.openOutputStream(uri, "wt")?.bufferedWriter(Charsets.UTF_8)?.use {
            it.write(contents)
        } ?: error("プレイリストを保存できませんでした。")
        result.success(mapOf("success" to true, "message" to "${entries.size}曲を保存しました。"))
    }

    private fun takeReadPermission(uri: Uri, flags: Int) {
        try {
            val takeFlags = flags and Intent.FLAG_GRANT_READ_URI_PERMISSION
            if (takeFlags != 0) contentResolver.takePersistableUriPermission(uri, takeFlags)
        } catch (_: SecurityException) {
            // Some providers offer only a transient grant.
        }
    }

    private fun displayName(uri: Uri): String {
        contentResolver.query(uri, arrayOf("_display_name"), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return Uri.decode(uri.lastPathSegment ?: "selected module")
    }

    private fun stateWithMessage(message: String): Map<String, Any?> =
        PlaybackService.state(this).toMutableMap().apply {
            this["message"] = message
        }

    private fun playLegacyFile(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val uri = call.argument<String>("uri")
        val name = call.argument<String>("name") ?: "selected module"
        if (uri.isNullOrBlank()) {
            result.error("invalid_arguments", "uri is required", null)
            return
        }
        startPlaybackService(PlaybackService.ACTION_START, uri = uri, name = name)
        result.success(mapOf("success" to true, "message" to "再生を開始しました: $name"))
    }

    private fun notifyPlaylistChanged() {
        if (PlaybackService.isRunning) {
            startService(PlaybackService.intent(this, PlaybackService.ACTION_PLAYLIST_CHANGED))
        }
    }

    private fun notifyRepeatChanged() {
        if (PlaybackService.isRunning) {
            startService(PlaybackService.intent(this, PlaybackService.ACTION_REPEAT_CHANGED))
        }
    }

    private fun notifyRenderSettingsChanged() {
        if (PlaybackService.isRunning) {
            startService(PlaybackService.intent(this, PlaybackService.ACTION_RENDER_SETTINGS_CHANGED))
        }
    }

    private fun sendIfRunning(action: String) {
        if (PlaybackService.isRunning) startService(PlaybackService.intent(this, action))
    }

    private fun startPlaybackService(
        action: String,
        uri: String? = null,
        name: String? = null,
        index: Int? = null,
        httpPort: Int? = null,
    ) {
        val intent = PlaybackService.intent(this, action).apply {
            if (uri != null) putExtra(PlaybackService.EXTRA_URI, uri)
            if (name != null) putExtra(PlaybackService.EXTRA_NAME, name)
            if (index != null) putExtra(PlaybackService.EXTRA_INDEX, index)
            if (httpPort != null) putExtra(PlaybackService.EXTRA_PORT, httpPort)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }
}
