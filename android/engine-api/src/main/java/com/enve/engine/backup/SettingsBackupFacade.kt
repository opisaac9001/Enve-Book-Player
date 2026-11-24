package com.enve.engine.backup

import com.enve.core.data.model.ComicPageLoadingMode
import com.enve.engine.prefs.EbookSyncInterval
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.prefs.ReadNextPosition
import com.enve.engine.theme.HearthPaletteStyle
import com.enve.engine.theme.HearthThemeMode

data class SettingsBackup(
    val themeMode: HearthThemeMode? = null,
    val oledEnabled: Boolean? = null,
    val paletteStyle: HearthPaletteStyle? = null,
    val uiTextScale: Float? = null,
    val accentHex: String? = null,
    val skipForwardSeconds: Int? = null,
    val skipBackwardSeconds: Int? = null,
    val defaultSpeed: Float? = null,
    val scrubScopeChapter: Boolean? = null,
    val readNextEnabled: Boolean? = null,
    val readNextPosition: ReadNextPosition? = null,
    val restReminderEnabled: Boolean? = null,
    val restReminderMinutes: Int? = null,
    val ebookSyncInterval: EbookSyncInterval? = null,
    val comicPageLoadingMode: ComicPageLoadingMode? = null,
    val libraryColumns: Int? = null,
    val readingEnabled: Boolean? = null,
    val preferredStartTab: HearthStartTab? = null,
    val homeSectionOrder: List<HearthHomeSection>? = null,
    val hiddenHomeSections: Set<HearthHomeSection>? = null,
    val showDockBookShortcut: Boolean? = null,
    val showTodayStack: Boolean? = null,
)

data class SettingsBackupChange(val label: String, val current: String, val incoming: String)

data class SettingsImportPreview(
    val backup: SettingsBackup,
    val exportedAtMillis: Long?,
    val changes: List<SettingsBackupChange>,
    val unchangedCount: Int,
    val ignoredKeys: List<String>,
)

enum class SettingsImportRejection { UNREADABLE, TOO_LARGE, NOT_JSON, NOT_ANDROID_SETTINGS, NEWER_VERSION, INVALID_VALUES }

sealed interface SettingsImportInspection {
    data class Ready(val preview: SettingsImportPreview) : SettingsImportInspection
    data class Rejected(
        val reason: SettingsImportRejection,
        val invalidFields: List<String> = emptyList(),
    ) : SettingsImportInspection
}

sealed interface SettingsExportResult {
    data class Exported(val settingCount: Int) : SettingsExportResult
    data object Failed : SettingsExportResult
}

interface SettingsBackupFacade {
    suspend fun export(destinationUri: String): SettingsExportResult
    suspend fun inspect(sourceUri: String): SettingsImportInspection
    suspend fun apply(backup: SettingsBackup): Boolean
}
