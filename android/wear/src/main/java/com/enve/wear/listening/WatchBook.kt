package com.enve.wear.listening

import kotlinx.serialization.Serializable
import java.security.MessageDigest

@Serializable
data class WatchChapter(val title: String, val startMs: Long, val endMs: Long)

@Serializable
data class WatchTrack(val path: String, val startMs: Long, val durationMs: Long)

@Serializable
data class WatchBook(
    val account: String,
    val id: String,
    val title: String,
    val author: String = "",
    val durationMs: Long = 0,
    val chapters: List<WatchChapter> = emptyList(),
    val tracks: List<WatchTrack> = emptyList(),
    val downloaded: Boolean = false,
) {
    val key: String get() = storageKey("$account/$id")
}

@Serializable
data class WatchPosition(val positionMs: Long = 0, val updatedAt: Long = 0, val bookmarks: List<Long> = emptyList())

@Serializable
data class WatchProgressBaseline(val positionMs: Long, val updatedAt: Long)

@Serializable
data class WatchPendingProgress(
    val account: String,
    val bookId: String,
    val positionMs: Long,
    val updatedAt: Long,
    val baselinePositionMs: Long? = null,
    val baselineUpdatedAt: Long? = null,
)

@Serializable
data class WatchProgressConflict(
    val localPositionMs: Long,
    val localUpdatedAt: Long,
    val remotePositionMs: Long,
    val remoteUpdatedAt: Long,
)

@Serializable
data class WatchLibrary(
    val books: List<WatchBook> = emptyList(),
    val positions: Map<String, WatchPosition> = emptyMap(),
    val progressBaselines: Map<String, WatchProgressBaseline> = emptyMap(),
    val pendingProgress: Map<String, WatchPendingProgress> = emptyMap(),
    val progressConflicts: Map<String, WatchProgressConflict> = emptyMap(),
)

data class TrackPosition(val index: Int, val offsetMs: Long)

fun WatchBook.locate(positionMs: Long): TrackPosition {
    require(tracks.isNotEmpty())
    val position = positionMs.coerceIn(0, durationMs)
    val index = tracks.indexOfLast { it.startMs <= position }.coerceAtLeast(0)
    return TrackPosition(index, (position - tracks[index].startMs).coerceIn(0, tracks[index].durationMs))
}

fun storageKey(value: String): String = MessageDigest.getInstance("SHA-256")
    .digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
