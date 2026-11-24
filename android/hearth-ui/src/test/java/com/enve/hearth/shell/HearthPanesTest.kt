package com.enve.hearth.shell

import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class HearthPanesTest {
    @Test
    fun phoneAndFoldedWidthsKeepSinglePaneNavigation() {
        assertNull(HearthPanes.listPaneWidth(412.dp))
        assertNull(HearthPanes.listPaneWidth(839.dp))
    }

    @Test
    fun wideWindowsGetABoundedListPane() {
        assertEquals(360.dp, HearthPanes.listPaneWidth(840.dp))
        assertEquals(400.dp, HearthPanes.listPaneWidth(1000.dp))
        assertEquals(480.dp, HearthPanes.listPaneWidth(1600.dp))
    }
}
