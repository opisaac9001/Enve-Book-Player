package com.enve.app.hearth

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import com.enve.core.data.local.ProfilePreferences
import com.enve.engine.theme.HearthThemeMode
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
private val KEY_START_TAB = stringPreferencesKey("hearth.startTab")
private val KEY_HOME_SECTION_ORDER = stringPreferencesKey("hearth.home.sectionOrder")

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
    val libraryAdvancedFilters: Flow<String> =
        dataStore.data.map { it[KEY_LIBRARY_ADVANCED_FILTERS] ?: "" }
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

    suspend fun setThemeMode(mode: HearthThemeMode) {
        dataStore.edit { it[KEY_THEME_MODE] = mode.name }
    }

    suspend fun setOledEnabled(enabled: Boolean) {
        dataStore.edit { it[KEY_OLED] = enabled }
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

    suspend fun setLibraryAdvancedFilters(encoded: String) {
        dataStore.edit { it[KEY_LIBRARY_ADVANCED_FILTERS] = encoded }
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
}
