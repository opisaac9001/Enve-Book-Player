package com.enve.app.ui.screens.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBarsIgnoringVisibility
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.viewmodel.ReadAloudClipRow
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.Overline

@OptIn(ExperimentalFoundationApi::class, ExperimentalLayoutApi::class)
@Composable
fun HearthReadAloudLyrics(
    rows: List<ReadAloudClipRow>,
    activeIndex: Int,
    onSelect: (ReadAloudClipRow) -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
    onToggleControls: () -> Unit = {},
) {
    val palette = Hearth.palette
    val spoken = rows.filter { it.text.isNotBlank() }
    val listState = rememberLazyListState()
    val activePosition = spoken.indexOfFirst { it.index == activeIndex }

    LaunchedEffect(activePosition) {
        if (activePosition >= 0) listState.animateScrollToItem(activePosition, -220)
    }

    val blocker = remember { MutableInteractionSource() }
    Box(
        modifier.fillMaxSize()
            .background(palette.bg)
            .clickable(interactionSource = blocker, indication = null, onClick = onToggleControls),
    ) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.statusBarsIgnoringVisibility)) {
            Row(
                Modifier.fillMaxWidth().padding(
                    start = Hearth.Spacing.XL,
                    end = Hearth.Spacing.S,
                    top = Hearth.Spacing.XXS,
                    bottom = Hearth.Spacing.XXS,
                ),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Overline("Read mode")
                Box(
                    Modifier.size(48.dp).clip(CircleShape).clickable(role = Role.Button, onClick = onClose),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Outlined.Close,
                        "Close read mode",
                        tint = palette.textSecondary,
                        modifier = Modifier.size(28.dp),
                    )
                }
            }

            if (spoken.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        "No narrated text for this chapter.",
                        style = HearthText.Caption,
                        color = palette.textSecondary,
                    )
                }
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier.fillMaxSize().padding(horizontal = Hearth.Spacing.XL),
                    contentPadding = PaddingValues(
                        top = Hearth.Spacing.L,
                        bottom = READ_MODE_BAR_INSET,
                    ),
                ) {
                    items(spoken, key = { it.index }) { row ->
                        val current = row.index == activeIndex
                        Text(
                            row.text,
                            style = if (current) ACTIVE_LINE else RESTING_LINE,
                            color = if (current) palette.text else palette.textTertiary,
                            modifier = Modifier.fillMaxWidth()
                                .testTag(READ_MODE_LINE_TAG)
                                .combinedClickable(
                                    onClick = onToggleControls,
                                    onDoubleClick = { onSelect(row) },
                                    onLongClickLabel = "Play from here",
                                    onLongClick = { onSelect(row) },
                                )
                                .padding(vertical = Hearth.Spacing.M),
                        )
                    }
                }
            }
        }
    }
}

const val READ_MODE_LINE_TAG = "ReadMode.Line"

private val READ_MODE_BAR_INSET = 140.dp

private val ACTIVE_LINE = hearthDisplay(20.sp, FontWeight.SemiBold).copy(lineHeight = 30.sp)
private val RESTING_LINE = hearthDisplay(17.sp, FontWeight.Normal).copy(lineHeight = 27.sp)
