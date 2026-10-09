package com.enve.app.widgets

import android.content.Context
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

internal data class BookWidgetSnapshot(
    val profileId: String? = null,
    val generation: Long = 0L,
    val coverIdentity: String? = null,
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
    private val json = Json { ignoreUnknownKeys = true }

    fun save(context: Context, snapshot: BookWidgetSnapshot) {
        val coordinator = coordinator(context)
        if (snapshot.profileId != null && (coordinator.state.value.locked || coordinator.state.value.switching ||
                coordinator.activeRuntime.value?.let { it.profileId == snapshot.profileId && it.generation == snapshot.generation } != true)) return
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("profile", snapshot.profileId)
            .putLong("generation", snapshot.generation)
            .putString("cover_identity", snapshot.coverIdentity)
            .putString("book", snapshot.book?.let { json.encodeToString(it.privateWidgetCopy()) })
            .putString("reader_book", snapshot.readerBook?.let { json.encodeToString(it.privateWidgetCopy()) })
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
        val coordinator = coordinator(context)
        val profileId = prefs.getString("profile", null)
        val generation = prefs.getLong("generation", 0L)
        if (coordinator.state.value.enabled && (coordinator.state.value.locked || coordinator.state.value.switching ||
                coordinator.activeRuntime.value?.let { it.profileId == profileId && it.generation == generation } != true)) return BookWidgetSnapshot()
        fun book(key: String) = prefs.getString(key, null)?.let {
            runCatching { json.decodeFromString<Book>(it) }.getOrNull()
        }
        return BookWidgetSnapshot(
            profileId = profileId, generation = generation, coverIdentity = prefs.getString("cover_identity", null),
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
    private fun coordinator(context: Context) = dagger.hilt.android.EntryPointAccessors.fromApplication(
        context.applicationContext, com.enve.app.profiles.ProfileActivityBinding.DeviceEntryPoint::class.java,
    ).profiles()

    private fun Book.privateWidgetCopy() = copy(
        coverUrl = null, chapters = emptyList(), audioTracks = emptyList(),
        podcastEnclosureUrl = null, opdsAcquisitionUrl = null, opdsProgressionUrl = null,
    )

}
