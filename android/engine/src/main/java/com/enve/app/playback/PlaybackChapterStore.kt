package com.enve.app.playback

import com.enve.core.data.model.Chapter
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlaybackChapterStore @Inject constructor() {

    data class Snapshot(
        val cacheKey: String? = null,
        val bookId: String? = null,
        val chapters: List<Chapter> = emptyList(),
        val title: String? = null,
        val author: String? = null,
        val coverUrl: String? = null,
    ) {
        fun chapterIndexAt(positionSec: Long): Int {
            if (chapters.isEmpty()) return -1
            return chapters.indexOfLast { positionSec >= it.startTime }.takeIf { it >= 0 } ?: 0
        }

        fun usesMediaItemIndexes(mediaItemCount: Int): Boolean =
            chapters.size > 1 &&
                chapters.size == mediaItemCount &&
                chapters.zipWithNext().any { (current, next) -> next.startTime <= current.startTime }

        fun previousChapterStart(positionSec: Long): Long? {
            if (chapters.isEmpty()) return null
            val current = chapterIndexAt(positionSec)
            if (current < 0) return null
            val currentStart = chapters[current].startTime
            if (positionSec - currentStart > 3) return currentStart
            val prev = (current - 1).takeIf { it >= 0 } ?: return currentStart
            return chapters[prev].startTime
        }

        fun nextChapterStart(positionSec: Long): Long? {
            if (chapters.isEmpty()) return null
            val current = chapterIndexAt(positionSec)
            val next = current + 1
            if (next < 0 || next >= chapters.size) return null
            return chapters[next].startTime
        }
    }

    private val _snapshot = MutableStateFlow(Snapshot())
    val snapshot: StateFlow<Snapshot> = _snapshot.asStateFlow()

    fun set(
        cacheKey: String,
        bookId: String,
        chapters: List<Chapter>,
        title: String?,
        author: String?,
        coverUrl: String?,
    ) {
        _snapshot.value = Snapshot(
            cacheKey = cacheKey,
            bookId = bookId,
            chapters = chapters,
            title = title,
            author = author,
            coverUrl = coverUrl,
        )
    }

    fun clear() {
        _snapshot.value = Snapshot()
    }

    fun previousChapterStart(positionSec: Long): Long? = _snapshot.value.previousChapterStart(positionSec)

    fun nextChapterStart(positionSec: Long): Long? = _snapshot.value.nextChapterStart(positionSec)
}
