package com.enve.app.hearth

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import com.enve.engine.theme.HearthThemeMode
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.HearthStartTab
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

private val Context.hearthDataStore by preferencesDataStore(name = "hearth_prefs")
private val KEY_THEME_MODE = stringPreferencesKey("hearth.themeMode")
private val KEY_OLED = booleanPreferencesKey("hearth.oled")
private val KEY_UI_TEXT_SCALE = floatPreferencesKey("hearth.uiTextScale")
private val KEY_SCRUB_CHAPTER = booleanPreferencesKey("hearth.player.scrubChapter")
private val KEY_LIBRARY_COLUMNS = intPreferencesKey("hearth.library.columns")
private val KEY_LIBRARY_SORT_STACK = stringPreferencesKey("hearth.library.sortStack")
private val KEY_LIBRARY_ADVANCED_FILTERS = stringPreferencesKey("hearth.library.advancedFilters")
private val KEY_START_TAB = stringPreferencesKey("hearth.startTab")
private val KEY_HOME_SECTION_ORDER = stringPreferencesKey("hearth.home.sectionOrder")

@Singleton
class HearthPreferencesStore @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    val themeMode: Flow<HearthThemeMode> = context.hearthDataStore.data.map { prefs ->
        prefs[KEY_THEME_MODE]?.let { runCatching { HearthThemeMode.valueOf(it) }.getOrNull() }
            ?: HearthThemeMode.SYSTEM
    }

    val oledEnabled: Flow<Boolean> = context.hearthDataStore.data.map { it[KEY_OLED] ?: false }

    val uiTextScale: Flow<Float> = context.hearthDataStore.data.map {
        (it[KEY_UI_TEXT_SCALE] ?: 1f).coerceIn(1f, 1.3f)
    }

    val scrubScopeChapter: Flow<Boolean> = context.hearthDataStore.data.map { it[KEY_SCRUB_CHAPTER] ?: false }

    val libraryColumns: Flow<Int> = context.hearthDataStore.data.map { (it[KEY_LIBRARY_COLUMNS] ?: 3).coerceIn(1, 4) }

    val librarySortStack: Flow<String> = context.hearthDataStore.data.map { it[KEY_LIBRARY_SORT_STACK] ?: "" }
    val libraryAdvancedFilters: Flow<String> =
        context.hearthDataStore.data.map { it[KEY_LIBRARY_ADVANCED_FILTERS] ?: "" }
    val preferredStartTab: Flow<HearthStartTab> = context.hearthDataStore.data.map { prefs ->
        prefs[KEY_START_TAB]?.let { runCatching { HearthStartTab.valueOf(it) }.getOrNull() }
            ?: HearthStartTab.HEARTH
    }
    val homeSectionOrder: Flow<List<HearthHomeSection>> = context.hearthDataStore.data.map { prefs ->
        val saved = prefs[KEY_HOME_SECTION_ORDER]
            .orEmpty()
            .split(',')
            .mapNotNull { raw -> runCatching { HearthHomeSection.valueOf(raw) }.getOrNull() }
        (saved + HearthHomeSection.entries).distinct()
    }

    suspend fun setThemeMode(mode: HearthThemeMode) {
        context.hearthDataStore.edit { it[KEY_THEME_MODE] = mode.name }
    }

    suspend fun setOledEnabled(enabled: Boolean) {
        context.hearthDataStore.edit { it[KEY_OLED] = enabled }
    }

    suspend fun setUiTextScale(scale: Float) {
        context.hearthDataStore.edit { it[KEY_UI_TEXT_SCALE] = scale.coerceIn(1f, 1.3f) }
    }

    suspend fun setScrubScopeChapter(chapter: Boolean) {
        context.hearthDataStore.edit { it[KEY_SCRUB_CHAPTER] = chapter }
    }

    suspend fun setLibraryColumns(columns: Int) {
        context.hearthDataStore.edit { it[KEY_LIBRARY_COLUMNS] = columns.coerceIn(1, 4) }
    }

    suspend fun setLibrarySortStack(encoded: String) {
        context.hearthDataStore.edit { it[KEY_LIBRARY_SORT_STACK] = encoded }
    }

    suspend fun setLibraryAdvancedFilters(encoded: String) {
        context.hearthDataStore.edit { it[KEY_LIBRARY_ADVANCED_FILTERS] = encoded }
    }

    suspend fun setPreferredStartTab(tab: HearthStartTab) {
        context.hearthDataStore.edit { it[KEY_START_TAB] = tab.name }
    }

    suspend fun setHomeSectionOrder(order: List<HearthHomeSection>) {
        val normalized = (order + HearthHomeSection.entries).distinct()
        context.hearthDataStore.edit {
            it[KEY_HOME_SECTION_ORDER] = normalized.joinToString(",") { section -> section.name }
        }
    }
}
