package com.enve.app.hearth

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import com.enve.app.readium.narrator.NarratorPack
import com.enve.core.data.local.ProfilePreferences
import com.enve.engine.theme.HearthPaletteStyle
import com.enve.engine.theme.HearthThemeMode
import com.enve.engine.prefs.EbookSyncInterval
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.prefs.ReadNextPosition
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

private val KEY_THEME_MODE = stringPreferencesKey("hearth.themeMode")
private val KEY_OLED = booleanPreferencesKey("hearth.oled")
private val KEY_PALETTE_STYLE = stringPreferencesKey("hearth.paletteStyle")
private val KEY_UI_TEXT_SCALE = floatPreferencesKey("hearth.uiTextScale")
private val KEY_SCRUB_CHAPTER = booleanPreferencesKey("hearth.player.scrubChapter")
private val KEY_READ_NEXT_ENABLED = booleanPreferencesKey("hearth.reader.readNextEnabled")
private val KEY_READ_NEXT_POSITION = stringPreferencesKey("hearth.reader.readNextPosition")
private val KEY_REST_REMINDER_ENABLED = booleanPreferencesKey("hearth.reader.restReminderEnabled")
private val KEY_REST_REMINDER_MINUTES = intPreferencesKey("hearth.reader.restReminderMinutes")
private val KEY_REST_REMINDER_INTRO_SHOWN = booleanPreferencesKey("hearth.reader.restReminderIntroShown")
private val KEY_LIBRARY_COLUMNS = intPreferencesKey("hearth.library.columns")
private val KEY_LIBRARY_SORT_STACK = stringPreferencesKey("hearth.library.sortStack")
private val KEY_LIBRARY_ADVANCED_FILTERS = stringPreferencesKey("hearth.library.advancedFilters")
private val KEY_LIBRARY_MEDIA = stringPreferencesKey("hearth.library.media")
private val KEY_LIBRARY_STATUS = stringPreferencesKey("hearth.library.status")
private val KEY_READING_ENABLED = booleanPreferencesKey("hearth.library.readingEnabled")
private val KEY_LIBRARY_SELECTION = stringPreferencesKey("hearth.library.selection")
private fun scopedLibraryMediaKey(scope: String) = stringPreferencesKey("hearth.library.media.$scope")
private fun comicBrowseKey(scope: String) = stringPreferencesKey("hearth.library.comics.$scope")
private val KEY_READER_TTS_VOICE = stringPreferencesKey("hearth.reader.ttsVoice")
private val KEY_READER_NARRATOR_PACK = stringPreferencesKey("hearth.reader.narratorPack")
private fun readerNarratorVoiceKey(pack: NarratorPack) = stringPreferencesKey("hearth.reader.narratorVoice.${pack.name}")
private val KEY_START_TAB = stringPreferencesKey("hearth.startTab")
private val KEY_HOME_SECTION_ORDER = stringPreferencesKey("hearth.home.sectionOrder")
private val KEY_HOME_HIDDEN_SECTIONS = stringPreferencesKey("hearth.home.hiddenSections")
private val KEY_SHOW_DOCK_BOOK_SHORTCUT = booleanPreferencesKey("hearth.dock.showBookShortcut")
private val KEY_SHOW_TODAY_STACK = booleanPreferencesKey("hearth.home.showTodayStack")
private val KEY_EBOOK_SYNC_INTERVAL = stringPreferencesKey("hearth.reader.ebookSyncInterval")

