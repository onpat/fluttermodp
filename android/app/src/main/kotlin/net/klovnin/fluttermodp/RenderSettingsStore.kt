package net.klovnin.fluttermodp

import android.content.Context

/**
 * User-configurable libopenmpt render settings.
 *
 * The defaults satisfy the product requirement of 48 kHz sampling rate and
 * 16-bit PCM output. Field names match the keys exchanged with Flutter
 * (camelCase), while the backing [RenderSettingsStore] uses snake_case
 * SharedPreferences keys internally.
 */
data class RenderSettings(
    val interpolationFilterLength: Int,
    val sampleRate: Int,
    val floatOutput: Boolean,
    val volumeRampingStrength: Int,
    val tempoFactor: Double,
    val pitchFactor: Double,
    val playAtEnd: String,
    val oplVolumeFactor: Double,
    val emulateAmiga: Boolean,
    val emulateAmigaType: String,
    val dither: Int,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "interpolationFilterLength" to interpolationFilterLength,
        "sampleRate" to sampleRate,
        "floatOutput" to floatOutput,
        "volumeRampingStrength" to volumeRampingStrength,
        "tempoFactor" to tempoFactor,
        "pitchFactor" to pitchFactor,
        "playAtEnd" to playAtEnd,
        "oplVolumeFactor" to oplVolumeFactor,
        "emulateAmiga" to emulateAmiga,
        "emulateAmigaType" to emulateAmigaType,
        "dither" to dither,
    )

    companion object {
        val DEFAULT = RenderSettings(
            interpolationFilterLength = 0,
            sampleRate = 48000,
            floatOutput = false,
            volumeRampingStrength = -1,
            tempoFactor = 1.0,
            pitchFactor = 1.0,
            playAtEnd = "fadeout",
            oplVolumeFactor = 1.0,
            emulateAmiga = false,
            emulateAmigaType = "auto",
            dither = 1,
        )
    }
}

/**
 * Persistent, UI-independent libopenmpt render settings.
 *
 * Follows the same SharedPreferences-backed pattern as [PlaylistStore] so
 * Flutter remains just one client of the settings state.
 */
class RenderSettingsStore(context: Context) {
    companion object {
        private const val PREFERENCES = "render_settings"
        private const val KEY_INTERPOLATION = "interpolation_filter_length"
        private const val KEY_SAMPLE_RATE = "sample_rate"
        private const val KEY_FLOAT_OUTPUT = "float_output"
        private const val KEY_RAMPING = "volume_ramping_strength"
        private const val KEY_TEMPO = "tempo_factor"
        private const val KEY_PITCH = "pitch_factor"
        private const val KEY_AT_END = "play_at_end"
        private const val KEY_OPL = "opl_volume_factor"
        private const val KEY_AMIGA = "emulate_amiga"
        private const val KEY_AMIGA_TYPE = "emulate_amiga_type"
        private const val KEY_DITHER = "dither"
        private val lock = Any()
    }

    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES,
        Context.MODE_PRIVATE,
    )

    fun snapshot(): RenderSettings = synchronized(lock) {
        val defaults = RenderSettings.DEFAULT
        RenderSettings(
            interpolationFilterLength =
                preferences.getInt(KEY_INTERPOLATION, defaults.interpolationFilterLength),
            sampleRate = preferences.getInt(KEY_SAMPLE_RATE, defaults.sampleRate),
            floatOutput = preferences.getBoolean(KEY_FLOAT_OUTPUT, defaults.floatOutput),
            volumeRampingStrength =
                preferences.getInt(KEY_RAMPING, defaults.volumeRampingStrength),
            tempoFactor = preferences.getFloat(KEY_TEMPO, defaults.tempoFactor.toFloat()).toDouble(),
            pitchFactor = preferences.getFloat(KEY_PITCH, defaults.pitchFactor.toFloat()).toDouble(),
            playAtEnd = preferences.getString(KEY_AT_END, defaults.playAtEnd)
                ?: defaults.playAtEnd,
            oplVolumeFactor =
                preferences.getFloat(KEY_OPL, defaults.oplVolumeFactor.toFloat()).toDouble(),
            emulateAmiga = preferences.getBoolean(KEY_AMIGA, defaults.emulateAmiga),
            emulateAmigaType = preferences.getString(KEY_AMIGA_TYPE, defaults.emulateAmigaType)
                ?: defaults.emulateAmigaType,
            dither = preferences.getInt(KEY_DITHER, defaults.dither),
        )
    }

    /**
     * Applies a partial map of settings (only the keys present in [updates] are
     * written) and returns the resulting full snapshot.
     */
    fun updateFromMap(updates: Map<String, Any?>): RenderSettings = synchronized(lock) {
        val editor = preferences.edit()
        (updates["interpolationFilterLength"] as? Number)?.let {
            editor.putInt(KEY_INTERPOLATION, it.toInt())
        }
        (updates["sampleRate"] as? Number)?.let { editor.putInt(KEY_SAMPLE_RATE, it.toInt()) }
        (updates["floatOutput"] as? Boolean)?.let { editor.putBoolean(KEY_FLOAT_OUTPUT, it) }
        (updates["volumeRampingStrength"] as? Number)?.let {
            editor.putInt(KEY_RAMPING, it.toInt())
        }
        (updates["tempoFactor"] as? Number)?.let { editor.putFloat(KEY_TEMPO, it.toFloat()) }
        (updates["pitchFactor"] as? Number)?.let { editor.putFloat(KEY_PITCH, it.toFloat()) }
        (updates["playAtEnd"] as? String)?.let { editor.putString(KEY_AT_END, it) }
        (updates["oplVolumeFactor"] as? Number)?.let {
            editor.putFloat(KEY_OPL, it.toFloat())
        }
        (updates["emulateAmiga"] as? Boolean)?.let { editor.putBoolean(KEY_AMIGA, it) }
        (updates["emulateAmigaType"] as? String)?.let {
            editor.putString(KEY_AMIGA_TYPE, it)
        }
        (updates["dither"] as? Number)?.let { editor.putInt(KEY_DITHER, it.toInt()) }
        editor.apply()
        snapshot()
    }
}