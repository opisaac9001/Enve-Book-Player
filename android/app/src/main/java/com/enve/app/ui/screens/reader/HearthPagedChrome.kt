package com.enve.app.ui.screens.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.setProgress
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.enve.engine.eink.EinkMode
import com.enve.engine.eink.EinkState
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthEink
import com.enve.hearth.design.HearthPalette
import com.enve.hearth.design.HearthText
import kotlin.math.roundToInt

internal fun hearthEinkFor(palette: HearthPalette, active: Boolean): HearthEink =
    if (active) HearthEink(EinkState(true, palette.bg == Color.White, EinkMode.ON, false, 2)) else HearthEink.Inactive

@Composable
internal fun BoxScope.VeilSlot(visible: Boolean, fromTop: Boolean, content: @Composable () -> Unit) {
    val alignment = if (fromTop) Alignment.TopCenter else Alignment.BottomCenter
    if (Hearth.eink.active) {
        if (visible) Box(Modifier.align(alignment)) { content() }
    } else {
        AnimatedVisibility(
            visible = visible,
            enter = slideInVertically { if (fromTop) -it else it },
            exit = slideOutVertically { if (fromTop) -it else it },
            modifier = Modifier.align(alignment),
        ) {
            content()
        }
    }
}

@Composable
internal fun VeilGlyph(icon: ImageVector, cd: String, tint: Color, onClick: () -> Unit, enabled: Boolean = true) {
    Box(
        Modifier.size(48.dp).clip(CircleShape).clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, cd, tint = if (enabled) tint else tint.copy(alpha = 0.35f), modifier = Modifier.size(24.dp))
    }
}

@Composable
internal fun VeilAction(icon: ImageVector, label: String, onClick: () -> Unit) {
    val palette = Hearth.palette
    Column(
        Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 48.dp).clip(RoundedCornerShape(Hearth.Radius.Inner))
            .clickable(role = Role.Button, onClick = onClick).padding(Hearth.Spacing.S),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(icon, null, tint = palette.textSecondary, modifier = Modifier.size(22.dp))
        Text(label, style = HearthText.Overline, color = palette.textSecondary)
    }
}

@Composable
internal fun PageRibbon(displayPage: Int, pageCount: Int, onScrub: (Int) -> Unit, onCommit: (Int) -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val scrub by rememberUpdatedState(onScrub)
    val commit by rememberUpdatedState(onCommit)
    val last = (pageCount - 1).coerceAtLeast(0)
    val fraction = if (last > 0) (displayPage.toFloat() / last).coerceIn(0f, 1f) else 1f
    fun pageAt(x: Float, width: Int): Int = ((x / width) * last).roundToInt().coerceIn(0, last)
    Canvas(
        Modifier.fillMaxWidth().height(48.dp)
            .semantics {
                contentDescription = "Page position"
                stateDescription = "Page ${displayPage + 1} of $pageCount"
                progressBarRangeInfo = ProgressBarRangeInfo(
                    displayPage.toFloat().coerceIn(0f, last.toFloat()), 0f..last.toFloat(), (last - 1).coerceAtLeast(0),
                )
                setProgress { value -> commit(value.roundToInt().coerceIn(0, last)); true }
            }
            .pointerInput(pageCount) {
                detectTapGestures { o -> commit(pageAt(o.x, size.width)) }
            }
            .pointerInput(pageCount) {
                var target = 0
                detectHorizontalDragGestures(
                    onDragStart = { o -> target = pageAt(o.x, size.width); scrub(target) },
                    onHorizontalDrag = { c, _ -> target = pageAt(c.position.x, size.width); scrub(target) },
                    onDragEnd = { commit(target) },
                    onDragCancel = { commit(target) },
                )
            },
    ) {
        val h = if (eink.active) 5.dp.toPx() else 3.dp.toPx()
        val y = size.height / 2f
        val fill = if (eink.monochrome) palette.text else palette.ember
        drawLine(palette.hairline, Offset(0f, y), Offset(size.width, y), h, StrokeCap.Round)
        drawLine(fill, Offset(0f, y), Offset(size.width * fraction, y), h, StrokeCap.Round)
        drawCircle(fill, h * 1.8f, Offset(size.width * fraction, y))
    }
}
