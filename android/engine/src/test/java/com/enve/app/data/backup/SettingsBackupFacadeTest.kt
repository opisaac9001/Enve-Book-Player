package com.enve.app.data.backup

import com.enve.core.data.model.BookCardStyle
import com.enve.core.data.model.ComicPageLoadingMode
import com.enve.engine.backup.SettingsBackup
import com.enve.engine.backup.SettingsExportResult
import com.enve.engine.backup.SettingsImportInspection
import com.enve.engine.backup.SettingsImportRejection
import com.enve.engine.prefs.EbookSyncInterval
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.prefs.ReadNextPosition
import com.enve.engine.theme.HearthPaletteStyle
import com.enve.engine.theme.HearthThemeMode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class SettingsBackupFacadeTest {
    private val directory: File = Files.createTempDirectory("settings-backup").toFile()

    private fun facade(prefs: PreferencesFacade) = SettingsBackupFacadeImpl(
        prefs,
        { File(it).inputStream() },
        { File(it).outputStream() },
        { 1_700_000_000_000L },
    )

    private fun file(name: String, text: String? = null) =
        directory.resolve(name).apply { text?.let(::writeText) }.path

    private fun backupFile(settings: String, version: Int = 1, format: String = "enve.android.settings") =
        file("in.json", """{"format":"$format","version":$version,"settings":$settings}""")

    @Test
    fun exportedSettingsRoundTripIntoAnotherProfile() = runBlocking {
        val source = FakePreferences().apply {
            themeMode.value = HearthThemeMode.INK
            oledEnabled.value = true
            paletteStyle.value = HearthPaletteStyle.CLASSIC
            uiTextScale.value = 1.15f
            accentHex.value = "#3D91E6"
            skipForwardSeconds.value = 45
            skipBackwardSeconds.value = 15
            defaultSpeed.value = 1.25f
            scrubScopeChapter.value = true
            readNextEnabled.value = false
            readNextPosition.value = ReadNextPosition.TOP
            restReminderEnabled.value = false
            restReminderMinutes.value = 90
            ebookSyncInterval.value = EbookSyncInterval.FIVE_MINUTES
            comicPageLoadingMode.value = ComicPageLoadingMode.PRELOAD
            libraryColumns.value = 2
            readingEnabled.value = false
            preferredStartTab.value = HearthStartTab.LIBRARY
            homeSectionOrder.value = HearthHomeSection.entries.reversed()
            hiddenHomeSections.value = setOf(HearthHomeSection.DOORWAYS)
            showDockBookShortcut.value = false
            showTodayStack.value = false
        }
        val path = file("out.json")
        assertEquals(SettingsExportResult.Exported(22), facade(source).export(path))

        val target = FakePreferences()
        val inspection = facade(target).inspect(path) as SettingsImportInspection.Ready
        assertEquals(1_700_000_000_000L, inspection.preview.exportedAtMillis)
        assertEquals(22, inspection.preview.changes.size)
        assertEquals(emptyList<String>(), inspection.preview.ignoredKeys)
        assertTrue(facade(target).apply(inspection.preview.backup))

        assertEquals(source.snapshot(), target.snapshot())
        val again = facade(target).inspect(path) as SettingsImportInspection.Ready
        assertTrue(again.preview.changes.isEmpty())
        assertEquals(22, again.preview.unchangedCount)
    }

    @Test
    fun defaultSettingsRoundTripWithoutChanges() = runBlocking {
        val prefs = FakePreferences()
        val path = file("defaults.json")
        facade(prefs).export(path)
        val inspection = facade(FakePreferences()).inspect(path) as SettingsImportInspection.Ready
        assertTrue(inspection.preview.changes.isEmpty())
    }

    @Test
    fun exportContainsOnlyAllowlistedSettings() = runBlocking {
        val prefs = FakePreferences().apply {
            librarySelection.value = """{"source":"KOMGA","libraryId":"private-lib","connectionId":"conn-secret"}"""
            excludedLibraryIds.value = setOf("hidden-library-id")
            librarySortStack.value = "TITLE:DESCENDING"
        }
        val path = file("out.json")
        facade(prefs).export(path)
        val text = File(path).readText()
        val root = Json.parseToJsonElement(text).jsonObject

        assertEquals(setOf("format", "version", "exportedAtMillis", "settings"), root.keys)
        listOf("private-lib", "conn-secret", "hidden-library-id", "TITLE:DESCENDING", "token", "server", "password", "pin")
            .forEach { assertFalse(it, text.contains(it, ignoreCase = true)) }
    }

    @Test
    fun invalidValuesAreRejectedBeforeAnyMutation() = runBlocking {
        val prefs = FakePreferences()
        val before = prefs.snapshot()
        val inspection = facade(prefs).inspect(
            backupFile("""{"oledEnabled":true,"defaultSpeed":9.0,"themeMode":"NEON","libraryColumns":"3"}"""),
        ) as SettingsImportInspection.Rejected

        assertEquals(SettingsImportRejection.INVALID_VALUES, inspection.reason)
        assertEquals(setOf("defaultSpeed", "themeMode", "libraryColumns"), inspection.invalidFields.toSet())
        assertEquals(before, prefs.snapshot())
    }

    @Test
    fun applyRefusesOutOfRangeBackup() = runBlocking {
        val prefs = FakePreferences()
        val before = prefs.snapshot()
        val result = runCatching { facade(prefs).apply(SettingsBackup(oledEnabled = true, libraryColumns = 9)) }
        assertTrue(result.exceptionOrNull() is IllegalArgumentException)
        assertEquals(before, prefs.snapshot())
    }

    @Test
    fun unreadablePreferencesRejectBackupBeforeOpeningTheOutput() = runBlocking {
        val prefs = object : PreferencesFacade by FakePreferences() {
            override val themeMode: Flow<HearthThemeMode> = kotlinx.coroutines.flow.flow {
                throw java.io.IOException("Preferences unavailable")
            }
        }
        val subject = facade(prefs)
        val destination = file("existing.json", "original")
        assertEquals(SettingsExportResult.Failed, subject.export(destination))
        assertEquals("original", File(destination).readText())
        val rejected = subject.inspect(backupFile("""{"oledEnabled":true}""")) as SettingsImportInspection.Rejected
        assertEquals(SettingsImportRejection.UNREADABLE, rejected.reason)
    }

    @Test
    fun incompatibleFilesAreRejected() = runBlocking {
        val subject = facade(FakePreferences())
        suspend fun reason(path: String) = (subject.inspect(path) as SettingsImportInspection.Rejected).reason
        val iosBackup = """{"version":1,"exportedAt":"2026-01-01T00:00:00Z","preferences":{},"perBookSpeeds":{}}"""

        assertEquals(SettingsImportRejection.NOT_JSON, reason(file("a.json", "not json")))
        assertEquals(SettingsImportRejection.NOT_ANDROID_SETTINGS, reason(file("b.json", iosBackup)))
        assertEquals(SettingsImportRejection.NOT_ANDROID_SETTINGS, reason(backupFile("{}", format = "enve.ios.settings")))
        assertEquals(SettingsImportRejection.NEWER_VERSION, reason(backupFile("{}", version = 2)))
        assertEquals(SettingsImportRejection.TOO_LARGE, reason(file("c.json", " ".repeat(256 * 1024 + 1))))
        assertEquals(SettingsImportRejection.UNREADABLE, reason(directory.resolve("missing.json").path))
    }

    @Test
    fun missingSettingsArePreservedAndUnknownKeysIgnored() = runBlocking {
        val prefs = FakePreferences().apply {
            defaultSpeed.value = 1.75f
            libraryColumns.value = 4
        }
        val inspection = facade(prefs).inspect(backupFile("""{"oledEnabled":true,"futureSetting":42}""")) as SettingsImportInspection.Ready

        assertEquals(listOf("futureSetting"), inspection.preview.ignoredKeys)
        assertEquals(1, inspection.preview.changes.size)
        facade(prefs).apply(inspection.preview.backup)

        assertTrue(prefs.oledEnabled.value)
        assertEquals(1.75f, prefs.defaultSpeed.value)
        assertEquals(4, prefs.libraryColumns.value)
    }

    @Test
    fun importingIntoOneProfileLeavesAnotherUntouched() = runBlocking {
        val adult = FakePreferences()
        val child = FakePreferences()
        val adultBefore = adult.snapshot()
        val inspection = facade(child).inspect(backupFile("""{"themeMode":"PAPER","libraryColumns":1}""")) as SettingsImportInspection.Ready
        facade(child).apply(inspection.preview.backup)

        assertEquals(HearthThemeMode.PAPER, child.themeMode.value)
        assertEquals(adultBefore, adult.snapshot())
    }
}

