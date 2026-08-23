package com.enve.engine.playback

import com.enve.core.data.model.AudiobookBookmark
import com.enve.core.data.model.Chapter
import kotlinx.coroutines.flow.StateFlow

interface PlayerSessionFacade {
    val chapters: StateFlow<List<Chapter>>
    val currentChapterIndex: StateFlow<Int>
    val bookmarks: StateFlow<List<AudiobookBookmark>>

    val sleepRemainingSec: StateFlow<Long?>

    fun seekToChapter(chapter: Chapter)
    fun nextChapter()
    fun previousChapter()

    fun addBookmark(note: String? = null)
    fun deleteBookmark(bookmark: AudiobookBookmark)
    fun seekToBookmark(bookmark: AudiobookBookmark)

    fun startSleepTimer(minutes: Int)
    fun startChapterSleepTimer(endPositionSec: Long)
    fun cancelSleepTimer()
}
