package com.enve.app.playback

import android.content.Context
import android.util.AtomicFile
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudiobookBookmark
import com.enve.core.data.model.Book
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlayerBookmarkService(locations: ProfileStorageLocations) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
    )

    private val profileId = locations.profileId
    private val mutex = Mutex()
    private val bookmarksDirectory = File(locations.filesDirectory, "audiobook-bookmarks")

    init {
        if (locations.profileId != DEFAULT_ADULT_PROFILE_ID) {
            check(bookmarksDirectory.isDirectory || bookmarksDirectory.mkdirs())
        }
    }

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Serializable
    private data class BookmarkPayload(val bookmarks: List<AudiobookBookmark> = emptyList())

    suspend fun loadBookmarks(book: Book): List<AudiobookBookmark> = mutex.withLock { readBookmarks(book.id) }

    suspend fun addBookmark(
        book: Book,
        position: Long,
        title: String?,
        note: String?,
        chapterTitle: String?,
    ): AudiobookBookmark {
        val bookmark = AudiobookBookmark(
            bookId = book.id,
            position = position.coerceAtLeast(0),
            title = buildTitle(
                requestedTitle = title,
                mediaType = book.mediaType,
                position = position,
                chapterTitle = chapterTitle,
            ),
            note = note?.takeIf { it.isNotBlank() },
            mediaType = book.mediaType,
            chapterTitle = chapterTitle?.takeIf { it.isNotBlank() },
        )
        upsertLocal(book.id, bookmark)
        return bookmark
    }

    suspend fun updateBookmark(book: Book, bookmark: AudiobookBookmark, title: String, note: String?): AudiobookBookmark {
        val updated = bookmark.copy(
            title = title.ifBlank { bookmark.title },
            note = note?.takeIf { it.isNotBlank() },
        )
        upsertLocal(book.id, updated)
        return updated
    }

    suspend fun deleteBookmark(book: Book, bookmark: AudiobookBookmark) = mutex.withLock {
        val remaining = readBookmarks(book.id).filterNot { it.id == bookmark.id }
        writeBookmarks(book.id, remaining)
    }

    fun buildTitle(
        requestedTitle: String?,
        mediaType: AppMediaType,
        position: Long,
        chapterTitle: String?,
    ): String {
        if (!requestedTitle.isNullOrBlank()) return requestedTitle.trim()
        if (mediaType == AppMediaType.EBOOK) {
            return chapterTitle?.takeIf { it.isNotBlank() } ?: "Bookmark at ${(position * 100).toInt()}%"
        }
        if (!chapterTitle.isNullOrBlank()) return "Bookmark: $chapterTitle"
        return "Bookmark at ${AudiobookBookmark.formatTime(position)}"
    }

    private suspend fun upsertLocal(bookId: String, bookmark: AudiobookBookmark) = mutex.withLock {
        val updated = readBookmarks(bookId).toMutableList()
        val index = updated.indexOfFirst { it.id == bookmark.id }
        if (index >= 0) updated[index] = bookmark else updated.add(bookmark)
        writeBookmarks(bookId, updated)
    }

    private suspend fun readBookmarks(bookId: String): List<AudiobookBookmark> = withContext(Dispatchers.IO) {
        try {
            val file = bookmarkFile(bookId)
            if (!file.exists() && !File("${file.path}.bak").exists()) return@withContext emptyList()
            val stored = AtomicFile(file).openRead().bufferedReader().use { it.readText() }
            json.decodeFromString<BookmarkPayload>(stored).bookmarks
        } catch (error: Exception) {
            if (error is CancellationException || profileId != DEFAULT_ADULT_PROFILE_ID) throw error
            emptyList()
        }
    }

    private suspend fun writeBookmarks(bookId: String, bookmarks: List<AudiobookBookmark>) = withContext(Dispatchers.IO) {
        val ordered = bookmarks.sortedBy { it.timestamp }
        val target = bookmarkFile(bookId)
        val directory = checkNotNull(target.parentFile)
        check(directory.isDirectory || directory.mkdirs())
        val bytes = json.encodeToString(BookmarkPayload(ordered)).toByteArray(Charsets.UTF_8)
        val file = AtomicFile(target)
        val output = file.startWrite()
        try {
            output.write(bytes)
            file.finishWrite(output)
        } catch (error: Throwable) {
            file.failWrite(output)
            throw error
        }
    }

    private fun bookmarkFile(bookId: String): File {
        val safeBookId = bookId.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(bookmarksDirectory, "$safeBookId.json")
    }
}