private class FakePreferences : PreferencesFacade {
    override val themeMode = MutableStateFlow(HearthThemeMode.SYSTEM)
    override val oledEnabled = MutableStateFlow(false)
    override val paletteStyle = MutableStateFlow(HearthPaletteStyle.PARCHMENT)
    override val uiTextScale = MutableStateFlow(1f)
    override val reduceMotion = MutableStateFlow(false)
    override val accentHex = MutableStateFlow("#F5921A")
    override val skipForwardSeconds = MutableStateFlow(30)
    override val skipBackwardSeconds = MutableStateFlow(30)
    override val defaultSpeed = MutableStateFlow(1f)
    override val scrubScopeChapter = MutableStateFlow(false)
    override val readNextEnabled = MutableStateFlow(true)
    override val readNextPosition = MutableStateFlow(ReadNextPosition.BOTTOM)
    override val restReminderEnabled = MutableStateFlow(true)
    override val restReminderMinutes = MutableStateFlow(60)
    override val restReminderIntroShown = MutableStateFlow(false)
    override val libraryColumns = MutableStateFlow(3)
    override val bookCardStyle: Flow<BookCardStyle> = emptyFlow()
    override val librarySortStack = MutableStateFlow("")
    override val libraryAdvancedFilters = MutableStateFlow("")
    override val libraryMedia = MutableStateFlow("")
    override val libraryStatus = MutableStateFlow("")
    override val readingEnabled = MutableStateFlow(true)
    override val librarySelection = MutableStateFlow("")
    override fun scopedLibraryMedia(scope: String): Flow<String> = flowOf("")
    override fun comicBrowseState(scope: String): Flow<String> = flowOf("")
    override val excludedLibraryIds = MutableStateFlow(emptySet<String>())
    override val comicPageLoadingMode = MutableStateFlow(ComicPageLoadingMode.STREAM)
    override val preferredStartTab = MutableStateFlow(HearthStartTab.HEARTH)
    override val homeSectionOrder = MutableStateFlow(HearthHomeSection.entries.toList())
    override val hiddenHomeSections = MutableStateFlow(emptySet<HearthHomeSection>())
    override val showDockBookShortcut = MutableStateFlow(true)
    override val showTodayStack = MutableStateFlow(true)
    override val ebookSyncInterval = MutableStateFlow(EbookSyncInterval.AUTOMATIC)

