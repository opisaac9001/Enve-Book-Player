package com.enve.app.viewmodel

import com.enve.app.data.reader.ReaderPreferences
import com.enve.app.data.reader.ReaderTheme
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadAloudPreferenceChangeTest {
    private val base = ReaderPreferences()

    @Test
    fun speedOnlyChangeIsReadAloudOnly() {
        assertTrue(isReadAloudOnlyPreferenceChange(base, base.copy(readAloudSpeed = 1.75f)))
        assertTrue(isReadAloudOnlyPreferenceChange(base, base.copy(ttsSpeed = 1.5f)))
    }

    @Test
    fun otherReadAloudSettingsAreReadAloudOnly() {
        val changed = base.copy(
            readAloudSyncOffsetMs = 200,
            readAloudAutoTurn = false,
            readAloudSkipOnPageTurn = false,
            readAloudHighlight = false,
            readAloudHighlightStyle = com.enve.core.reader.ReadAloudHighlightStyle.UNDERLINE,
            readAloudHighlightHex = "#FF0000",
            readAloudSkipAsides = false,
        )

        assertTrue(isReadAloudOnlyPreferenceChange(base, changed))
    }

    @Test
    fun layoutChangeIsNotReadAloudOnly() {
        assertFalse(isReadAloudOnlyPreferenceChange(base, base.copy(fontSize = 1.2f)))
        assertFalse(isReadAloudOnlyPreferenceChange(base, base.copy(theme = ReaderTheme.SEPIA)))
        assertFalse(isReadAloudOnlyPreferenceChange(base, base.copy(scroll = true)))
    }

    @Test
    fun speedChangedWithLayoutIsNotReadAloudOnly() {
        assertFalse(isReadAloudOnlyPreferenceChange(base, base.copy(readAloudSpeed = 2.0f, fontSize = 1.2f)))
    }
}
