package net.klovnin.fluttermodp

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.NetworkInterface
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.math.max

class PlaybackService : Service() {
    companion object {
        private const val TAG = "fluttermodp/playback"
        private const val NOTIFICATION_CHANNEL_ID = "mod_playback"
        private const val NOTIFICATION_ID = 1001
        private const val CHANNEL_COUNT = 2
        // Render 500 ms at a time. AudioTrack holds two chunks (about one
        // second), reducing JNI calls and playback-thread wakeups while
        // retaining responsive transport controls.
        private const val STATE_UPDATE_CHUNKS = 2

        const val ACTION_START = "net.klovnin.fluttermodp.action.START"
        const val ACTION_PLAY = "net.klovnin.fluttermodp.action.PLAY"
        const val ACTION_PAUSE = "net.klovnin.fluttermodp.action.PAUSE"
        const val ACTION_STOP = "net.klovnin.fluttermodp.action.STOP"
        const val ACTION_NEXT = "net.klovnin.fluttermodp.action.NEXT"
        const val ACTION_PREVIOUS = "net.klovnin.fluttermodp.action.PREVIOUS"
        const val ACTION_PLAY_INDEX = "net.klovnin.fluttermodp.action.PLAY_INDEX"
        const val ACTION_PLAYLIST_CHANGED = "net.klovnin.fluttermodp.action.PLAYLIST_CHANGED"
        const val ACTION_REPEAT_CHANGED = "net.klovnin.fluttermodp.action.REPEAT_CHANGED"
        const val ACTION_SEEK = "net.klovnin.fluttermodp.action.SEEK"
        const val ACTION_START_HTTP = "net.klovnin.fluttermodp.action.START_HTTP"
        const val ACTION_STOP_HTTP = "net.klovnin.fluttermodp.action.STOP_HTTP"
        const val ACTION_RENDER_SETTINGS_CHANGED = "net.klovnin.fluttermodp.action.RENDER_SETTINGS_CHANGED"
        const val EXTRA_POSITION_MS = "position_ms"
        const val EXTRA_INDEX = "playlist_index"
        const val EXTRA_URI = "module_uri"
        const val EXTRA_NAME = "module_name"
        const val EXTRA_PORT = "http_port"
        const val HTTP_SERVER_CHANNEL = "net.klovnin.fluttermodp/http_server"
        const val PLAYER_CHANNEL = "net.klovnin.fluttermodp/player"

        @Volatile var isHttpServerRunning: Boolean = false
            private set
        @Volatile var httpServerPort: Int = 0
            private set
        @Volatile var httpServerAddress: String? = null
            private set

        @Volatile var statusMessage: String = "再生停止中"
            private set
        @Volatile var isRunning: Boolean = false
            private set
        @Volatile var isPaused: Boolean = false
            private set
        @Volatile var activeIndex: Int = -1
            private set

        fun intent(context: Context, action: String): Intent =
            Intent(context, PlaybackService::class.java).setAction(action)

        fun state(context: Context): Map<String, Any?> {
            val snapshot = PlaylistStore(context).snapshot()
            val index = if (isRunning) activeIndex else snapshot.currentIndex
            return mapOf<String, Any?>(
                "entries" to snapshot.entries.map(PlaylistEntry::toMap),
                "currentIndex" to index,
                "repeatOne" to snapshot.repeatOne,
                "repeatPlaylist" to snapshot.repeatPlaylist,
                "isPlaying" to (isRunning && !isPaused),
                "isPaused" to (isRunning && isPaused),
                "status" to statusMessage,
                "httpServerRunning" to isHttpServerRunning,
                "httpServerPort" to httpServerPort,
                "httpServerAddress" to httpServerAddress,
            )
        }

        fun localIpAddresses(): List<String> = buildList {
            try {
                NetworkInterface.getNetworkInterfaces()?.asSequence()
                    ?.filter { it.isUp && !it.isLoopback }
                    ?.forEach { intf ->
                        intf.inetAddresses.asSequence()
                            .filter { !it.isLoopbackAddress && it.hostAddress?.contains(':') == false }
                            .mapNotNull { it.hostAddress }
                            .forEach { add(it) }
                    }
            } catch (_: Exception) {
                // Best-effort enumeration; ignore failures.
            }
        }

        fun preferredLocalAddress(): String? =
            localIpAddresses().firstOrNull { it.startsWith("192.168.") || it.startsWith("10.") }
                ?: localIpAddresses().firstOrNull()
    }

