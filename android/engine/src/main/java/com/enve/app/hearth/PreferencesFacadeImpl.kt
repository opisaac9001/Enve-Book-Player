package com.enve.app.hearth

import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.ComicPageLoadingMode
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.prefs.ReadNextPosition
import com.enve.engine.theme.HearthThemeMode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

private const val OLD_DEFAULT_ACCENT = "#EF4444"
private const val EMBER = "#F5921A"

@Singleton
class PreferencesFacadeImpl @Inject constructor(
    private val prefs: PreferencesManager,
    private val hearthPrefs: HearthPreferencesStore,
) : PreferencesFacade {
    override val themeMode: Flow<HearthThemeMode> = hearthPrefs.themeMode
    override val oledEnabled: Flow<Boolean> = hearthPrefs.oledEnabled
    override val uiTextScale: Flow<Float> = hearthPrefs.uiTextScale
    override val reduceMotion: Flow<Boolean> = prefs.dynamicBackgroundEnabled.map { enabled -> !enabled }
    override val accentHex: Flow<String> = prefs.themeColorHex.map {
        if (it.equals(OLD_DEFAULT_ACCENT, ignoreCase = true)) EMBER else it
    }
    override val skipForwardSeconds: Flow<Int> = prefs.skipForwardSeconds
    override val skipBackwardSeconds: Flow<Int> = prefs.skipBackwardSeconds
    override val defaultSpeed: Flow<Float> = prefs.playbackSpeed
    override val scrubScopeChapter: Flow<Boolean> = hearthPrefs.scrubScopeChapter
    override val readNextEnabled: Flow<Boolean> = hearthPrefs.readNextEnabled
    override val readNextPosition: Flow<ReadNextPosition> = hearthPrefs.readNextPosition
    override val libraryColumns: Flow<Int> = hearthPrefs.libraryColumns
    override val librarySortStack: Flow<String> = hearthPrefs.librarySortStack
    override val libraryAdvancedFilters: Flow<String> = hearthPrefs.libraryAdvancedFilters
    override val excludedLibraryIds: Flow<Set<String>> = prefs.excludedLibraryIds
    override val comicPageLoadingMode: Flow<ComicPageLoadingMode> = prefs.comicPageLoadingMode
    override val preferredStartTab: Flow<HearthStartTab> = hearthPrefs.preferredStartTab
    override val homeSectionOrder: Flow<List<HearthHomeSection>> = hearthPrefs.homeSectionOrder

    override suspend fun setThemeMode(mode: HearthThemeMode) {
        hearthPrefs.setThemeMode(mode)
        prefs.setThemeMode(
            when (mode) {
                HearthThemeMode.SYSTEM -> "system"
                HearthThemeMode.INK -> "dark"
                HearthThemeMode.PAPER -> "paper_white"
            },
        )
    }
    override suspend fun setOledEnabled(enabled: Boolean) = hearthPrefs.setOledEnabled(enabled)
    override suspend fun setUiTextScale(scale: Float) = hearthPrefs.setUiTextScale(scale)
    override suspend fun setAccentHex(hex: String) = prefs.setThemeColorHex(hex)
    override suspend fun setSkipForwardSeconds(seconds: Int) = prefs.setSkipForwardSeconds(seconds)
    override suspend fun setSkipBackwardSeconds(seconds: Int) = prefs.setSkipBackwardSeconds(seconds)
    override suspend fun setDefaultSpeed(speed: Float) = prefs.setPlaybackSpeed(speed)
    override suspend fun setScrubScopeChapter(chapter: Boolean) = hearthPrefs.setScrubScopeChapter(chapter)
    override suspend fun setReadNextEnabled(enabled: Boolean) = hearthPrefs.setReadNextEnabled(enabled)
    override suspend fun setReadNextPosition(position: ReadNextPosition) = hearthPrefs.setReadNextPosition(position)
    override suspend fun setLibraryColumns(columns: Int) = hearthPrefs.setLibraryColumns(columns)
    override suspend fun setLibrarySortStack(encoded: String) = hearthPrefs.setLibrarySortStack(encoded)
    override suspend fun setLibraryAdvancedFilters(encoded: String) =
        hearthPrefs.setLibraryAdvancedFilters(encoded)
    override suspend fun setComicPageLoadingMode(mode: ComicPageLoadingMode) =
        prefs.saveComicReaderPreferences(pageLoadingMode = mode)
    override suspend fun setPreferredStartTab(tab: HearthStartTab) =
        hearthPrefs.setPreferredStartTab(tab)
    override suspend fun setHomeSectionOrder(order: List<HearthHomeSection>) =
        hearthPrefs.setHomeSectionOrder(order)
}
