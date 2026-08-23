package com.enve.app.playback

import android.content.Context
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudiobookBookmark
import com.enve.core.data.model.Book
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlayerBookmarkService @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Serializable
    private data class BookmarkPayload(val bookmarks: List<AudiobookBookmark> = emptyList())

    suspend fun loadBookmarks(book: Book): List<AudiobookBookmark> = readBookmarks(book.id)

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

    suspend fun deleteBookmark(book: Book, bookmark: AudiobookBookmark) {
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

    private suspend fun upsertLocal(bookId: String, bookmark: AudiobookBookmark) {
        val updated = readBookmarks(bookId).toMutableList()
        val index = updated.indexOfFirst { it.id == bookmark.id }
        if (index >= 0) updated[index] = bookmark else updated.add(bookmark)
        writeBookmarks(bookId, updated)
    }

    private suspend fun readBookmarks(bookId: String): List<AudiobookBookmark> = withContext(Dispatchers.IO) {
        runCatching {
            val file = bookmarkFile(bookId)
            if (!file.exists() || file.length() == 0L) return@runCatching emptyList()
            json.decodeFromString<BookmarkPayload>(file.readText()).bookmarks
        }.getOrDefault(emptyList())
    }

    private suspend fun writeBookmarks(bookId: String, bookmarks: List<AudiobookBookmark>) = withContext(Dispatchers.IO) {
        val ordered = bookmarks.sortedBy { it.timestamp }
        val target = bookmarkFile(bookId)
        target.parentFile?.mkdirs()
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeText(json.encodeToString(BookmarkPayload(ordered)))
        if (!tmp.renameTo(target)) {
            target.writeText(tmp.readText())
            tmp.delete()
        }
    }

    private fun bookmarkFile(bookId: String): File {
        val safeBookId = bookId.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(context.filesDir, "audiobook-bookmarks/$safeBookId.json")
    }
}