    private val stateLock = Object()
    private val pendingSeekMs = AtomicLong(-1L)
    private val requestedIndex = AtomicInteger(-1)

    @Volatile private var prepared = false
    @Volatile private var resumeOnFocusGain = false
    @Volatile private var activeUri: String? = null

    private var playbackThread: Thread? = null
    private var audioTrack: AudioTrack? = null
    private lateinit var audioManager: AudioManager
    private lateinit var mediaSession: MediaSession
    private lateinit var playlistStore: PlaylistStore
    private lateinit var renderSettingsStore: RenderSettingsStore
    private var audioFocusRequest: AudioFocusRequest? = null
    @Volatile private var moduleName = "MOD player"

    private var httpEngine: FlutterEngine? = null
    private var httpChannel: MethodChannel? = null
    private var wakeLock: PowerManager.WakeLock? = null
    @Volatile private var httpPort: Int = 8080

    override fun onCreate() {
        super.onCreate()
        playlistStore = PlaylistStore(this)
        renderSettingsStore = RenderSettingsStore(this)
        audioManager = getSystemService(AudioManager::class.java)
        createNotificationChannel()
        createMediaSession()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action ?: ACTION_PLAY
        if (
            !isRunning && action in setOf(
                ACTION_START,
                ACTION_PLAY,
                ACTION_NEXT,
                ACTION_PREVIOUS,
                ACTION_PLAY_INDEX,
                ACTION_START_HTTP,
            )
        ) {
            // A command may arrive through startForegroundService while the
            // playlist is concurrently emptied. Always satisfy Android's
            // foreground-service deadline before validating the command.
            startForeground(NOTIFICATION_ID, buildNotification("準備中…"))
        }
        when (action) {
            ACTION_START -> startLegacyEntry(intent)
            ACTION_PLAY -> resumePlayback()
            ACTION_PAUSE -> pausePlayback()
            ACTION_STOP -> stopPlayback(removeNotification = true)
            ACTION_NEXT -> skipBy(1)
            ACTION_PREVIOUS -> skipBy(-1)
            ACTION_PLAY_INDEX -> playIndex(intent?.getIntExtra(EXTRA_INDEX, -1) ?: -1)
            ACTION_PLAYLIST_CHANGED -> playlistChanged()
            ACTION_REPEAT_CHANGED -> repeatChanged()
            ACTION_SEEK -> {
                val positionMs = intent?.getLongExtra(EXTRA_POSITION_MS, -1L) ?: -1L
                if (isRunning && positionMs >= 0L) {
                    pendingSeekMs.set(positionMs)
                    // Interrupt a blocking write. The playback thread will
                    // discard the remainder, flush, seek, and refill.
                    audioTrack?.pause()
                    synchronized(stateLock) { stateLock.notifyAll() }
                } else if (!isRunning) {
                    stopSelf()
                }
            }
            ACTION_START_HTTP -> {
                httpPort = intent?.getIntExtra(EXTRA_PORT, 8080) ?: 8080
                startHttpServer()
            }
            ACTION_STOP_HTTP -> stopHttpServer()
            ACTION_RENDER_SETTINGS_CHANGED -> applyRenderSettingsToModule()
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isRunning = false
        isPaused = false
        synchronized(stateLock) { stateLock.notifyAll() }
        playbackThread?.takeIf { it !== Thread.currentThread() }?.join(2000)
        disposeHttp()
        mediaSession.release()
        super.onDestroy()
    }

    private fun startLegacyEntry(intent: Intent?) {
        val uri = intent?.getStringExtra(EXTRA_URI)
        if (!uri.isNullOrBlank()) {
            val name = intent.getStringExtra(EXTRA_NAME) ?: "selected module"
            val snapshot = playlistStore.add(listOf(PlaylistEntry(uri, name)))
            playIndex(snapshot.entries.lastIndex)
        } else {
            resumePlayback()
        }
    }

    private fun startPlayback() {
        if (isRunning) return
        val snapshot = playlistStore.snapshot()
        if (snapshot.entries.isEmpty()) {
            statusMessage = "プレイリストが空のため停止しています。"
            activeIndex = -1
            isPaused = false
            if (!isHttpServerRunning) stopForeground(STOP_FOREGROUND_REMOVE)
            finishIfIdle()
            return
        }

        NativeOpenMpt.loadError?.let {
            failPlayback("Could not load native libraries: $it")
            return
        }
        if (!requestAudioFocus()) {
            failPlayback("オーディオフォーカスを取得できませんでした。")
            return
        }

        activeIndex = snapshot.currentIndex.coerceIn(snapshot.entries.indices)
        isRunning = true
        isPaused = false
        prepared = false
        playbackThread = thread(
            start = true,
            isDaemon = false,
            name = "OpenMptPlaybackThread",
            priority = Thread.MAX_PRIORITY,
        ) { playbackLoop() }
    }

    private fun playbackLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
        var track: AudioTrack? = null
        try {
            val audioSettings = renderSettingsStore.snapshot()
            val sampleRate = audioSettings.sampleRate.coerceIn(8000, 192000)
            val floatOutput = audioSettings.floatOutput
            val chunkFrames = (sampleRate / 2).coerceAtLeast(1)
            track = createAudioTrack(sampleRate, floatOutput, chunkFrames).also { audioTrack = it }
            while (isRunning) {
                val snapshot = playlistStore.snapshot()
                if (snapshot.entries.isEmpty()) {
                    statusMessage = "プレイリストが空のため停止しています。"
                    break
                }
                activeIndex = activeIndex.coerceIn(snapshot.entries.indices)
                playlistStore.setCurrentIndex(activeIndex)
                val entry = snapshot.entries[activeIndex]
                activeUri = entry.uri
                moduleName = entry.name

                val moduleData = contentResolver.openInputStream(android.net.Uri.parse(entry.uri))?.use {
                    it.readBytes()
                } ?: throw IllegalStateException("${entry.name} を読み込めませんでした。")
                if (!NativeOpenMpt.nativeInitializeModule(moduleData)) {
                    throw IllegalStateException(NativeOpenMpt.nativeGetLastMessage())
                }
                NativeOpenMpt.nativeSetRepeatCount(if (snapshot.repeatOne) -1 else 0)
                NativeOpenMpt.applyModuleSettings(renderSettingsStore.snapshot())

                prepared = true
                statusMessage = "再生中: ${entry.name}"
                updateMetadata()
                mediaSession.isActive = true
                updatePlaybackState(PlaybackState.STATE_PLAYING)
                updateNotification(statusMessage)
                track.play()

                var reachedEnd = false
                var chunksSinceStateUpdate = 0
                while (isRunning && requestedIndex.get() < 0) {
                    waitUntilPlayableOrSeekable()
                    if (!isRunning || requestedIndex.get() >= 0) break
                    applyPendingSeek(track)
                    if (isPaused) continue
                    val pcm = NativeOpenMpt.nativeRenderPcm(chunkFrames, sampleRate, floatOutput)
                    if (pcm.isEmpty()) {
                        reachedEnd = true
                        break
                    }
                    writeFully(track, pcm)
                    chunksSinceStateUpdate++
                    if (chunksSinceStateUpdate >= STATE_UPDATE_CHUNKS) {
                        chunksSinceStateUpdate = 0
                        updatePlaybackState(PlaybackState.STATE_PLAYING)
                    }
                }

                prepared = false
                NativeOpenMpt.nativeDestroyModule()
                if (!isRunning) break

                val requested = requestedIndex.getAndSet(-1)
                if (requested >= 0) {
                    track.pause()
                    track.flush()
                    activeIndex = requested.coerceIn(playlistStore.snapshot().entries.indices)
                    continue
                }
                if (reachedEnd) {
                    val latest = playlistStore.snapshot()
                    val next = when {
                        activeIndex < latest.entries.lastIndex -> activeIndex + 1
                        latest.repeatPlaylist && latest.entries.isNotEmpty() -> 0
                        else -> -1
                    }
                    if (next < 0) {
                        statusMessage = "プレイリストの最後まで再生しました。"
                        break
                    }
                    activeIndex = next
                    playlistStore.setCurrentIndex(next)
                }
            }
        } catch (error: Throwable) {
            statusMessage = "再生に失敗しました: ${error.message ?: error.javaClass.simpleName}"
            Log.e(TAG, statusMessage, error)
        } finally {
            isRunning = false
            isPaused = false
            prepared = false
            activeUri = null
            try {
                track?.pause()
                track?.flush()
                track?.stop()
            } catch (_: IllegalStateException) {
                // The track may already have been stopped by stopPlayback().
            }
            track?.release()
            audioTrack = null
            NativeOpenMpt.nativeDestroyModule()
            abandonAudioFocus()
            updatePlaybackState(PlaybackState.STATE_STOPPED)
            mediaSession.isActive = false
            if (!isHttpServerRunning) stopForeground(STOP_FOREGROUND_REMOVE)
            finishIfIdle()
        }
    }

