package net.klovnin.fluttermodp

object NativeOpenMpt {
    // Values mirror the render-param indices defined in libopenmpt.h.
    const val RENDER_PARAM_INTERPOLATION_FILTER_LENGTH = 3
    const val RENDER_PARAM_VOLUME_RAMPING_STRENGTH = 4

    val loadError: String? = try {
        System.loadLibrary("openmpt_bridge")
        null
    } catch (error: UnsatisfiedLinkError) {
        error.message ?: "Unknown native library loading error"
    }

    external fun nativeInitializeModule(moduleData: ByteArray): Boolean
    external fun nativeSetRepeatCount(repeatCount: Int)
    external fun nativeGetLastMessage(): String
    external fun nativeRenderPcm(frameCount: Int, sampleRate: Int, floatOutput: Boolean): ByteArray
    external fun nativeSeekToSeconds(seconds: Double): Double
    external fun nativeGetPositionSeconds(): Double
    external fun nativeGetDurationSeconds(): Double
    external fun nativeDestroyModule()

    external fun nativeSetRenderParam(param: Int, value: Int): Boolean
    external fun nativeSetCtlBoolean(ctl: String, value: Boolean): Boolean
    external fun nativeSetCtlInteger(ctl: String, value: Long): Boolean
    external fun nativeSetCtlFloatingPoint(ctl: String, value: Double): Boolean
    external fun nativeSetCtlText(ctl: String, value: String): Boolean

    /**
     * Applies every module-scoped render/CTL setting to the currently loaded
     * module. No-op when nothing is loaded yet: the playback loop calls this
     * again right after [nativeInitializeModule].
     *
     * Sample rate and output format are intentionally handled separately in
     * [PlaybackService] because those are properties of the Android AudioTrack
     * rather than the module renderer.
     */
    fun applyModuleSettings(settings: RenderSettings) {
        nativeSetRenderParam(
            RENDER_PARAM_INTERPOLATION_FILTER_LENGTH,
            settings.interpolationFilterLength,
        )
        nativeSetRenderParam(
            RENDER_PARAM_VOLUME_RAMPING_STRENGTH,
            settings.volumeRampingStrength,
        )
        nativeSetCtlFloatingPoint("play.tempo_factor", settings.tempoFactor)
        nativeSetCtlFloatingPoint("play.pitch_factor", settings.pitchFactor)
        nativeSetCtlText("play.at_end", settings.playAtEnd)
        nativeSetCtlFloatingPoint("render.opl.volume_factor", settings.oplVolumeFactor)
        nativeSetCtlBoolean("render.resampler.emulate_amiga", settings.emulateAmiga)
        nativeSetCtlText("render.resampler.emulate_amiga_type", settings.emulateAmigaType)
        nativeSetCtlInteger("dither", settings.dither.toLong())
    }
}
