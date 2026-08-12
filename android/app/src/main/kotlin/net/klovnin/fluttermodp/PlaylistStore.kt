package net.klovnin.fluttermodp

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

data class PlaylistEntry(
    val uri: String,
    val name: String,
) {
    fun toMap(): Map<String, String> = mapOf("uri" to uri, "name" to name)
}

data class PlaylistSnapshot(
    val entries: List<PlaylistEntry>,
    val currentIndex: Int,
    val repeatOne: Boolean,
    val repeatPlaylist: Boolean,
)

/**
 * Persistent, UI-independent playlist state.
 *
 * PlaybackService and any future controller (for example an HTTP server) use
 * this class as their common source of truth. Flutter is only one client.
 */
class PlaylistStore(context: Context) {
    companion object {
        private const val PREFERENCES = "playlist_state"
        private const val KEY_ENTRIES = "entries"
        private const val KEY_CURRENT_INDEX = "current_index"
        private const val KEY_REPEAT_ONE = "repeat_one"
        private const val KEY_REPEAT_PLAYLIST = "repeat_playlist"
        private val lock = Any()
    }

    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES,
        Context.MODE_PRIVATE,
    )

    fun snapshot(): PlaylistSnapshot = synchronized(lock) {
        val entries = readEntries()
        PlaylistSnapshot(
            entries = entries,
            currentIndex = normalizedIndex(
                preferences.getInt(KEY_CURRENT_INDEX, if (entries.isEmpty()) -1 else 0),
                entries.size,
            ),
            repeatOne = preferences.getBoolean(KEY_REPEAT_ONE, false),
            repeatPlaylist = preferences.getBoolean(KEY_REPEAT_PLAYLIST, false),
        )
    }

    fun add(entries: List<PlaylistEntry>): PlaylistSnapshot = synchronized(lock) {
        if (entries.isEmpty()) return@synchronized snapshot()
        val oldEntries = readEntries()
        val currentIndex = normalizedIndex(
            preferences.getInt(KEY_CURRENT_INDEX, if (oldEntries.isEmpty()) -1 else 0),
            oldEntries.size,
        )
        writeEntries(oldEntries + entries)
        if (currentIndex < 0) preferences.edit().putInt(KEY_CURRENT_INDEX, 0).apply()
        snapshot()
    }

    fun replace(entries: List<PlaylistEntry>): PlaylistSnapshot = synchronized(lock) {
        writeEntries(entries)
        preferences.edit().putInt(KEY_CURRENT_INDEX, if (entries.isEmpty()) -1 else 0).apply()
        snapshot()
    }

    fun remove(index: Int): PlaylistSnapshot = synchronized(lock) {
        val entries = readEntries().toMutableList()
        if (index !in entries.indices) return@synchronized snapshot()
        val oldCurrent = normalizedIndex(
            preferences.getInt(KEY_CURRENT_INDEX, if (entries.isEmpty()) -1 else 0),
            entries.size,
        )
        entries.removeAt(index)
        val newCurrent = when {
            entries.isEmpty() -> -1
            index < oldCurrent -> oldCurrent - 1
            oldCurrent >= entries.size -> entries.lastIndex
            else -> oldCurrent
        }
        writeEntries(entries)
        preferences.edit().putInt(KEY_CURRENT_INDEX, newCurrent).apply()
        snapshot()
    }

    fun clear(): PlaylistSnapshot = replace(emptyList())

    fun setCurrentIndex(index: Int): PlaylistSnapshot = synchronized(lock) {
        val entries = readEntries()
        val normalized = if (index in entries.indices) index else normalizedIndex(index, entries.size)
        preferences.edit().putInt(KEY_CURRENT_INDEX, normalized).apply()
        snapshot()
    }

    fun setRepeatOne(enabled: Boolean): PlaylistSnapshot = synchronized(lock) {
        preferences.edit().putBoolean(KEY_REPEAT_ONE, enabled).apply()
        snapshot()
    }

    fun setRepeatPlaylist(enabled: Boolean): PlaylistSnapshot = synchronized(lock) {
        preferences.edit().putBoolean(KEY_REPEAT_PLAYLIST, enabled).apply()
        snapshot()
    }

    private fun readEntries(): List<PlaylistEntry> {
        val serialized = preferences.getString(KEY_ENTRIES, "[]") ?: "[]"
        return try {
            val array = JSONArray(serialized)
            buildList {
                for (index in 0 until array.length()) {
                    val item = array.optJSONObject(index) ?: continue
                    val uri = item.optString("uri")
                    if (uri.isBlank()) continue
                    add(PlaylistEntry(uri, item.optString("name", uri.substringAfterLast('/'))))
                }
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun writeEntries(entries: List<PlaylistEntry>) {
        val array = JSONArray()
        entries.forEach { entry ->
            array.put(JSONObject().put("uri", entry.uri).put("name", entry.name))
        }
        preferences.edit().putString(KEY_ENTRIES, array.toString()).apply()
    }

    private fun normalizedIndex(index: Int, size: Int): Int = when {
        size == 0 -> -1
        index < 0 -> 0
        index >= size -> size - 1
        else -> index
    }
}
