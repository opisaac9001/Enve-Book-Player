package com.enve.app.playback

import com.enve.core.data.local.PreferencesManager
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

@EntryPoint
@InstallIn(SingletonComponent::class)
interface AndroidAutoDebugEntryPoint {
    fun audioPlaybackManager(): AudioPlaybackManager
    fun chapterStore(): PlaybackChapterStore
    fun preferencesManager(): PreferencesManager
}