    private fun playIndex(index: Int) {
        val snapshot = playlistStore.snapshot()
        if (index !in snapshot.entries.indices) {
            if (snapshot.entries.isEmpty() || !isRunning) {
                stopPlayback(removeNotification = true)
            }
            return
        }
        playlistStore.setCurrentIndex(index)
        if (!isRunning) {
            activeIndex = index
            startPlayback()
        } else {
            requestTrack(index)
        }
    }

    private fun skipBy(offset: Int) {
        val snapshot = playlistStore.snapshot()
        if (snapshot.entries.isEmpty()) {
            stopPlayback(removeNotification = true)
            return
        }
        val base = if (isRunning) activeIndex else snapshot.currentIndex
        val target = when {
            base + offset in snapshot.entries.indices -> base + offset
            snapshot.repeatPlaylist && offset > 0 -> 0
            snapshot.repeatPlaylist && offset < 0 -> snapshot.entries.lastIndex
            else -> -1
        }
        if (target < 0) {
            statusMessage = if (offset > 0) {
                "プレイリストの最後です。"
            } else {
                "プレイリストの先頭です。"
            }
            if (offset > 0 || !isRunning) stopPlayback(removeNotification = true)
            return
        }
        playIndex(target)
    }

    private fun requestTrack(index: Int) {
        isPaused = false
        requestedIndex.set(index)
        synchronized(stateLock) { stateLock.notifyAll() }
        audioTrack?.let {
            try {
                it.pause()
            } catch (_: IllegalStateException) {
                // The playback thread will process the request.
            }
        }
    }

