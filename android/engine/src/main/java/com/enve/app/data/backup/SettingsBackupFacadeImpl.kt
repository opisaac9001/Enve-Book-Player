package com.enve.app.data.backup

import android.content.Context
import android.net.Uri
import com.enve.core.data.model.ComicPageLoadingMode
import com.enve.engine.backup.SettingsBackup
import com.enve.engine.backup.SettingsBackupChange
import com.enve.engine.backup.SettingsBackupFacade
import com.enve.engine.backup.SettingsExportResult
import com.enve.engine.backup.SettingsImportInspection
import com.enve.engine.backup.SettingsImportPreview
import com.enve.engine.backup.SettingsImportRejection
import com.enve.engine.prefs.EbookSyncInterval
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.prefs.PreferencesFacade
import com.enve.engine.prefs.ReadNextPosition
import com.enve.engine.theme.HearthPaletteStyle
import com.enve.engine.theme.HearthThemeMode
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import java.io.ByteArrayOutputStream
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import javax.inject.Inject
import kotlin.math.roundToInt

private const val FORMAT = "enve.android.settings"
private const val VERSION = 1
private const val MAX_BYTES = 256 * 1024
private val ACCENT_PATTERN = Regex("^#?[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$")

private enum class Setting(val key: String, val label: String) {
    THEME_MODE("themeMode", "Theme"),
    OLED("oledEnabled", "True black"),
    PALETTE("paletteStyle", "Palette"),
    TEXT_SCALE("uiTextScale", "Text size"),
    ACCENT("accentHex", "Accent colour"),
    SKIP_FORWARD("skipForwardSeconds", "Skip forward"),
    SKIP_BACKWARD("skipBackwardSeconds", "Skip back"),
    SPEED("defaultSpeed", "Default speed"),
    SCRUB_CHAPTER("scrubScopeChapter", "Scrub within chapter"),
    READ_NEXT("readNextEnabled", "Read next"),
    READ_NEXT_POSITION("readNextPosition", "Read next position"),
    REST_REMINDER("restReminderEnabled", "Rest reminder"),
    REST_MINUTES("restReminderMinutes", "Rest reminder interval"),
    EBOOK_SYNC("ebookSyncInterval", "Ebook sync interval"),
    COMIC_LOADING("comicPageLoadingMode", "Comic page loading"),
    LIBRARY_COLUMNS("libraryColumns", "Library columns"),
    READING("readingEnabled", "Reading in library"),
    START_TAB("preferredStartTab", "Start tab"),
    HOME_ORDER("homeSectionOrder", "Home section order"),
    HOME_HIDDEN("hiddenHomeSections", "Hidden home sections"),
    DOCK_BOOK("showDockBookShortcut", "Book shortcut in dock"),
    TODAY_STACK("showTodayStack", "Today stack"),
}

