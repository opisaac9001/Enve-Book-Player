package com.enve.app.ui.screens.reader

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.viewmodel.ReadAloudClipRow
import com.enve.hearth.design.HearthTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class HearthReadAloudLyricsTest {

    @get:Rule
    val compose = createComposeRule()

    private fun row(index: Int, text: String) = ReadAloudClipRow(
        index = index,
        startMs = index * 1_000L,
        skippable = false,
        textHref = "OEBPS/c1.xhtml",
        fragmentId = "c1.xhtml-s$index",
        resourceProgression = null,
        text = text,
    )

    private val rows = listOf(
        row(0, "Alice was beginning to get very tired."),
        row(1, "So she was considering in her own mind."),
        row(2, "When suddenly a White Rabbit ran close by her."),
    )

    private fun show(
        rows: List<ReadAloudClipRow>,
        activeIndex: Int,
        onSelect: (ReadAloudClipRow) -> Unit = {},
        onClose: () -> Unit = {},
        onToggleControls: () -> Unit = {},
    ) {
        compose.setContent {
            HearthTheme {
                HearthReadAloudLyrics(rows, activeIndex, onSelect, onClose, onToggleControls = onToggleControls)
            }
        }
    }

    @Test
    fun everyNarratedSentenceIsRendered() {
        show(rows, activeIndex = 0)

        rows.forEach { compose.onNodeWithText(it.text).assertIsDisplayed() }
        compose.onNodeWithText("READ MODE").assertIsDisplayed()
    }

    @Test
    fun tappingASentenceTogglesControlsWithoutSeeking() {
        val selected = mutableListOf<ReadAloudClipRow>()
        var toggles = 0
        show(rows, activeIndex = 1, onSelect = { selected += it }, onToggleControls = { toggles++ })

        compose.onNodeWithText(rows[2].text).performClick()
        compose.waitUntil(timeoutMillis = 1_000) { toggles == 1 }

        assertEquals(1, toggles)
        assertEquals(emptyList<ReadAloudClipRow>(), selected)
    }

    @Test
    fun doubleTappingASentenceReportsThatRow() {
        val selected = mutableListOf<ReadAloudClipRow>()
        show(rows, activeIndex = 0, onSelect = { selected += it })

        compose.onNodeWithText(rows[2].text).performTouchInput { doubleClick() }

        assertEquals(listOf(2), selected.map { it.index })
    }

    @Test
    fun accessibilityActionCanPlayFromASentence() {
        val selected = mutableListOf<ReadAloudClipRow>()
        show(rows, activeIndex = 0, onSelect = { selected += it })

        compose.onNodeWithText(rows[2].text).performSemanticsAction(SemanticsActions.OnLongClick) { it() }

        assertEquals(listOf(2), selected.map { it.index })
    }

    @Test
    fun closingThePanelIsReported() {
        var closed = 0
        show(rows, activeIndex = 1, onClose = { closed++ })

        compose.onNodeWithContentDescription("Close read mode").performClick()

        assertEquals(1, closed)
    }

    @Test
    fun clipsWithoutNarratedTextAreLeftOut() {
        show(rows + row(3, "") + row(4, "   "), activeIndex = 0)

        val lines = compose.onAllNodesWithTag(READ_MODE_LINE_TAG).fetchSemanticsNodes()
        assertEquals(rows.size, lines.size)
    }

    @Test
    fun aChapterWithNoNarratedTextExplainsItself() {
        show(listOf(row(0, ""), row(1, "")), activeIndex = 0)

        compose.onNodeWithText("No narrated text for this chapter.").assertIsDisplayed()
        assertEquals(0, compose.onAllNodesWithTag(READ_MODE_LINE_TAG).fetchSemanticsNodes().size)
    }
}
