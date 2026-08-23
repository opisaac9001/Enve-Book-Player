package com.enve.app.data.reader

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.readium.r2.navigator.preferences.ColumnCount

class ReaderPreferencesTest {
    @Test
    fun supportsLargeAccessibilityFontScale() {
        val preferences = ReaderPreferences(fontSize = MAX_READER_FONT_SCALE)

        assertEquals(4.0f, preferences.fontSize, 0.0f)
        assertTrue(MAX_READER_FONT_SCALE > 2.0f)
    }

    @Test
    fun preservesUserColumnPreferenceOnStandardDisplays() {
        assertEquals(
            ColumnCount.TWO,
            ReaderColumns.TWO.toReadiumColumnCount(einkActive = false),
        )
    }

    @Test
    fun forcesSingleColumnWhenEinkOptimizationsAreActive() {
        assertEquals(
            ColumnCount.ONE,
            ReaderColumns.TWO.toReadiumColumnCount(einkActive = true),
        )
    }

    @Test
    fun paragraphIndentPreservesConfiguredValueAndZeroReset() {
        assertEquals(1.25f, ReaderPreferences(paragraphIndent = 1.25f).paragraphIndent)
        assertEquals(0f, ReaderPreferences(paragraphIndent = 0f).paragraphIndent)
    }

    @Test
    fun paragraphIndentIsForwardedToReadium() {
        val source = listOf(
            File("../engine/src/main/java/com/enve/app/data/reader/ReaderPreferences.kt"),
            File("engine/src/main/java/com/enve/app/data/reader/ReaderPreferences.kt"),
        ).first(File::isFile).readText()

        assertTrue(source.contains("paragraphIndent = paragraphIndent.toDouble()"))
    }
}
