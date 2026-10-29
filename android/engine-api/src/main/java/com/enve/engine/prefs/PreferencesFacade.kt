package com.enve.engine.prefs

import com.enve.engine.theme.HearthPaletteStyle
import com.enve.engine.theme.HearthThemeMode
import com.enve.core.data.model.ComicPageLoadingMode
import kotlinx.coroutines.flow.Flow

enum class HearthStartTab(val label: String) {
    HEARTH("Hearth"),
    LIBRARY("Library"),
    PODCASTS("Podcasts"),
    JOURNAL("Journal"),
}

enum class HearthHomeSection(val label: String) {
    CONTINUE_READING("Continue reading"),
    CONTINUE_LISTENING("Continue listening"),
    RECENTLY_ADDED("Recently Added"),
    DOWNLOADED("On this device"),
    DOORWAYS("Doorways"),
}

enum class ReadNextPosition(val label: String) {
    TOP("Top"),
    BOTTOM("Bottom"),
}

enum class EbookSyncInterval(val label: String, val milliseconds: Long) {
    AUTOMATIC("Automatic", 0L),
    THIRTY_SECONDS("30 seconds", 30_000L),
    ONE_MINUTE("1 minute", 60_000L),
    FIVE_MINUTES("5 minutes", 300_000L),
    TWELVE_MINUTES("12 minutes", 720_000L),
}

interface PreferencesFacade {
    val themeMode: Flow<HearthThemeMode>
    val oledEnabled: Flow<Boolean>
    val paletteStyle: Flow<HearthPaletteStyle>
    val uiTextScale: Flow<Float>

    val reduceMotion: Flow<Boolean>
    val accentHex: Flow<String>
    val skipForwardSeconds: Flow<Int>
    val skipBackwardSeconds: Flow<Int>
    val defaultSpeed: Flow<Float>

    val scrubScopeChapter: Flow<Boolean>
    val readNextEnabled: Flow<Boolean>
    val readNextPosition: Flow<ReadNextPosition>
    val restReminderEnabled: Flow<Boolean>
    val restReminderMinutes: Flow<Int>
    val restReminderIntroShown: Flow<Boolean>

    val libraryColumns: Flow<Int>

    val librarySortStack: Flow<String>

    val libraryAdvancedFilters: Flow<String>
    val excludedLibraryIds: Flow<Set<String>>
    val comicPageLoadingMode: Flow<ComicPageLoadingMode>
    val preferredStartTab: Flow<HearthStartTab>
    val homeSectionOrder: Flow<List<HearthHomeSection>>
    val showDockBookShortcut: Flow<Boolean>
    val showTodayStack: Flow<Boolean>
    val ebookSyncInterval: Flow<EbookSyncInterval>

    suspend fun setThemeMode(mode: HearthThemeMode)
    suspend fun setOledEnabled(enabled: Boolean)
    suspend fun setPaletteStyle(style: HearthPaletteStyle)
    suspend fun setUiTextScale(scale: Float)
    suspend fun setAccentHex(hex: String)
    suspend fun setSkipForwardSeconds(seconds: Int)
    suspend fun setSkipBackwardSeconds(seconds: Int)
    suspend fun setDefaultSpeed(speed: Float)
    suspend fun setScrubScopeChapter(chapter: Boolean)
    suspend fun setReadNextEnabled(enabled: Boolean)
    suspend fun setReadNextPosition(position: ReadNextPosition)
    suspend fun setRestReminderEnabled(enabled: Boolean)
    suspend fun setRestReminderMinutes(minutes: Int)
    suspend fun setRestReminderIntroShown(shown: Boolean)
    suspend fun setLibraryColumns(columns: Int)
    suspend fun setLibrarySortStack(encoded: String)
    suspend fun setLibraryAdvancedFilters(encoded: String)
    suspend fun setComicPageLoadingMode(mode: ComicPageLoadingMode)
    suspend fun setPreferredStartTab(tab: HearthStartTab)
    suspend fun setHomeSectionOrder(order: List<HearthHomeSection>)
    suspend fun setShowDockBookShortcut(show: Boolean)
    suspend fun setShowTodayStack(show: Boolean)
    suspend fun setEbookSyncInterval(interval: EbookSyncInterval)
}
