package com.enve.app.viewmodel

import com.enve.app.data.reader.ReaderTheme
import org.junit.Assert.assertEquals
import org.junit.Test

class ReaderAnnotationRenderColorTest {
    @Test
    fun preservesStoredColorOnStandardDisplays() {
        assertEquals(
            "#FFF59D",
            annotationRenderColorHex("#FFF59D", einkActive = false, theme = ReaderTheme.LIGHT),
        )
    }

    @Test
    fun usesBlackInkForLightEinkPages() {
        assertEquals(
            "#000000",
            annotationRenderColorHex("#FFF59D", einkActive = true, theme = ReaderTheme.SEPIA),
        )
    }

    @Test
    fun usesWhiteInkForDarkEinkPages() {
        assertEquals(
            "#FFFFFF",
            annotationRenderColorHex("#FFF59D", einkActive = true, theme = ReaderTheme.OLED),
        )
    }

    @Test
    fun namedHighlightColorsRenderAsHex() {
        assertEquals(
            "#F472B6",
            annotationRenderColorHex("pink", einkActive = false, theme = ReaderTheme.LIGHT),
        )
    }
}
