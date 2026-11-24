package com.enve.hearth.shell

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.coerceIn
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.hearthDisplay

internal object HearthPanes {
    val MinTwoPaneWidth = 840.dp
    private val MinListWidth = 360.dp
    private val MaxListWidth = 480.dp
    private const val LIST_FRACTION = 0.4f

    fun listPaneWidth(windowWidth: Dp): Dp? =
        if (windowWidth < MinTwoPaneWidth) null else (windowWidth * LIST_FRACTION).coerceIn(MinListWidth, MaxListWidth)
}

@Composable
internal fun HearthListDetail(
    listWidth: Dp?,
    detail: (@Composable () -> Unit)?,
    list: @Composable () -> Unit,
) {
    val currentList by rememberUpdatedState(list)
    val movableList = remember { movableContentOf { currentList() } }
    if (listWidth == null) {
        movableList()
        return
    }
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxSize()
            .background(palette.bg)
            .windowInsetsPadding(WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal)),
    ) {
        Box(Modifier.width(listWidth).fillMaxHeight().testTag("hearth-list-pane")) { movableList() }
        Box(Modifier.width(1.dp).fillMaxHeight().background(palette.hairline))
        Box(Modifier.weight(1f).fillMaxHeight().testTag("hearth-detail-pane")) {
            if (detail != null) {
                detail()
            } else {
                Column(
                    Modifier.align(Alignment.Center).padding(Hearth.Spacing.XXXL),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        "Choose a book",
                        style = hearthDisplay(22.sp, FontWeight.SemiBold),
                        color = palette.text,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        "Its details open here while the list stays where you left it.",
                        style = HearthText.Body,
                        color = palette.textSecondary,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = Hearth.Spacing.S),
                    )
                }
            }
        }
    }
}
