package com.enve.app.playback

import com.enve.core.data.model.Chapter
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlayerChapterService @Inject constructor() {

    fun resolveCurrentChapterIndex(chapters: List<Chapter>, currentTimeSec: Long): Int {
        if (chapters.isEmpty()) return 0
        val index = chapters.indexOfLast { it.startTime <= currentTimeSec }
        return if (index >= 0) index else 0
    }

    fun nextChapterStart(chapters: List<Chapter>, currentIndex: Int): Long? {
        if (currentIndex < 0 || currentIndex >= chapters.lastIndex) return null
        return chapters[currentIndex + 1].startTime
    }

    fun previousChapterStart(chapters: List<Chapter>, currentIndex: Int, currentTimeSec: Long): Long? {
        val current = chapters.getOrNull(currentIndex) ?: return null
        return if (currentTimeSec - current.startTime > 3L) {
            current.startTime
        } else {
            chapters.getOrNull(currentIndex - 1)?.startTime
        }
    }
}