class SettingsBackupFacadeImpl internal constructor(
    private val prefs: PreferencesFacade,
    private val openRead: (String) -> InputStream,
    private val openWrite: (String) -> OutputStream,
    private val clock: () -> Long,
) : SettingsBackupFacade {

    @Inject
    constructor(@ApplicationContext context: Context, prefs: PreferencesFacade) : this(
        prefs,
        { uri -> context.contentResolver.openInputStream(Uri.parse(uri)) ?: throw FileNotFoundException(uri) },
        { uri -> context.contentResolver.openOutputStream(Uri.parse(uri), "wt") ?: throw FileNotFoundException(uri) },
        System::currentTimeMillis,
    )

    private val json = Json { prettyPrint = true }

    override suspend fun export(destinationUri: String): SettingsExportResult {
        val entries = currentSettings()?.entries() ?: return SettingsExportResult.Failed
        val root = buildJsonObject {
            put("format", JsonPrimitive(FORMAT))
            put("version", JsonPrimitive(VERSION))
            put("exportedAtMillis", JsonPrimitive(clock()))
            put("settings", JsonObject(entries.entries.associate { (setting, value) -> setting.key to encode(value) }))
        }
        val bytes = json.encodeToString(JsonObject.serializer(), root).encodeToByteArray()
        return try {
            withContext(Dispatchers.IO) { openWrite(destinationUri).use { it.write(bytes) } }
            SettingsExportResult.Exported(entries.size)
        } catch (e: IOException) {
            SettingsExportResult.Failed
        } catch (e: SecurityException) {
            SettingsExportResult.Failed
        }
    }

    override suspend fun inspect(sourceUri: String): SettingsImportInspection {
        val bytes = try {
            withContext(Dispatchers.IO) { openRead(sourceUri).use { it.readAtMost(MAX_BYTES + 1) } }
        } catch (e: IOException) {
            return SettingsImportInspection.Rejected(SettingsImportRejection.UNREADABLE)
        } catch (e: SecurityException) {
            return SettingsImportInspection.Rejected(SettingsImportRejection.UNREADABLE)
        }
        if (bytes.size > MAX_BYTES) return SettingsImportInspection.Rejected(SettingsImportRejection.TOO_LARGE)
        val root = try {
            Json.parseToJsonElement(bytes.decodeToString()) as? JsonObject
        } catch (e: SerializationException) {
            null
        } ?: return SettingsImportInspection.Rejected(SettingsImportRejection.NOT_JSON)

        val format = (root["format"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val version = (root["version"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
        if (format != FORMAT || version == null || version < 1) {
            return SettingsImportInspection.Rejected(SettingsImportRejection.NOT_ANDROID_SETTINGS)
        }
        if (version > VERSION) return SettingsImportInspection.Rejected(SettingsImportRejection.NEWER_VERSION)
        val settings = root["settings"] as? JsonObject
            ?: return SettingsImportInspection.Rejected(SettingsImportRejection.INVALID_VALUES, listOf("settings"))

        val reader = SettingsReader(settings)
        val backup = reader.read()
        val invalid = reader.invalid + backup.invalidFields()
        if (invalid.isNotEmpty()) {
            return SettingsImportInspection.Rejected(SettingsImportRejection.INVALID_VALUES, invalid.distinct())
        }

        val known = Setting.entries.mapTo(HashSet()) { it.key }
        val currentValues = currentSettings()?.entries()
            ?: return SettingsImportInspection.Rejected(SettingsImportRejection.UNREADABLE)
        val incoming = backup.entries()
        val changes = incoming.mapNotNull { (setting, value) ->
            val before = currentValues[setting]?.let { setting.describe(it) } ?: "Not set"
            val after = setting.describe(value)
            if (before == after) null else SettingsBackupChange(setting.label, before, after)
        }
        return SettingsImportInspection.Ready(
            SettingsImportPreview(
                backup = backup,
                exportedAtMillis = (root["exportedAtMillis"] as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull,
                changes = changes,
                unchangedCount = incoming.size - changes.size,
                ignoredKeys = settings.keys.filterNot(known::contains).sorted(),
            ),
        )
    }

    override suspend fun apply(backup: SettingsBackup): Boolean {
        require(backup.invalidFields().isEmpty())
        return withContext(NonCancellable) {
            try {
                backup.themeMode?.let { prefs.setThemeMode(it) }
                backup.oledEnabled?.let { prefs.setOledEnabled(it) }
                backup.paletteStyle?.let { prefs.setPaletteStyle(it) }
                backup.uiTextScale?.let { prefs.setUiTextScale(it) }
                backup.accentHex?.let { prefs.setAccentHex(it) }
                backup.skipForwardSeconds?.let { prefs.setSkipForwardSeconds(it) }
                backup.skipBackwardSeconds?.let { prefs.setSkipBackwardSeconds(it) }
                backup.defaultSpeed?.let { prefs.setDefaultSpeed(it) }
                backup.scrubScopeChapter?.let { prefs.setScrubScopeChapter(it) }
                backup.readNextEnabled?.let { prefs.setReadNextEnabled(it) }
                backup.readNextPosition?.let { prefs.setReadNextPosition(it) }
                backup.restReminderEnabled?.let { prefs.setRestReminderEnabled(it) }
                backup.restReminderMinutes?.let { prefs.setRestReminderMinutes(it) }
                backup.ebookSyncInterval?.let { prefs.setEbookSyncInterval(it) }
                backup.comicPageLoadingMode?.let { prefs.setComicPageLoadingMode(it) }
                backup.libraryColumns?.let { prefs.setLibraryColumns(it) }
                backup.readingEnabled?.let { prefs.setReadingEnabled(it) }
                backup.preferredStartTab?.let { prefs.setPreferredStartTab(it) }
                backup.homeSectionOrder?.let { prefs.setHomeSectionOrder(it) }
                backup.hiddenHomeSections?.let { hidden ->
                    HearthHomeSection.entries.forEach { prefs.setHomeSectionHidden(it, it in hidden) }
                }
                backup.showDockBookShortcut?.let { prefs.setShowDockBookShortcut(it) }
                backup.showTodayStack?.let { prefs.setShowTodayStack(it) }
                true
            } catch (e: IOException) {
                false
            }
        }
    }

    private suspend fun currentSettings(): SettingsBackup? = try {
        current()
    } catch (_: IOException) {
        null
    }

    private suspend fun current() = SettingsBackup(
        themeMode = prefs.themeMode.first(),
        oledEnabled = prefs.oledEnabled.first(),
        paletteStyle = prefs.paletteStyle.first(),
        uiTextScale = prefs.uiTextScale.first(),
        accentHex = prefs.accentHex.first(),
        skipForwardSeconds = prefs.skipForwardSeconds.first(),
        skipBackwardSeconds = prefs.skipBackwardSeconds.first(),
        defaultSpeed = prefs.defaultSpeed.first(),
        scrubScopeChapter = prefs.scrubScopeChapter.first(),
        readNextEnabled = prefs.readNextEnabled.first(),
        readNextPosition = prefs.readNextPosition.first(),
        restReminderEnabled = prefs.restReminderEnabled.first(),
        restReminderMinutes = prefs.restReminderMinutes.first(),
        ebookSyncInterval = prefs.ebookSyncInterval.first(),
        comicPageLoadingMode = prefs.comicPageLoadingMode.first(),
        libraryColumns = prefs.libraryColumns.first(),
        readingEnabled = prefs.readingEnabled.first(),
        preferredStartTab = prefs.preferredStartTab.first(),
        homeSectionOrder = prefs.homeSectionOrder.first(),
        hiddenHomeSections = prefs.hiddenHomeSections.first(),
        showDockBookShortcut = prefs.showDockBookShortcut.first(),
        showTodayStack = prefs.showTodayStack.first(),
    )
}

private class SettingsReader(private val settings: JsonObject) {
    val invalid = mutableListOf<String>()

    fun read() = SettingsBackup(
        themeMode = enum(Setting.THEME_MODE, HearthThemeMode.entries),
        oledEnabled = bool(Setting.OLED),
        paletteStyle = enum(Setting.PALETTE, HearthPaletteStyle.entries),
        uiTextScale = float(Setting.TEXT_SCALE),
        accentHex = string(Setting.ACCENT)?.let { hex ->
            if (ACCENT_PATTERN.matches(hex)) "#" + hex.removePrefix("#").uppercase() else hex
        },
        skipForwardSeconds = int(Setting.SKIP_FORWARD),
        skipBackwardSeconds = int(Setting.SKIP_BACKWARD),
        defaultSpeed = float(Setting.SPEED),
        scrubScopeChapter = bool(Setting.SCRUB_CHAPTER),
        readNextEnabled = bool(Setting.READ_NEXT),
        readNextPosition = enum(Setting.READ_NEXT_POSITION, ReadNextPosition.entries),
        restReminderEnabled = bool(Setting.REST_REMINDER),
        restReminderMinutes = int(Setting.REST_MINUTES),
        ebookSyncInterval = enum(Setting.EBOOK_SYNC, EbookSyncInterval.entries),
        comicPageLoadingMode = enum(Setting.COMIC_LOADING, ComicPageLoadingMode.entries),
        libraryColumns = int(Setting.LIBRARY_COLUMNS),
        readingEnabled = bool(Setting.READING),
        preferredStartTab = enum(Setting.START_TAB, HearthStartTab.entries),
        homeSectionOrder = enumList(Setting.HOME_ORDER, HearthHomeSection.entries),
        hiddenHomeSections = enumList(Setting.HOME_HIDDEN, HearthHomeSection.entries)?.toSet(),
        showDockBookShortcut = bool(Setting.DOCK_BOOK),
        showTodayStack = bool(Setting.TODAY_STACK),
    )

    private fun <T> parsed(setting: Setting, parse: (JsonPrimitive) -> T?): T? {
        val element = settings[setting.key]
        if (element == null || element is JsonNull) return null
        val value = (element as? JsonPrimitive)?.let(parse)
        if (value == null) invalid += setting.key
        return value
    }

    private fun bool(setting: Setting) = parsed(setting) { if (it.isString) null else it.booleanOrNull }
    private fun int(setting: Setting) = parsed(setting) { if (it.isString) null else it.intOrNull }
    private fun float(setting: Setting) =
        parsed(setting) { if (it.isString) null else it.floatOrNull?.takeIf(Float::isFinite) }
    private fun string(setting: Setting) = parsed(setting) { if (it.isString) it.content else null }

    private fun <E : Enum<E>> enum(setting: Setting, entries: List<E>): E? =
        parsed(setting) { primitive -> if (primitive.isString) entries.firstOrNull { it.name == primitive.content } else null }

    private fun <E : Enum<E>> enumList(setting: Setting, entries: List<E>): List<E>? {
        val element = settings[setting.key]
        if (element == null || element is JsonNull) return null
        val values = (element as? JsonArray)?.map { item ->
            val name = (item as? JsonPrimitive)?.takeIf { it.isString }?.content
            entries.firstOrNull { it.name == name }
        }
        if (values == null || values.any { it == null }) {
            invalid += setting.key
            return null
        }
        return values.filterNotNull()
    }
}

private fun <T : Comparable<T>> outside(value: T?, range: ClosedRange<T>) = value != null && value !in range

private fun SettingsBackup.invalidFields(): List<String> = buildList {
    if (outside(uiTextScale, 1f..1.3f)) add(Setting.TEXT_SCALE.key)
    if (accentHex?.let { !ACCENT_PATTERN.matches(it) } == true) add(Setting.ACCENT.key)
    if (outside(skipForwardSeconds, 5..300)) add(Setting.SKIP_FORWARD.key)
    if (outside(skipBackwardSeconds, 5..300)) add(Setting.SKIP_BACKWARD.key)
    if (outside(defaultSpeed, 0.5f..3f)) add(Setting.SPEED.key)
    if (outside(restReminderMinutes, 5..240)) add(Setting.REST_MINUTES.key)
    if (outside(libraryColumns, 1..4)) add(Setting.LIBRARY_COLUMNS.key)
    if (homeSectionOrder?.let { it.size != it.toSet().size } == true) add(Setting.HOME_ORDER.key)
}

private fun SettingsBackup.entries(): Map<Setting, Any> = buildMap {
    fun add(setting: Setting, value: Any?) {
        if (value != null) put(setting, value)
    }
    add(Setting.THEME_MODE, themeMode)
    add(Setting.OLED, oledEnabled)
    add(Setting.PALETTE, paletteStyle)
    add(Setting.TEXT_SCALE, uiTextScale)
    add(Setting.ACCENT, accentHex)
    add(Setting.SKIP_FORWARD, skipForwardSeconds)
    add(Setting.SKIP_BACKWARD, skipBackwardSeconds)
    add(Setting.SPEED, defaultSpeed)
    add(Setting.SCRUB_CHAPTER, scrubScopeChapter)
    add(Setting.READ_NEXT, readNextEnabled)
    add(Setting.READ_NEXT_POSITION, readNextPosition)
    add(Setting.REST_REMINDER, restReminderEnabled)
    add(Setting.REST_MINUTES, restReminderMinutes)
    add(Setting.EBOOK_SYNC, ebookSyncInterval)
    add(Setting.COMIC_LOADING, comicPageLoadingMode)
    add(Setting.LIBRARY_COLUMNS, libraryColumns)
    add(Setting.READING, readingEnabled)
    add(Setting.START_TAB, preferredStartTab)
    add(Setting.HOME_ORDER, homeSectionOrder)
    add(Setting.HOME_HIDDEN, hiddenHomeSections?.sortedBy { it.ordinal })
    add(Setting.DOCK_BOOK, showDockBookShortcut)
    add(Setting.TODAY_STACK, showTodayStack)
}

private fun encode(value: Any): JsonElement = when (value) {
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is String -> JsonPrimitive(value)
    is Enum<*> -> JsonPrimitive(value.name)
    is Collection<*> -> JsonArray(value.map { encode(requireNotNull(it)) })
    else -> error("Unsupported setting value ${value::class}")
}

private fun Setting.describe(value: Any): String = when (this) {
    Setting.SPEED -> "$value×"
    Setting.SKIP_FORWARD, Setting.SKIP_BACKWARD -> "$value s"
    Setting.REST_MINUTES -> "$value min"
    Setting.TEXT_SCALE -> "${((value as Float) * 100).roundToInt()}%"
    Setting.ACCENT -> "#" + (value as String).removePrefix("#").uppercase()
    else -> describeValue(value)
}

private fun describeValue(value: Any): String = when (value) {
    is Boolean -> if (value) "On" else "Off"
    is HearthStartTab -> value.label
    is HearthHomeSection -> value.label
    is ReadNextPosition -> value.label
    is EbookSyncInterval -> value.label
    is Enum<*> -> value.name.lowercase().replaceFirstChar(Char::uppercase)
    is Collection<*> -> if (value.isEmpty()) "None" else value.joinToString(", ") { describeValue(requireNotNull(it)) }
    else -> value.toString()
}

private fun InputStream.readAtMost(limit: Int): ByteArray {
    val out = ByteArrayOutputStream()
    val buffer = ByteArray(8 * 1024)
    while (out.size() < limit) {
        val read = read(buffer, 0, minOf(buffer.size, limit - out.size()))
        if (read < 0) break
        out.write(buffer, 0, read)
    }
    return out.toByteArray()
}
