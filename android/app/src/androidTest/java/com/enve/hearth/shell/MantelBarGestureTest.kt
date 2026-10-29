package com.enve.hearth.shell

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeRight
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.engine.playback.PlaybackTransport
import com.enve.hearth.design.HearthTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MantelBarGestureTest {

    @get:Rule
    val compose = createComposeRule()

    private val selections = mutableListOf<HearthTab>()
    private var opened = 0

    private fun show(withItem: Boolean = true, showShortcut: Boolean = true) {
        compose.setContent {
            HearthTheme {
                MantelBar(
                    selected = HearthTab.HEARTH,
                    onSelect = { selections += it },
                    lastOpenedBook = Book(id = "mantel", title = "Mantel", source = BookSource.LOCAL).takeIf { withItem },
                    nowPlaying = null,
                    transport = PlaybackTransport.Empty,
                    subtitle = null,
                    onOpenItem = { opened += 1 },
                    onItemAction = {},
                    showItemShortcut = showShortcut,
                )
            }
        }
    }

    private fun tab(label: String) = compose.onNode(hasText(label) and hasClickAction())

    @Test
    fun tapOnATabSelectsIt() {
        show()

        tab("Podcasts").performClick()

        assertEquals(listOf(HearthTab.PODCASTS), selections)
    }

    @Test
    fun swipeUpDeliveredWithoutMovesOpensTheItemAndSelectsNoTab() {
        show()

        tab("Podcasts").performTouchInput {
            down(center)
            updatePointerTo(0, center - Offset(0f, 600f))
            up()
        }
        compose.waitForIdle()

        assertEquals(emptyList<HearthTab>(), selections)
        assertEquals(1, opened)
    }

    @Test
    fun horizontalSwipeDeliveredWithoutMovesSelectsNoTab() {
        show()

        tab("Library").performTouchInput {
            down(center)
            updatePointerTo(0, center + Offset(400f, 0f))
            up()
        }
        compose.waitForIdle()

        assertEquals(emptyList<HearthTab>(), selections)
        assertEquals(0, opened)
    }

    @Test
    fun swipeUpWithoutAnItemSelectsNoTab() {
        show(withItem = false)

        tab("Podcasts").performTouchInput {
            down(center)
            updatePointerTo(0, center - Offset(0f, 600f))
            up()
        }
        compose.waitForIdle()

        assertEquals(emptyList<HearthTab>(), selections)
        assertEquals(0, opened)
    }

    @Test
    fun hiddenShortcutCannotBeOpenedBySwipingTheTabs() {
        show(showShortcut = false)
        tab("Podcasts").performTouchInput {
            down(center)
            updatePointerTo(0, center - Offset(0f, 600f))
            up()
        }
        compose.waitForIdle()
        assertEquals(0, opened)
        assertEquals(emptyList<HearthTab>(), selections)
        tab("Library").performClick()
        assertEquals(listOf(HearthTab.LIBRARY), selections)
    }

    @Test
    fun horizontalSwipeAcrossTheTabsSelectsNoTab() {
        show()

        tab("Library").performTouchInput { swipeRight(startX = centerX, endX = centerX + 400f) }
        compose.waitForIdle()

        assertEquals(emptyList<HearthTab>(), selections)
        assertEquals(0, opened)
    }
}