    fun snapshot(): List<Any> = listOf(
        themeMode.value, oledEnabled.value, paletteStyle.value, uiTextScale.value, accentHex.value,
        skipForwardSeconds.value, skipBackwardSeconds.value, defaultSpeed.value, scrubScopeChapter.value,
        readNextEnabled.value, readNextPosition.value, restReminderEnabled.value, restReminderMinutes.value,
        ebookSyncInterval.value, comicPageLoadingMode.value, libraryColumns.value, readingEnabled.value,
        preferredStartTab.value, homeSectionOrder.value, hiddenHomeSections.value,
        showDockBookShortcut.value, showTodayStack.value,
        librarySelection.value, excludedLibraryIds.value, librarySortStack.value,
    )

    override suspend fun setThemeMode(mode: HearthThemeMode) { themeMode.value = mode }
    override suspend fun setOledEnabled(enabled: Boolean) { oledEnabled.value = enabled }
    override suspend fun setPaletteStyle(style: HearthPaletteStyle) { paletteStyle.value = style }
    override suspend fun setUiTextScale(scale: Float) { uiTextScale.value = scale }
    override suspend fun setAccentHex(hex: String) { accentHex.value = hex }
    override suspend fun setSkipForwardSeconds(seconds: Int) { skipForwardSeconds.value = seconds }
    override suspend fun setSkipBackwardSeconds(seconds: Int) { skipBackwardSeconds.value = seconds }
    override suspend fun setDefaultSpeed(speed: Float) { defaultSpeed.value = speed }
    override suspend fun setScrubScopeChapter(chapter: Boolean) { scrubScopeChapter.value = chapter }
    override suspend fun setReadNextEnabled(enabled: Boolean) { readNextEnabled.value = enabled }
    override suspend fun setReadNextPosition(position: ReadNextPosition) { readNextPosition.value = position }
    override suspend fun setRestReminderEnabled(enabled: Boolean) { restReminderEnabled.value = enabled }
    override suspend fun setRestReminderMinutes(minutes: Int) { restReminderMinutes.value = minutes }
    override suspend fun setRestReminderIntroShown(shown: Boolean) { restReminderIntroShown.value = shown }
    override suspend fun setLibraryColumns(columns: Int) { libraryColumns.value = columns }
    override suspend fun setLibrarySortStack(encoded: String) { librarySortStack.value = encoded }
    override suspend fun setLibraryAdvancedFilters(encoded: String) { libraryAdvancedFilters.value = encoded }
    override suspend fun setLibraryMedia(encoded: String) { libraryMedia.value = encoded }
    override suspend fun setLibraryStatus(encoded: String) { libraryStatus.value = encoded }
    override suspend fun setReadingEnabled(enabled: Boolean) { readingEnabled.value = enabled }
    override suspend fun setLibrarySelection(encoded: String) { librarySelection.value = encoded }
    override suspend fun setScopedLibraryMedia(scope: String, encoded: String) = Unit
    override suspend fun setComicBrowseState(scope: String, encoded: String) = Unit
    override suspend fun setComicPageLoadingMode(mode: ComicPageLoadingMode) { comicPageLoadingMode.value = mode }
    override suspend fun setPreferredStartTab(tab: HearthStartTab) { preferredStartTab.value = tab }
    override suspend fun setHomeSectionOrder(order: List<HearthHomeSection>) { homeSectionOrder.value = order }
    override suspend fun setHomeSectionHidden(section: HearthHomeSection, hidden: Boolean) {
        hiddenHomeSections.value = if (hidden) hiddenHomeSections.value + section else hiddenHomeSections.value - section
    }
    override suspend fun setShowDockBookShortcut(show: Boolean) { showDockBookShortcut.value = show }
    override suspend fun setShowTodayStack(show: Boolean) { showTodayStack.value = show }
    override suspend fun setEbookSyncInterval(interval: EbookSyncInterval) { ebookSyncInterval.value = interval }
}
