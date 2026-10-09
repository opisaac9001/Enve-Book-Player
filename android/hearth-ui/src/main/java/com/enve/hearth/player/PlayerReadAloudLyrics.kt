package com.enve.hearth.player

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.engine.playback.PlayerReadAloudState
import com.enve.engine.playback.ReadAloudLyricLine
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first

@Composable
fun PlayerReadAloudLyrics(
    state: PlayerReadAloudState,
    onSeek: (ReadAloudLyricLine) -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Cover)

    BoxWithConstraints(
        modifier
            .clip(shape)
            .background(if (eink.active) palette.bgElevated else palette.bgElevated.copy(alpha = 0.72f))
            .then(if (eink.active) Modifier else Modifier.background(palette.ember.copy(alpha = 0.12f)))
            .then(
                if (eink.borderInsteadOfShadow) {
                    Modifier.border(1.5.dp, palette.text, shape)
                } else {
                    Modifier.border(1.dp, palette.hairline.copy(alpha = 0.7f), shape)
                },
            )
            .testTag("Player.ReadMode"),
        contentAlignment = Alignment.Center,
    ) {
        if (state.lines.isEmpty()) {
            Column(
                Modifier.padding(horizontal = Hearth.Spacing.XXL),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.MenuBook,
                    contentDescription = null,
                    tint = palette.textSecondary.copy(alpha = 0.5f),
                    modifier = Modifier.size(22.dp),
                )
                Text(
                    state.error ?: if (state.loading) "Preparing the narration…" else "No narrated text for this chapter.",
                    style = hearthUI(12.sp),
                    color = palette.textSecondary,
                    textAlign = TextAlign.Center,
                )
            }
        } else {
            ReadAloudLines(
                lines = state.lines,
                activeLineId = state.activeLineId,
                topPadding = maxHeight * 0.42f,
                bottomPadding = maxHeight * 0.34f,
                onSeek = onSeek,
            )
        }
    }
}

@Composable
private fun ReadAloudLines(
    lines: List<ReadAloudLyricLine>,
    activeLineId: String?,
    topPadding: Dp,
    bottomPadding: Dp,
    onSeek: (ReadAloudLyricLine) -> Unit,
) {
    val eink = Hearth.eink
    val animate = !eink.suppressAnimations && !Hearth.reduceMotion
    val listState = rememberLazyListState()
    val chapterKey = lines.first().id
    var centeredChapterKey by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(chapterKey, activeLineId, lines.size) {
        val index = lines.indexOfFirst { it.id == activeLineId }
        if (index < 0) return@LaunchedEffect
        listState.center(index, animate = animate && centeredChapterKey == chapterKey)
        centeredChapterKey = chapterKey
    }

    LazyColumn(
        state = listState,
        contentPadding = PaddingValues(
            start = Hearth.Spacing.XL,
            end = Hearth.Spacing.XL,
            top = topPadding,
            bottom = bottomPadding,
        ),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS),
        modifier = Modifier
            .fillMaxSize()
            .then(if (eink.suppressGradients) Modifier else Modifier.fadeEdges()),
    ) {
        items(lines, key = { it.id }) { line ->
            ReadAloudLine(line, active = line.id == activeLineId, animate = animate, onSeek = onSeek)
        }
    }
}

@Composable
private fun ReadAloudLine(
    line: ReadAloudLyricLine,
    active: Boolean,
    animate: Boolean,
    onSeek: (ReadAloudLyricLine) -> Unit,
) {
    val palette = Hearth.palette
    val inactiveColor = if (Hearth.eink.active) palette.textSecondary else palette.text.copy(alpha = 0.4f)
    val color by animateColorAsState(
        targetValue = if (active) palette.text else inactiveColor,
        animationSpec = if (animate) tween(280) else snap(),
        label = "readAloudLineColor",
    )
    Text(
        line.text,
        style = if (active) {
            hearthDisplay(19.sp, FontWeight.SemiBold).copy(lineHeight = 25.sp)
        } else {
            hearthDisplay(16.sp, FontWeight.Normal).copy(lineHeight = 21.sp)
        },
        color = color,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("Player.ReadMode.Line")
            .selectable(selected = active, role = Role.Button) { onSeek(line) }
            .padding(vertical = 7.dp),
    )
}

private fun Modifier.fadeEdges(): Modifier = this
    .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
    .drawWithContent {
        drawContent()
        drawRect(
            Brush.verticalGradient(
                0f to Color.Transparent,
                0.10f to Color.Black.copy(alpha = 0.35f),
                0.30f to Color.Black,
                0.70f to Color.Black,
                0.90f to Color.Black.copy(alpha = 0.35f),
                1f to Color.Transparent,
            ),
            blendMode = BlendMode.DstIn,
        )
    }

private suspend fun LazyListState.center(index: Int, animate: Boolean) {
    if (layoutInfo.visibleItemsInfo.none { it.index == index }) scrollToItem(index)
    val item = snapshotFlow { layoutInfo.visibleItemsInfo.firstOrNull { it.index == index } }
        .filterNotNull()
        .first()
    val viewport = layoutInfo
    val delta = item.offset + item.size / 2f - (viewport.viewportStartOffset + viewport.viewportEndOffset) / 2f
    if (animate) animateScrollBy(delta, tween(400)) else scrollBy(delta)
}