    private fun playlistChanged() {
        val snapshot = playlistStore.snapshot()
        if (snapshot.entries.isEmpty()) {
            statusMessage = "プレイリストが空のため停止しています。"
            stopPlayback(removeNotification = true)
            return
        }
        if (!isRunning) return
        val relocatedIndex = snapshot.entries.indexOfFirst { it.uri == activeUri }
        if (relocatedIndex >= 0) {
            activeIndex = relocatedIndex
            playlistStore.setCurrentIndex(relocatedIndex)
        } else {
            requestTrack(snapshot.currentIndex)
        }
    }

    private fun repeatChanged() {
        val repeatOne = playlistStore.snapshot().repeatOne
        if (prepared) NativeOpenMpt.nativeSetRepeatCount(if (repeatOne) -1 else 0)
        updateNotification(if (repeatOne) "1曲リピート" else statusMessage)
    }

    /**
     * Re-applies module-scoped render/CTL settings to the currently loaded
     * module. Called both per-track (in the playback loop) and in response to
     * ACTION_RENDER_SETTINGS_CHANGED. Audio-format settings (sample rate /
     * bit depth) are owned by the AudioTrack and only take effect on the next
     * playback start.
     */
    private fun applyRenderSettingsToModule() {
        if (prepared) {
            NativeOpenMpt.applyModuleSettings(renderSettingsStore.snapshot())
        }
    }

    private fun waitUntilPlayableOrSeekable() {
        synchronized(stateLock) {
            while (isRunning && isPaused && pendingSeekMs.get() < 0L && requestedIndex.get() < 0) {
                stateLock.wait()
            }
        }
    }

