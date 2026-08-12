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
        private const val RENDER_CHUNK_FRAMES = 8192

        const val ACTION_START = "net.klovnin.fluttermodp.action.START"
        const val ACTION_PLAY = "net.klovnin.fluttermodp.action.PLAY"
        const val ACTION_PAUSE = "net.klovnin.fluttermodp.action.PAUSE"
        const val ACTION_STOP = "net.klovnin.fluttermodp.action.STOP"
        const val ACTION_SEEK = "net.klovnin.fluttermodp.action.SEEK"
        const val EXTRA_POSITION_MS = "position_ms"
        const val EXTRA_URI = "module_uri"
        const val EXTRA_NAME = "module_name"

        @Volatile
        var statusMessage: String = "Playback service has not started."
            private set

        fun intent(context: Context, action: String): Intent =
            Intent(context, PlaybackService::class.java).setAction(action)
    }

    private val stateLock = Object()
    private val pendingSeekMs = AtomicLong(-1L)

    @Volatile private var running = false
    @Volatile private var paused = false
    @Volatile private var prepared = false
    @Volatile private var resumeOnFocusGain = false

    private var playbackThread: Thread? = null
    private var audioTrack: AudioTrack? = null
    private lateinit var audioManager: AudioManager
    private lateinit var mediaSession: MediaSession
    private var audioFocusRequest: AudioFocusRequest? = null
    @Volatile private var moduleName = "selected module"
    @Volatile private var moduleUri: String? = null

    override fun onCreate() {
        super.onCreate()
        audioManager = getSystemService(AudioManager::class.java)
        createNotificationChannel()
        createMediaSession()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action ?: ACTION_START) {
            ACTION_START -> {
                moduleUri = intent?.getStringExtra(EXTRA_URI)
                moduleName = intent?.getStringExtra(EXTRA_NAME) ?: "selected module"
                startPlayback()
            }
            ACTION_PLAY -> resumePlayback()
            ACTION_PAUSE -> if (running) pausePlayback() else stopSelf()
            ACTION_STOP -> stopPlayback(removeNotification = true)
            ACTION_SEEK -> {
                val positionMs = intent?.getLongExtra(EXTRA_POSITION_MS, -1L) ?: -1L
                if (running && positionMs >= 0L) {
                    pendingSeekMs.set(positionMs)
                    synchronized(stateLock) { stateLock.notifyAll() }
                } else if (!running) {
                    stopSelf()
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        stopPlayback(removeNotification = true)
        playbackThread?.takeIf { it !== Thread.currentThread() }?.join(2000)
        mediaSession.release()
        super.onDestroy()
    }

    private fun startPlayback() {
        if (running) {
            resumePlayback()
            return
        }

        // Android requires startForeground() promptly after startForegroundService().
        startForeground(NOTIFICATION_ID, buildNotification("Preparing cavern.mod…"))

        val loadError = NativeOpenMpt.loadError
        if (loadError != null) {
            failPlayback("Could not load native libraries: $loadError")
            return
        }
        if (!requestAudioFocus()) {
            failPlayback("Could not obtain audio focus.")
            return
        }

        running = true
        paused = false
        prepared = false
        playbackThread = thread(
            start = true,
            isDaemon = false,
            name = "OpenMptPlaybackThread",
            priority = Thread.MAX_PRIORITY,
        ) {
            playbackLoop()
        }
    }

    private fun playbackLoop() {
        android.os.Process.setThreadPriority(android.os.Process.THREAD_PRIORITY_AUDIO)
        try {
            val uri = moduleUri ?: throw IllegalStateException("再生するファイルが指定されていません。")
            val moduleData = contentResolver.openInputStream(android.net.Uri.parse(uri))?.use {
                it.readBytes()
            } ?: throw IllegalStateException("ファイルを読み込めませんでした。")
            if (!NativeOpenMpt.nativeInitializeModule(moduleData)) {
                throw IllegalStateException(NativeOpenMpt.nativeGetLastMessage())
            }

            val track = createAudioTrack()
            audioTrack = track
            prepared = true
            statusMessage = NativeOpenMpt.nativeGetLastMessage()
            updateMetadata()
            updatePlaybackState(PlaybackState.STATE_PLAYING)
            updateNotification(statusMessage)
            track.play()

            var chunksSinceStateUpdate = 0
            while (running) {
                waitUntilPlayableOrSeekable()
                if (!running) break

                applyPendingSeek(track)
                if (paused) continue
                val pcm = NativeOpenMpt.nativeRenderPcm(
                    RENDER_CHUNK_FRAMES,
                    SAMPLE_RATE,
                )
                if (pcm.isEmpty()) {
                    statusMessage = "Playback finished."
                    break
                }
                writeFully(track, pcm)
                chunksSinceStateUpdate++
                if (chunksSinceStateUpdate >= 6) {
                    chunksSinceStateUpdate = 0
                    updatePlaybackState(PlaybackState.STATE_PLAYING)
                }
            }
        } catch (error: Throwable) {
            statusMessage = "Playback failed: ${error.message ?: error.javaClass.simpleName}"
            Log.e(TAG, statusMessage, error)
        } finally {
            running = false
            paused = false
            prepared = false
            audioTrack?.let { track ->
                try {
                    track.pause()
                    track.flush()
                    track.stop()
                } catch (_: IllegalStateException) {
                    // The track may already have been stopped by stopPlayback().
                }
                track.release()
            }
            audioTrack = null
            NativeOpenMpt.nativeDestroyModule()
            abandonAudioFocus()
            updatePlaybackState(PlaybackState.STATE_STOPPED)
            mediaSession.isActive = false
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun waitUntilPlayableOrSeekable() {
        synchronized(stateLock) {
            while (running && paused && pendingSeekMs.get() < 0L) {
                stateLock.wait()
            }
        }
    }

    private fun applyPendingSeek(track: AudioTrack) {
        val positionMs = pendingSeekMs.getAndSet(-1L)
        if (positionMs < 0L) return

        track.pause()
        track.flush()
        val actualSeconds = NativeOpenMpt.nativeSeekToSeconds(positionMs / 1000.0)
        statusMessage = "Seeked to ${"%.2f".format(actualSeconds)} sec."
        if (!paused && running) track.play()
        updatePlaybackState(
            if (paused) PlaybackState.STATE_PAUSED else PlaybackState.STATE_PLAYING,
        )
    }

    private fun writeFully(track: AudioTrack, pcm: ByteArray) {
        var offset = 0
        while (running && offset < pcm.size) {
            val written = track.write(
                pcm,
                offset,
                pcm.size - offset,
                AudioTrack.WRITE_BLOCKING,
            )
            if (written < 0) {
                throw IllegalStateException("AudioTrack.write failed with $written")
            }
            if (written == 0) break
            offset += written
        }
    }

    private fun pausePlayback() {
        if (!running || paused) return
        resumeOnFocusGain = false
        paused = true
        audioTrack?.pause()
        statusMessage = "Playback paused."
        updatePlaybackState(PlaybackState.STATE_PAUSED)
        updateNotification(statusMessage)
    }

    private fun resumePlayback() {
        if (!running) {
            startPlayback()
            return
        }
        if (!requestAudioFocus()) return
        paused = false
        if (prepared) audioTrack?.play()
        synchronized(stateLock) { stateLock.notifyAll() }
        statusMessage = "Playback running in background."
        mediaSession.isActive = true
        updatePlaybackState(PlaybackState.STATE_PLAYING)
        updateNotification(statusMessage)
    }

    private fun stopPlayback(removeNotification: Boolean) {
        running = false
        paused = false
        synchronized(stateLock) { stateLock.notifyAll() }
        audioTrack?.let { track ->
            try {
                track.pause()
                track.flush()
                track.stop()
            } catch (_: IllegalStateException) {
                // Ignore stop races with playbackLoop cleanup.
            }
        }
        statusMessage = "Playback stopped."
        updatePlaybackState(PlaybackState.STATE_STOPPED)
        if (removeNotification) stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun failPlayback(message: String) {
        statusMessage = message
        Log.e(TAG, message)
        running = false
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
        return AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(max(minBufferBytes, chunkBytes * 2))
            .build()
            .also {
                check(it.state == AudioTrack.STATE_INITIALIZED) {
                    "AudioTrack initialization failed."
                }
            }
    }

    private fun createMediaSession() {
        mediaSession = MediaSession(this, "FlutterModpSession").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() = resumePlayback()
                override fun onPause() = pausePlayback()
                override fun onStop() = stopPlayback(removeNotification = true)
                override fun onSeekTo(pos: Long) {
                    pendingSeekMs.set(pos.coerceAtLeast(0L))
                    synchronized(stateLock) { stateLock.notifyAll() }
                }
            })
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS,
            )
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
        } else {
            0L
        }
        mediaSession.setPlaybackState(
            PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_STOP or
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
        val toggleAction = if (paused) ACTION_PLAY else ACTION_PAUSE
        val toggleIcon = if (paused) android.R.drawable.ic_media_play else android.R.drawable.ic_media_pause
        val toggleLabel = if (paused) "Play" else "Pause"

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(moduleName)
            .setContentText(text)
            .setContentIntent(contentIntent)
            .setCategory(Notification.CATEGORY_TRANSPORT)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setOngoing(running && !paused)
            .addAction(
                Notification.Action.Builder(
                    toggleIcon,
                    toggleLabel,
                    servicePendingIntent(toggleAction, 1),
                ).build(),
            )
            .addAction(
                Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Stop",
                    servicePendingIntent(ACTION_STOP, 2),
                ).build(),
            )
            .setStyle(
                Notification.MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1),
            )
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java)
            .notify(NOTIFICATION_ID, buildNotification(text))
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
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "MOD playback",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Background module music playback"
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        when (change) {
            AudioManager.AUDIOFOCUS_GAIN -> {
                if (resumeOnFocusGain) {
                    resumeOnFocusGain = false
                    resumePlayback()
                }
            }
            AudioManager.AUDIOFOCUS_LOSS -> stopPlayback(removeNotification = true)
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK,
            -> {
                resumeOnFocusGain = running && !paused
                if (resumeOnFocusGain) {
                    paused = true
                    audioTrack?.pause()
                    updatePlaybackState(PlaybackState.STATE_PAUSED)
                    updateNotification("Playback paused for audio focus.")
                }
            }
        }
    }

    private fun requestAudioFocus(): Boolean {
        val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = audioFocusRequest ?: AudioFocusRequest.Builder(
                AudioManager.AUDIOFOCUS_GAIN,
            )
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
            audioManager.requestAudioFocus(
                focusChangeListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN,
            )
        }
        return result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    private fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            audioFocusRequest?.let(audioManager::abandonAudioFocusRequest)
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusChangeListener)
        }
    }
}
