package com.enve.core.data.model

import kotlinx.serialization.Serializable

@Serializable
data class Book(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val author: String? = null,
    val narrator: String? = null,
    val description: String? = null,
    val coverUrl: String? = null,
    val duration: Long = 0L,
    val currentTime: Long = 0L,
    val isFinished: Boolean = false,
    val source: BookSource = BookSource.GRIMMORY,
    val mediaType: AppMediaType = AppMediaType.AUDIOBOOK,
    val readStatus: ReadStatus = ReadStatus.UNREAD,

    val seriesName: String? = null,
    val seriesNumber: String? = null,
    val publisher: String? = null,
    val publishedDate: String? = null,
    val isbn13: String? = null,
    val language: String? = null,
    val pageCount: Int? = null,
    val categories: List<String> = emptyList(),
    val personalRating: Float? = null,
    val goodreadsRating: Float? = null,
    val primaryFileType: String? = null,

    val libraryId: String? = null,
    val libraryName: String? = null,
    val connectionId: String? = null,
    val addedOn: Long = 0L,
    val lastReadTime: Long = 0L,
    val readProgress: Float = 0f,

    val chapters: List<Chapter> = emptyList(),
    val audioTracks: List<AudioTrack> = emptyList(),
    val codec: String? = null,
    val bitrate: Int? = null,
    val sampleRate: Int? = null,
    val channels: Int? = null,

    val epubProgress: Float? = null,
    val epubLocator: String? = null,
    val readAlongAvailable: Boolean = false,

    val hasEbook: Boolean = false,

    val hasAudio: Boolean = false,
    val hideFromContinue: Boolean = false,
    val serverReadStatus: String? = null,

    val podcastName: String? = null,

    val isDownloaded: Boolean = false,
    val downloadProgress: Float? = null,

    val shelves: List<String> = emptyList(),
) {

    val uniqueKey: String
        get() = "${connectionId ?: source.name}:$id"

    val progress: Float
        get() = when {
            duration > 0 && currentTime > 0 -> (currentTime.toFloat() / duration).coerceIn(0f, 1f)
            else -> readProgress.coerceIn(0f, 1f)
        }

    val remainingTime: Long
        get() = when {
            duration > 0 && currentTime > 0 -> (duration - currentTime).coerceAtLeast(0)
            duration > 0 && readProgress > 0f -> ((duration * (1f - readProgress.coerceIn(0f, 1f))).toLong()).coerceAtLeast(0)
            else -> 0L
        }

    val displayDuration: String
        get() = formatDuration(duration)

    val displayRemainingTime: String
        get() = when {
            duration > 0L && (currentTime > 0L || readProgress > 0f) -> formatDuration(remainingTime)
            duration > 0L -> formatDuration(duration)
            else -> formatDuration(0L)
        }

    val currentChapter: Chapter?
        get() = chapters.lastOrNull { it.startTime <= currentTime }

    val currentChapterIndex: Int
        get() = chapters.indexOfLast { it.startTime <= currentTime }.coerceAtLeast(0)

    companion object {
        fun formatDuration(seconds: Long): String {
            val hours = seconds / 3600
            val minutes = (seconds % 3600) / 60
            return when {
                hours > 0 -> "${hours}h ${minutes}m"
                else -> "${minutes}m"
            }
        }
    }
}

@Serializable
data class Chapter(
    val index: Int = 0,
    val title: String,
    val startTime: Long,
    val endTime: Long,
) {
    val duration: Long get() = endTime - startTime
}

@Serializable
data class AudioTrack(
    val index: Int,
    val fileName: String,
    val title: String? = null,
    val durationMs: Long,
    val fileSizeBytes: Long = 0,
    val cumulativeStartMs: Long = 0,
    val fileId: String? = null,
    val contentUrl: String? = null,
)

@Serializable
data class LibraryCollection(
    val id: String,
    val name: String,
    val books: List<Book> = emptyList(),
    val bookCount: Int = 0,
    val iconName: String? = null,
    val colorHex: String? = null,
    val isSmart: Boolean = false,
    val isServerCollection: Boolean = false,
)

@Serializable
data class Library(
    val id: String,
    val name: String,
    val bookCount: Int = 0,
    val source: BookSource = BookSource.GRIMMORY,
    val connectionId: String? = null,
)

@Serializable
data class Shelf(
    val id: String,
    val name: String,
    val bookCount: Int = 0,
)

data class ServerConnection(
    val id: String,
    val name: String,
    val url: String,
    val source: BookSource,
    val username: String,
    val isConnected: Boolean = false,
    val lastSync: Long = 0L,
)
