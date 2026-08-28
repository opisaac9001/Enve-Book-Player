package com.enve.engine.prefs

import com.enve.engine.theme.HearthThemeMode
import com.enve.core.data.model.ComicPageLoadingMode
import kotlinx.coroutines.flow.Flow

enum class HearthStartTab(val label: String) {
    HEARTH("Hearth"),
    LIBRARY("Library"),
    JOURNAL("Journal"),
}

enum class HearthHomeSection(val label: String) {
    CONTINUE_READING("Continue reading"),
    CONTINUE_LISTENING("Continue listening"),
    RECENTLY_ADDED("Fresh ink"),
    DOWNLOADED("On this device"),
}

enum class ReadNextPosition(val label: String) {
    TOP("Top"),
    BOTTOM("Bottom"),
}

interface PreferencesFacade {
    val themeMode: Flow<HearthThemeMode>
    val oledEnabled: Flow<Boolean>
    val uiTextScale: Flow<Float>

    val reduceMotion: Flow<Boolean>
    val accentHex: Flow<String>
    val skipForwardSeconds: Flow<Int>
    val skipBackwardSeconds: Flow<Int>
    val defaultSpeed: Flow<Float>

    val scrubScopeChapter: Flow<Boolean>
    val readNextEnabled: Flow<Boolean>
    val readNextPosition: Flow<ReadNextPosition>

    val libraryColumns: Flow<Int>

    val librarySortStack: Flow<String>

    val libraryAdvancedFilters: Flow<String>
    val excludedLibraryIds: Flow<Set<String>>
    val comicPageLoadingMode: Flow<ComicPageLoadingMode>
    val preferredStartTab: Flow<HearthStartTab>
    val homeSectionOrder: Flow<List<HearthHomeSection>>

    suspend fun setThemeMode(mode: HearthThemeMode)
    suspend fun setOledEnabled(enabled: Boolean)
    suspend fun setUiTextScale(scale: Float)
    suspend fun setAccentHex(hex: String)
    suspend fun setSkipForwardSeconds(seconds: Int)
    suspend fun setSkipBackwardSeconds(seconds: Int)
    suspend fun setDefaultSpeed(speed: Float)
    suspend fun setScrubScopeChapter(chapter: Boolean)
    suspend fun setReadNextEnabled(enabled: Boolean)
    suspend fun setReadNextPosition(position: ReadNextPosition)
    suspend fun setLibraryColumns(columns: Int)
    suspend fun setLibrarySortStack(encoded: String)
    suspend fun setLibraryAdvancedFilters(encoded: String)
    suspend fun setComicPageLoadingMode(mode: ComicPageLoadingMode)
    suspend fun setPreferredStartTab(tab: HearthStartTab)
    suspend fun setHomeSectionOrder(order: List<HearthHomeSection>)
}