@Singleton
class HearthPreferencesStore(
    private val dataStore: DataStore<Preferences>,
) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(ProfilePreferences.owner(context).hearth)

    val themeMode: Flow<HearthThemeMode> = dataStore.data.map { prefs ->
        prefs[KEY_THEME_MODE]?.let { runCatching { HearthThemeMode.valueOf(it) }.getOrNull() }
            ?: HearthThemeMode.SYSTEM
    }

    val oledEnabled: Flow<Boolean> = dataStore.data.map { it[KEY_OLED] ?: false }

    val paletteStyle: Flow<HearthPaletteStyle> = dataStore.data.map { prefs ->
        prefs[KEY_PALETTE_STYLE]?.let { runCatching { HearthPaletteStyle.valueOf(it) }.getOrNull() }
            ?: HearthPaletteStyle.PARCHMENT
    }

    val uiTextScale: Flow<Float> = dataStore.data.map {
        (it[KEY_UI_TEXT_SCALE] ?: 1f).coerceIn(1f, 1.3f)
    }

    val scrubScopeChapter: Flow<Boolean> = dataStore.data.map { it[KEY_SCRUB_CHAPTER] ?: false }
    val readNextEnabled: Flow<Boolean> = dataStore.data.map { it[KEY_READ_NEXT_ENABLED] ?: true }
    val readNextPosition: Flow<ReadNextPosition> = dataStore.data.map { prefs ->
        prefs[KEY_READ_NEXT_POSITION]?.let { runCatching { ReadNextPosition.valueOf(it) }.getOrNull() }
            ?: ReadNextPosition.BOTTOM
    }

    val restReminderEnabled: Flow<Boolean> = dataStore.data.map { it[KEY_REST_REMINDER_ENABLED] ?: true }
    val restReminderMinutes: Flow<Int> =
        dataStore.data.map { (it[KEY_REST_REMINDER_MINUTES] ?: 60).coerceIn(5, 240) }
    val restReminderIntroShown: Flow<Boolean> =
        dataStore.data.map { it[KEY_REST_REMINDER_INTRO_SHOWN] ?: false }

    val libraryColumns: Flow<Int> = dataStore.data.map { (it[KEY_LIBRARY_COLUMNS] ?: 3).coerceIn(1, 4) }

    val librarySortStack: Flow<String> = dataStore.data.map { it[KEY_LIBRARY_SORT_STACK] ?: "" }
    val readerTtsVoice: Flow<String?> = dataStore.data.map { it[KEY_READER_TTS_VOICE] }
    val readerNarratorPack: Flow<NarratorPack?> = dataStore.data.map { prefs ->
        prefs[KEY_READER_NARRATOR_PACK]?.let { runCatching { NarratorPack.valueOf(it) }.getOrNull() }
    }
    fun readerNarratorVoice(pack: NarratorPack): Flow<String?> = dataStore.data.map { prefs ->
        prefs[readerNarratorVoiceKey(pack)]?.takeIf { it in pack.voices }
    }
    val libraryAdvancedFilters: Flow<String> =
        dataStore.data.map { it[KEY_LIBRARY_ADVANCED_FILTERS] ?: "" }
    val libraryMedia: Flow<String> = dataStore.data.map { it[KEY_LIBRARY_MEDIA] ?: "" }
    val libraryStatus: Flow<String> = dataStore.data.map { it[KEY_LIBRARY_STATUS] ?: "" }
    val readingEnabled: Flow<Boolean> = dataStore.data.map { it[KEY_READING_ENABLED] ?: true }
    val librarySelection: Flow<String> = dataStore.data.map { it[KEY_LIBRARY_SELECTION] ?: "" }

    fun scopedLibraryMedia(scope: String): Flow<String> {
        val key = scopedLibraryMediaKey(scope)
        return dataStore.data.map { it[key] ?: "" }
    }

    fun comicBrowseState(scope: String): Flow<String> {
        val key = comicBrowseKey(scope)
        return dataStore.data.map { it[key] ?: "" }
    }

    val preferredStartTab: Flow<HearthStartTab> = dataStore.data.map { prefs ->
        prefs[KEY_START_TAB]?.let { runCatching { HearthStartTab.valueOf(it) }.getOrNull() }
            ?: HearthStartTab.HEARTH
    }
    val homeSectionOrder: Flow<List<HearthHomeSection>> = dataStore.data.map { prefs ->
        val saved = prefs[KEY_HOME_SECTION_ORDER]
            .orEmpty()
            .split(',')
            .mapNotNull { raw -> runCatching { HearthHomeSection.valueOf(raw) }.getOrNull() }
        (saved + HearthHomeSection.entries).distinct()
    }
    val hiddenHomeSections: Flow<Set<HearthHomeSection>> = dataStore.data.map { prefs ->
        prefs[KEY_HOME_HIDDEN_SECTIONS]
            .orEmpty()
            .split(',')
            .mapNotNull { raw -> runCatching { HearthHomeSection.valueOf(raw) }.getOrNull() }
            .toSet()
    }
    val showDockBookShortcut: Flow<Boolean> = dataStore.data.map { it[KEY_SHOW_DOCK_BOOK_SHORTCUT] ?: true }
    val showTodayStack: Flow<Boolean> = dataStore.data.map { it[KEY_SHOW_TODAY_STACK] ?: true }
    val ebookSyncInterval: Flow<EbookSyncInterval> = dataStore.data.map { prefs ->
        prefs[KEY_EBOOK_SYNC_INTERVAL]?.let { runCatching { EbookSyncInterval.valueOf(it) }.getOrNull() }
            ?: EbookSyncInterval.AUTOMATIC
    }

    suspend fun setThemeMode(mode: HearthThemeMode) {
        dataStore.edit { it[KEY_THEME_MODE] = mode.name }
    }

    suspend fun setOledEnabled(enabled: Boolean) {
        dataStore.edit { it[KEY_OLED] = enabled }
    }

    suspend fun setPaletteStyle(style: HearthPaletteStyle) {
        dataStore.edit { it[KEY_PALETTE_STYLE] = style.name }
    }

    suspend fun setUiTextScale(scale: Float) {
        dataStore.edit { it[KEY_UI_TEXT_SCALE] = scale.coerceIn(1f, 1.3f) }
    }

    suspend fun setScrubScopeChapter(chapter: Boolean) {
        dataStore.edit { it[KEY_SCRUB_CHAPTER] = chapter }
    }

    suspend fun setReadNextEnabled(enabled: Boolean) {
        dataStore.edit { it[KEY_READ_NEXT_ENABLED] = enabled }
    }

    suspend fun setReadNextPosition(position: ReadNextPosition) {
        dataStore.edit { it[KEY_READ_NEXT_POSITION] = position.name }
    }

    suspend fun setRestReminderEnabled(enabled: Boolean) {
        dataStore.edit { it[KEY_REST_REMINDER_ENABLED] = enabled }
    }

    suspend fun setRestReminderMinutes(minutes: Int) {
        dataStore.edit { it[KEY_REST_REMINDER_MINUTES] = minutes.coerceIn(5, 240) }
    }

    suspend fun setRestReminderIntroShown(shown: Boolean) {
        dataStore.edit { it[KEY_REST_REMINDER_INTRO_SHOWN] = shown }
    }

    suspend fun setLibraryColumns(columns: Int) {
        dataStore.edit { it[KEY_LIBRARY_COLUMNS] = columns.coerceIn(1, 4) }
    }

    suspend fun setLibrarySortStack(encoded: String) {
        dataStore.edit { it[KEY_LIBRARY_SORT_STACK] = encoded }
    }

    suspend fun setReaderTtsVoice(name: String) {
        dataStore.edit { it[KEY_READER_TTS_VOICE] = name }
    }

    suspend fun setReaderNarratorPack(pack: NarratorPack?) {
        dataStore.edit {
            if (pack == null) {
                it.remove(KEY_READER_NARRATOR_PACK)
            } else {
                it[KEY_READER_NARRATOR_PACK] = pack.name
            }
        }
    }

    suspend fun setReaderNarratorVoice(pack: NarratorPack, voice: String) {
        dataStore.edit { it[readerNarratorVoiceKey(pack)] = voice }
    }

    suspend fun setLibraryAdvancedFilters(encoded: String) {
        dataStore.edit { it[KEY_LIBRARY_ADVANCED_FILTERS] = encoded }
    }

    suspend fun setLibraryMedia(encoded: String) {
        dataStore.edit { it[KEY_LIBRARY_MEDIA] = encoded }
    }

    suspend fun setLibraryStatus(encoded: String) {
        dataStore.edit { it[KEY_LIBRARY_STATUS] = encoded }
    }

    suspend fun setReadingEnabled(enabled: Boolean) {
        dataStore.edit { it[KEY_READING_ENABLED] = enabled }
    }

    suspend fun setLibrarySelection(encoded: String) {
        dataStore.edit { it[KEY_LIBRARY_SELECTION] = encoded }
    }

    suspend fun setScopedLibraryMedia(scope: String, encoded: String) {
        dataStore.edit { it[scopedLibraryMediaKey(scope)] = encoded }
    }

    suspend fun setComicBrowseState(scope: String, encoded: String) {
        dataStore.edit { it[comicBrowseKey(scope)] = encoded }
    }

    suspend fun setPreferredStartTab(tab: HearthStartTab) {
        dataStore.edit { it[KEY_START_TAB] = tab.name }
    }

    suspend fun setHomeSectionOrder(order: List<HearthHomeSection>) {
        val normalized = (order + HearthHomeSection.entries).distinct()
        dataStore.edit {
            it[KEY_HOME_SECTION_ORDER] = normalized.joinToString(",") { section -> section.name }
        }
    }

    suspend fun setHomeSectionHidden(section: HearthHomeSection, hidden: Boolean) {
        dataStore.edit { prefs ->
            val current = prefs[KEY_HOME_HIDDEN_SECTIONS].orEmpty().split(',').filter(String::isNotEmpty).toMutableSet()
            if (hidden) current += section.name else current -= section.name
            prefs[KEY_HOME_HIDDEN_SECTIONS] = current.joinToString(",")
        }
    }

    suspend fun setShowDockBookShortcut(show: Boolean) {
        dataStore.edit { it[KEY_SHOW_DOCK_BOOK_SHORTCUT] = show }
    }

    suspend fun setShowTodayStack(show: Boolean) {
        dataStore.edit { it[KEY_SHOW_TODAY_STACK] = show }
    }

    suspend fun setEbookSyncInterval(interval: EbookSyncInterval) {
        dataStore.edit { it[KEY_EBOOK_SYNC_INTERVAL] = interval.name }
    }
}
