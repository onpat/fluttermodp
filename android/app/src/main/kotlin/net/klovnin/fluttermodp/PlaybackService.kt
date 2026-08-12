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
import android.util.Log
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.math.max

class PlaybackService : Service() {
    companion object {
        private const val TAG = "fluttermodp/playback"
        private const val NOTIFICATION_CHANNEL_ID = "mod_playback"
        private const val NOTIFICATION_ID = 1001
        private const val SAMPLE_RATE = 48000
        private const val CHANNEL_COUNT = 2
        // Render 500 ms at a time. AudioTrack holds two chunks (about one
        // second), reducing JNI calls and playback-thread wakeups while
        // retaining responsive transport controls.
        private const val RENDER_CHUNK_FRAMES = SAMPLE_RATE / 2
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
        const val EXTRA_POSITION_MS = "position_ms"
        const val EXTRA_INDEX = "playlist_index"
        const val EXTRA_URI = "module_uri"
        const val EXTRA_NAME = "module_name"

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

        fun state(context: Context): Map<String, Any> {
            val snapshot = PlaylistStore(context).snapshot()
            val index = if (isRunning) activeIndex else snapshot.currentIndex
            return mapOf(
                "entries" to snapshot.entries.map(PlaylistEntry::toMap),
                "currentIndex" to index,
                "repeatOne" to snapshot.repeatOne,
                "repeatPlaylist" to snapshot.repeatPlaylist,
                "isPlaying" to (isRunning && !isPaused),
                "isPaused" to (isRunning && isPaused),
                "status" to statusMessage,
            )
        }
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
    private var audioFocusRequest: AudioFocusRequest? = null
    @Volatile private var moduleName = "MOD player"

    override fun onCreate() {
        super.onCreate()
        playlistStore = PlaylistStore(this)
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
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        isRunning = false
        isPaused = false
        synchronized(stateLock) { stateLock.notifyAll() }
        playbackThread?.takeIf { it !== Thread.currentThread() }?.join(2000)
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
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
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
            track = createAudioTrack().also { audioTrack = it }
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
                    val pcm = NativeOpenMpt.nativeRenderPcm(RENDER_CHUNK_FRAMES, SAMPLE_RATE)
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
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
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
            if (!isRunning) stopSelf()
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
        if (removeNotification) stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun failPlayback(message: String) {
        statusMessage = message
        Log.e(TAG, message)
        isRunning = false
        updatePlaybackState(PlaybackState.STATE_ERROR)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun createAudioTrack(): AudioTrack {
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
            .build()
        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()
        val chunkBytes = RENDER_CHUNK_FRAMES * CHANNEL_COUNT * Short.SIZE_BYTES
        val minBufferBytes = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT,
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
                "AudioTrack ready: chunk=$RENDER_CHUNK_FRAMES frames, " +
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
            .setOngoing(isRunning && !isPaused)
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_previous, "Previous", servicePendingIntent(ACTION_PREVIOUS, 1)).build())
            .addAction(Notification.Action.Builder(toggleIcon, toggleLabel, servicePendingIntent(toggleAction, 2)).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_media_next, "Next", servicePendingIntent(ACTION_NEXT, 3)).build())
            .addAction(Notification.Action.Builder(android.R.drawable.ic_menu_close_clear_cancel, "Stop", servicePendingIntent(ACTION_STOP, 4)).build())
            .setStyle(Notification.MediaStyle().setMediaSession(mediaSession.sessionToken).setShowActionsInCompactView(0, 1, 2))
            .build()
    }

    private fun updateNotification(text: String) {
        if (!isRunning) return
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
}