    private fun applyPendingSeek(track: AudioTrack) {
        val positionMs = pendingSeekMs.getAndSet(-1L)
        if (positionMs < 0L) return
        track.pause()
        track.flush()
        NativeOpenMpt.nativeSeekToSeconds(positionMs / 1000.0)
        if (!isPaused && isRunning) track.play()
        updatePlaybackState(if (isPaused) PlaybackState.STATE_PAUSED else PlaybackState.STATE_PLAYING)
    }

    private fun writeFully(track: AudioTrack, pcm: ByteArray) {
        var offset = 0
        while (
            isRunning &&
            requestedIndex.get() < 0 &&
            pendingSeekMs.get() < 0L &&
            offset < pcm.size
        ) {
            // pause() may interrupt a blocking write with a short transfer.
            // Preserve and resume the unwritten part for an ordinary pause;
            // seek/skip requests intentionally discard it.
            waitUntilPlayableOrSeekable()
            if (
                !isRunning ||
                requestedIndex.get() >= 0 ||
                pendingSeekMs.get() >= 0L
            ) {
                break
            }
            val written = track.write(pcm, offset, pcm.size - offset, AudioTrack.WRITE_BLOCKING)
            if (written < 0) throw IllegalStateException("AudioTrack.write failed with $written")
            if (written == 0) {
                Thread.yield()
                continue
            }
            offset += written
        }
    }

    private fun pausePlayback() {
        if (!isRunning || isPaused) {
            if (!isRunning && !isHttpServerRunning) stopSelf()
            return
        }
        resumeOnFocusGain = false
        isPaused = true
        audioTrack?.pause()
        statusMessage = "一時停止中: $moduleName"
        updatePlaybackState(PlaybackState.STATE_PAUSED)
        updateNotification(statusMessage)
    }

    private fun resumePlayback() {
        if (!isRunning) {
            startPlayback()
            return
        }
        if (!requestAudioFocus()) return
        isPaused = false
        if (prepared) audioTrack?.play()
        synchronized(stateLock) { stateLock.notifyAll() }
        statusMessage = "再生中: $moduleName"
        mediaSession.isActive = true
        updatePlaybackState(PlaybackState.STATE_PLAYING)
        updateNotification(statusMessage)
    }

    private fun stopPlayback(removeNotification: Boolean) {
        isRunning = false
        isPaused = false
        requestedIndex.set(-1)
        synchronized(stateLock) { stateLock.notifyAll() }
        audioTrack?.let {
            try {
                it.pause()
                it.flush()
                it.stop()
            } catch (_: IllegalStateException) {
                // Ignore cleanup races with playbackLoop.
            }
        }
        statusMessage = if (playlistStore.snapshot().entries.isEmpty()) {
            "プレイリストが空のため停止しています。"
        } else {
            "再生停止中"
        }
        updatePlaybackState(PlaybackState.STATE_STOPPED)
        if (removeNotification && !isHttpServerRunning) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        finishIfIdle()
    }

    private fun failPlayback(message: String) {
        statusMessage = message
        Log.e(TAG, message)
        isRunning = false
        updatePlaybackState(PlaybackState.STATE_ERROR)
        if (!isHttpServerRunning) stopForeground(STOP_FOREGROUND_REMOVE)
        finishIfIdle()
    }

