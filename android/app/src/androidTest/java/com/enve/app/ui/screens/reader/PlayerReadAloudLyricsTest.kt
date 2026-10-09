package com.enve.app.ui.screens.reader

import androidx.compose.foundation.layout.size
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.engine.playback.PlayerReadAloudState
import com.enve.engine.playback.ReadAloudLyricLine
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.player.PlayerReadAloudLyrics
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PlayerReadAloudLyricsTest {
    @get:Rule
    val compose = createComposeRule()

    private val first = ReadAloudLyricLine("chapter1#first", "First narrated sentence.", 0, 0L, 8_000L)
    private val second = ReadAloudLyricLine("chapter2#second", "Second chapter sentence.", 1, 24_000L, 32_000L)

    @Test
    fun activeSentenceIsSelectedAndTapReportsWholeBookPosition() {
        var selected: ReadAloudLyricLine? = null
        compose.setContent {
            HearthTheme {
                PlayerReadAloudLyrics(
                    PlayerReadAloudState("book", true, lines = listOf(second), activeLineId = second.id),
                    onSeek = { selected = it },
                    modifier = Modifier.size(300.dp, 250.dp),
                )
            }
        }
        compose.onNodeWithText(second.text).assertIsDisplayed().assertIsSelected().performClick()
        assertEquals(24_000L, selected?.startMs)
    }

    @Test
    fun chapterChangeCentersTheNewSentence() {
        val state = mutableStateOf(PlayerReadAloudState("book", true, lines = listOf(first), activeLineId = first.id))
        compose.setContent {
            HearthTheme {
                PlayerReadAloudLyrics(state.value, {}, Modifier.size(300.dp, 250.dp))
            }
        }
        compose.onNodeWithText(first.text).assertIsSelected()
        compose.runOnIdle {
            state.value = state.value.copy(lines = listOf(second), activeLineId = second.id)
        }
        compose.onNodeWithText(second.text).assertIsDisplayed().assertIsSelected()
    }
}
