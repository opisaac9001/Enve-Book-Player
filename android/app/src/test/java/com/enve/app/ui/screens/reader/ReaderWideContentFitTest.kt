package com.enve.app.ui.screens.reader

import com.enve.app.data.reader.ReaderColumns
import com.enve.app.data.reader.ReaderPreferences
import com.enve.app.data.reader.ReaderTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderWideContentFitTest {
    @Test
    fun javascriptAnswersAreReadThroughTheirJsonQuoting() {
        assertEquals(ReaderWideContentFit.Result.CHANGED, ReaderWideContentFit.parse("\"changed\""))
        assertEquals(ReaderWideContentFit.Result.STABLE, ReaderWideContentFit.parse("\"stable\""))
        assertEquals(ReaderWideContentFit.Result.BLOCKED, ReaderWideContentFit.parse("\"blocked\""))
        assertEquals(ReaderWideContentFit.Result.STABLE, ReaderWideContentFit.parse(" stable "))
    }

    @Test
    fun missingAnswerIsAFailureNeverASilentSuccess() {
        assertEquals(ReaderWideContentFit.Result.FAILED, ReaderWideContentFit.parse(null))
        assertEquals(ReaderWideContentFit.Result.FAILED, ReaderWideContentFit.parse(""))
        assertEquals(ReaderWideContentFit.Result.FAILED, ReaderWideContentFit.parse("null"))
        assertEquals(ReaderWideContentFit.Result.FAILED, ReaderWideContentFit.parse("\"failed\""))
    }

    @Test
    fun reflowSignatureTracksLayoutPreferencesOnly() {
        val prefs = ReaderPreferences()
        assertEquals(prefs.reflowSignature(), prefs.copy(theme = ReaderTheme.OLED).reflowSignature())
        assertEquals(prefs.reflowSignature(), prefs.copy(screenBrightness = 0.4f, showClock = true).reflowSignature())
        assertNotEquals(prefs.reflowSignature(), prefs.copy(fontSize = 1.3f).reflowSignature())
        assertNotEquals(prefs.reflowSignature(), prefs.copy(scroll = true).reflowSignature())
        assertNotEquals(prefs.reflowSignature(), prefs.copy(columns = ReaderColumns.TWO).reflowSignature())
        assertNotEquals(prefs.reflowSignature(), prefs.copy(pageMargins = 1.5f).reflowSignature())
    }
}