    private fun createAudioTrack(sampleRate: Int, floatOutput: Boolean, chunkFrames: Int): AudioTrack {
        val encoding = if (floatOutput) AudioFormat.ENCODING_PCM_FLOAT else AudioFormat.ENCODING_PCM_16BIT
        val bytesPerSample = if (floatOutput) Float.SIZE_BYTES else Short.SIZE_BYTES
        val format = AudioFormat.Builder()
            .setEncoding(encoding)
            .setSampleRate(sampleRate)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val chunkBytes = chunkFrames * CHANNEL_COUNT * bytesPerSample
        val minBufferBytes = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            encoding,
        )
        val builder = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(max(minBufferBytes, chunkBytes * 2))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_POWER_SAVING)
        }
        return builder.build().also {
            check(it.state == AudioTrack.STATE_INITIALIZED) { "AudioTrack initialization failed." }
            val performanceMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                it.performanceMode
            } else {
                AudioTrack.PERFORMANCE_MODE_NONE
            }
            Log.i(
                TAG,
                "AudioTrack ready: chunk=$chunkFrames frames, sampleRate=$sampleRate, " +
                    "encoding=${if (floatOutput) "float" else "pcm16"}, " +
                    "buffer=${it.bufferSizeInFrames}/${it.bufferCapacityInFrames} frames, " +
                    "performanceMode=$performanceMode",
            )
        }
    }

    private fun createMediaSession() {
        mediaSession = MediaSession(this, "FlutterModpSession").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = resumePlayback()
                override fun onPause() = pausePlayback()
                override fun onStop() = stopPlayback(removeNotification = true)
                override fun onSkipToNext() = skipBy(1)
                override fun onSkipToPrevious() = skipBy(-1)
                override fun onSeekTo(pos: Long) {
                    pendingSeekMs.set(pos.coerceAtLeast(0L))
                    synchronized(stateLock) { stateLock.notifyAll() }
                }
            })
            setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            setPlaybackToLocal(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
            )
            isActive = true
        }
        updatePlaybackState(PlaybackState.STATE_CONNECTING)
    }

    private fun updateMetadata() {
        val durationMs = (NativeOpenMpt.nativeGetDurationSeconds() * 1000.0).toLong()
        mediaSession.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, moduleName)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, "libopenmpt")
                .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
                .build(),
        )
    }

    private fun updatePlaybackState(state: Int) {
        val positionMs = if (prepared) {
            (NativeOpenMpt.nativeGetPositionSeconds() * 1000.0).toLong()
        } else 0L
        mediaSession.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_STOP or
                        PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackState.ACTION_SEEK_TO,
                )
                .setState(state, positionMs, if (state == PlaybackState.STATE_PLAYING) 1f else 0f)
                .build(),
        )
    }

    private fun buildNotification(text: String): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val toggleAction = if (isPaused) ACTION_PLAY else ACTION_PAUSE
        val toggleIcon = if (isPaused) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause
        val toggleLabel = if (isPaused) "Play" else "Pause"
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(moduleName)
            .setContentText(text)
            .setContentIntent(contentIntent)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setOngoing((isRunning && !isPaused) || isHttpServerRunning)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_previous, "Previous", servicePendingIntent(ACTION_PREVIOUS, 1)).build())
            .addAction(Notification.Action.Builder(toggleIcon, toggleLabel, servicePendingIntent(toggleAction, 2)).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_next, "Next", servicePendingIntent(ACTION_NEXT, 3)).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "Stop", servicePendingIntent(ACTION_STOP, 4)).build())
            .setStyle(Notification.MediaStyle().setMediaSession(mediaSession.sessionToken).setShowActionsInCompactView(0, 1, 2))
            .build()
    }

    private fun updateNotification(text: String) {
        if (!isRunning && !isHttpServerRunning) return
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, buildNotification(text))
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent =
        PendingIntent.getService(
            this,
            requestCode,
            intent(this, action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL_ID, "MOD playback", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Background module music playback"
                setShowBadge(false)
            },
        )
    }

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> if (resumeOnFocusGain) {
                resumeOnFocusGain = false
                resumePlayback()
            }
            AudioManager.AUDIOFOCUS_LOSS -> stopPlayback(removeNotification = true)
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            -> {
                resumeOnFocusGain = isRunning && !isPaused
                if (resumeOnFocusGain) {
                    pausePlayback()
                    resumeOnFocusGain = true
                }
            }
        }
    }

    private fun requestAudioFocus(): Boolean {
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = audioFocusRequest ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setOnAudioFocusChangeListener(focusChangeListener)
                .build()
                .also { audioFocusRequest = it }
            audioManager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            audioManager.requestAudioFocus(focusChangeListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        }
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let(audioManager::abandonAudioFocusRequest)
        } else {
            @Suppress("DEPRECATION") audioManager.abandonAudioFocus(focusChangeListener)
        }
    }

    private fun startHttpServer() {
        if (isHttpServerRunning) return
        val engine = httpEngine ?: createHttpEngine()
        acquireWakeLock()
        val port = httpPort
        httpChannel = MethodChannel(engine.dartExecutor.binaryMessenger, HTTP_SERVER_CHANNEL)
        httpChannel?.invokeMethod(
            "startServer",
            mapOf("port" to port),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    val data = result as? Map<*, *>
                    if (data?.get("success") == true) {
                        isHttpServerRunning = true
                        httpServerPort = (data["port"] as? Number)?.toInt() ?: port
                        httpServerAddress = preferredLocalAddress()
                        statusMessage = "HTTPリモコン待受中: ${httpServerAddress ?: "0.0.0.0"}:$httpServerPort"
                        updateNotification(statusMessage)
                    } else {
                        handleStartHttpFailure(data?.get("message") as? String)
                    }
                }

                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    handleStartHttpFailure(errorMessage)
                }

                override fun notImplemented() {
                    handleStartHttpFailure("HTTP server not implemented")
                }
            },
        )
    }

    private fun handleStartHttpFailure(message: String?) {
        releaseWakeLock()
        isHttpServerRunning = false
        httpServerPort = 0
        httpServerAddress = null
        Log.e(TAG, "startServer failed: $message")
        if (!isRunning) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun createHttpEngine(): FlutterEngine {
        val engine = FlutterEngine(this)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(
                FlutterInjector.instance().flutterLoader().findAppBundlePath(),
                "httpServerEntrypoint",
            ),
        )
        MethodChannel(engine.dartExecutor.binaryMessenger, PLAYER_CHANNEL)
            .setMethodCallHandler { call, result -> handlePlayerMethod(call, result) }
        httpEngine = engine
        return engine
    }

    private fun stopHttpServer() {
        disposeHttp()
        if (isRunning) {
            updateNotification(statusMessage)
        } else {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun disposeHttp() {
        httpChannel?.invokeMethod("stopServer", null)
        httpChannel?.setMethodCallHandler(null)
        httpChannel = null
        httpEngine?.destroy()
        httpEngine = null
        releaseWakeLock()
        isHttpServerRunning = false
        httpServerPort = 0
        httpServerAddress = null
    }

    private fun finishIfIdle() {
        if (isHttpServerRunning) {
            updateNotification(statusMessage)
            return
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val lock = getSystemService(PowerManager::class.java)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "$TAG:http")
        lock.setReferenceCounted(false)
        lock.acquire()
        wakeLock = lock
    }

    private fun releaseWakeLock() {
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
    }

    private fun handlePlayerMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getState" -> result.success(state(this))
            "play" -> {
                resumePlayback()
                result.success(true)
            }
            "pause" -> {
                pausePlayback()
                result.success(true)
            }
            "stop" -> {
                stopPlayback(removeNotification = true)
                result.success(true)
            }
            "next" -> {
                skipBy(1)
                result.success(true)
            }
            "previous" -> {
                skipBy(-1)
                result.success(true)
            }
            "seek" -> {
                val positionMs = call.argument<Number>("positionMs")?.toLong() ?: -1L
                if (positionMs < 0L) {
                    result.error("invalid_arguments", "positionMs must be non-negative", null)
                } else {
                    if (isRunning) {
                        pendingSeekMs.set(positionMs)
                        audioTrack?.pause()
                        synchronized(stateLock) { stateLock.notifyAll() }
                    }
                    result.success(true)
                }
            }
            "playIndex" -> {
                playIndex(call.argument<Number>("index")?.toInt() ?: -1)
                result.success(true)
            }
            "removeTrack" -> {
                playlistStore.remove(call.argument<Number>("index")?.toInt() ?: -1)
                playlistChanged()
                result.success(true)
            }
            "clearPlaylist" -> {
                playlistStore.clear()
                playlistChanged()
                result.success(true)
            }
            "setRepeatOne" -> {
                playlistStore.setRepeatOne(call.argument<Boolean>("enabled") == true)
                repeatChanged()
                result.success(true)
            }
            "setRepeatPlaylist" -> {
                playlistStore.setRepeatPlaylist(call.argument<Boolean>("enabled") == true)
                repeatChanged()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }
}
