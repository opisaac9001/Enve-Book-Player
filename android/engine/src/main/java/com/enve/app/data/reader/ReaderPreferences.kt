package com.enve.app.data.reader

import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.preferences.ColumnCount
import org.readium.r2.navigator.preferences.FontFamily
import org.readium.r2.navigator.preferences.TextAlign
import org.readium.r2.shared.ExperimentalReadiumApi

enum class ReaderTheme { LIGHT, SEPIA, DARK, OLED }
const val MIN_READER_FONT_SCALE = 0.7f
const val MAX_READER_FONT_SCALE = 4.0f
const val READER_FONT_SCALE_STEP = 0.1f

enum class ReaderFont(val displayName: String) {
    SERIF("Serif"),
    SANS("Sans Serif"),
    DYSLEXIC("OpenDyslexic"),
    MONO("Monospace"),
    LITERATA("Literata"),
    ATKINSON("Atkinson Hyperlegible"),
    LEXEND("Lexend"),
    IA_WRITER("iA Writer Duo"),
}
enum class ReaderColumns { AUTO, ONE, TWO }

@OptIn(ExperimentalReadiumApi::class)
fun ReaderColumns.toReadiumColumnCount(einkActive: Boolean): ColumnCount {
    if (einkActive) return ColumnCount.ONE
    return when (this) {
        ReaderColumns.AUTO -> ColumnCount.AUTO
        ReaderColumns.ONE -> ColumnCount.ONE
        ReaderColumns.TWO -> ColumnCount.TWO
    }
}

enum class ReaderToolbarButton(val label: String, val iconName: String) {
    TOC("Contents", "list"),
    APPEARANCE("Appearance", "text"),
    BOOKMARK("Bookmark", "bookmark"),
    READ_ALONG("Read Along", "headset"),
    AUTO_SCROLL("Auto Scroll", "scroll"),
    SHARE("Share", "share"),
    SEARCH("Search", "search");

    companion object {
        val DEFAULT_SET = setOf(SEARCH, TOC, APPEARANCE, BOOKMARK)
    }
}

enum class ReaderProgressDisplay(val label: String) {
    NONE("None"),
    PAGE("Page X of Y"),
    PERCENT("Percentage"),
    CHAPTER("Chapter title"),
    PAGE_AND_PERCENT("Page + %"),
}

@OptIn(ExperimentalReadiumApi::class)
data class ReaderPreferences(
    val theme:            ReaderTheme   = ReaderTheme.DARK,
    val font:             ReaderFont    = ReaderFont.SERIF,

    val customFontName:   String?       = null,
    val fontSize:         Float         = 1.0f,
    val lineHeight:       Float         = 1.4f,
    val pageMargins:      Float         = 0.5f,
    val verticalMargins:  Float         = 0.5f,
    val wordSpacing:      Float         = 0f,
    val letterSpacing:    Float         = 0f,
    val fontWeight:       Float         = 1.0f,
    val paragraphSpacing: Float         = 0f,
    val paragraphIndent:  Float         = 0f,
    val scroll:           Boolean       = false,

    val publisherStyles:  Boolean       = true,
    val justified:        Boolean       = true,
    val columns:          ReaderColumns = ReaderColumns.AUTO,

    val volumeButtonNavigation: Boolean = true,
    val autoScrollSpeed:  Float = 0f,
    val toolbarButtons:   Set<ReaderToolbarButton> = ReaderToolbarButton.DEFAULT_SET,
    val ttsEnabled:       Boolean = false,
    val ttsSpeed:         Float = 1.0f,

    val readAloudSpeed:        Float = 1.0f,
    val readAloudSyncOffsetMs: Int = 0,
    val readAloudAutoTurn:     Boolean = true,
    val readAloudHighlight:    Boolean = true,
    val readAloudHighlightHex: String = "#FFF59D",
    val readAloudSkipAsides:   Boolean = true,
    val screenBrightness: Float = -1f,
    val showClock:        Boolean = false,
    val showBattery:      Boolean = false,
    val progressDisplay:  ReaderProgressDisplay = ReaderProgressDisplay.NONE,
    val tapZoneWidth:     Float = 0.20f,
    val edgeBrightnessSwipe: Boolean = true,

    val bionicReading:    Boolean = false,
) {

    val backgroundColor: Int get() = when (theme) {
        ReaderTheme.LIGHT -> 0xFFFAFAFA.toInt()
        ReaderTheme.SEPIA -> 0xFFF3E8D0.toInt()
        ReaderTheme.DARK  -> 0xFF121212.toInt()
        ReaderTheme.OLED  -> 0xFF000000.toInt()
    }
    val surfaceColor: Int get() = when (theme) {
        ReaderTheme.LIGHT -> 0xFFFFFFFF.toInt()
        ReaderTheme.SEPIA -> 0xFFEDD9B4.toInt()
        ReaderTheme.DARK  -> 0xFF1E1E1E.toInt()
        ReaderTheme.OLED  -> 0xFF0A0A0A.toInt()
    }
    val primaryTextColor: Int get() = when (theme) {
        ReaderTheme.LIGHT, ReaderTheme.SEPIA -> 0xFF1A1A1A.toInt()
        ReaderTheme.DARK  -> 0xFFE0E0E0.toInt()
        ReaderTheme.OLED  -> 0xFFFFFFFF.toInt()
    }
    val accentColor: Int get() = 0xFFBB86FC.toInt()

    fun toEpubPreferences(einkBoldText: Boolean = false, einkActive: Boolean = false): EpubPreferences {
        val readiumTheme = when (theme) {
            ReaderTheme.LIGHT -> org.readium.r2.navigator.preferences.Theme.LIGHT
            ReaderTheme.SEPIA -> org.readium.r2.navigator.preferences.Theme.SEPIA
            ReaderTheme.DARK, ReaderTheme.OLED -> org.readium.r2.navigator.preferences.Theme.DARK
        }
        val ff = customFontName?.let { FontFamily(it) } ?: when (font) {
            ReaderFont.SERIF      -> FontFamily.SERIF
            ReaderFont.SANS       -> FontFamily.SANS_SERIF
            ReaderFont.DYSLEXIC   -> FontFamily.OPEN_DYSLEXIC
            ReaderFont.MONO       -> FontFamily("monospace")
            ReaderFont.LITERATA   -> FontFamily("Literata")
            ReaderFont.ATKINSON   -> FontFamily("Atkinson Hyperlegible")
            ReaderFont.LEXEND     -> FontFamily("Lexend")
            ReaderFont.IA_WRITER  -> FontFamily.IA_WRITER_DUOSPACE
        }
        return EpubPreferences(
            theme           = readiumTheme,
            fontFamily      = ff,
            fontSize        = fontSize.toDouble(),
            lineHeight      = lineHeight.toDouble(),
            pageMargins     = pageMargins.toDouble(),

            wordSpacing     = wordSpacing.toDouble(),
            letterSpacing   = letterSpacing.toDouble(),
            fontWeight      = if (einkBoldText) (fontWeight.coerceAtLeast(1.0f) * 1.4f).coerceAtMost(2.0f).toDouble() else fontWeight.toDouble(),
            paragraphSpacing = paragraphSpacing.toDouble(),
            paragraphIndent = paragraphIndent.toDouble(),
            scroll          = scroll,
            publisherStyles = publisherStyles,
            textAlign       = if (justified) TextAlign.JUSTIFY else TextAlign.START,
            columnCount     = columns.toReadiumColumnCount(einkActive),
        )
    }
}
