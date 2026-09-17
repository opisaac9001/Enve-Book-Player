package com.enve.app.widgets

import android.content.Context
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal data class BookWidgetSnapshot(
    val book: Book? = null,
    val readerBook: Book? = null,
    val isPlaying: Boolean = false,
    val hasLiveAudio: Boolean = false,
    val readAlongSessionId: String? = null,
    val progress: Float = 0f,
    val fromQueue: Boolean = false,
    val artworkPath: String? = null,
    val upNext: List<String> = emptyList(),
) {
    val showsAudioControls: Boolean
        get() = hasLiveAudio || book?.let {
            it.supportsListening() && !it.readAlongAvailable && it.mediaType != AppMediaType.EBOOK
        } == true

    val heading: String
        get() = when {
            fromQueue -> "UP NEXT"
            book?.readAlongAvailable == true -> "CONTINUE READ-ALONG"
            book?.mediaType == AppMediaType.EBOOK -> "CONTINUE READING"
            isPlaying -> "NOW LISTENING"
            else -> "CONTINUE LISTENING"
        }
}

internal object BookWidgetStore {
    const val PREFS = "enve_book_widget"
    val json = Json { ignoreUnknownKeys = true }

    fun save(context: Context, snapshot: BookWidgetSnapshot) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("book", snapshot.book?.let { json.encodeToString(it) })
            .putString("reader_book", snapshot.readerBook?.let { json.encodeToString(it) })
            .putBoolean("playing", snapshot.isPlaying)
            .putBoolean("live_audio", snapshot.hasLiveAudio)
            .putString("read_along_session", snapshot.readAlongSessionId)
            .putFloat("progress", snapshot.progress)
            .putBoolean("from_queue", snapshot.fromQueue)
            .putString("artwork", snapshot.artworkPath)
            .putString("shelf", snapshot.upNext.joinToString("\u001E"))
            .apply()
    }

    fun load(context: Context): BookWidgetSnapshot {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        fun book(key: String) = prefs.getString(key, null)?.let {
            runCatching { json.decodeFromString<Book>(it) }.getOrNull()
        }
        return BookWidgetSnapshot(
            book = book("book"), readerBook = book("reader_book"),
            isPlaying = prefs.getBoolean("playing", false),
            hasLiveAudio = prefs.getBoolean("live_audio", false),
            readAlongSessionId = prefs.getString("read_along_session", null),
            progress = prefs.getFloat("progress", 0f),
            fromQueue = prefs.getBoolean("from_queue", false),
            artworkPath = prefs.getString("artwork", null),
            upNext = prefs.getString("shelf", null)?.split('\u001E').orEmpty().filter(String::isNotBlank),
        )
    }
}
