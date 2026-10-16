package com.enve.hearth.shell

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathMeasure
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.playback.NowPlaying
import com.enve.engine.playback.PlaybackTransport
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalHearthImageLoader
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.rememberCoverImageModel
import kotlin.math.abs

@Composable
fun MantelBar(
    selected: HearthTab,
    onSelect: (HearthTab) -> Unit,
    lastOpenedBook: Book?,
    nowPlaying: NowPlaying?,
    transport: PlaybackTransport,
    subtitle: String?,
    onOpenItem: () -> Unit,
    onItemAction: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 10.dp else Hearth.Radius.Bar)
    val hasItem = lastOpenedBook != null || nowPlaying != null
    val openItem by rememberUpdatedState(onOpenItem)
    val canOpenItem by rememberUpdatedState(hasItem)

    val surface = Modifier
        .fillMaxWidth()
        .navigationBarsPadding()
        .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.S)
        .then(if (eink.suppressShadows) Modifier else Modifier.shadow(16.dp, shape, clip = false))
        .clip(shape)
        .background(palette.bgElevated)
        .border(1.dp, palette.hairline, shape)
        .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS)

    Column(modifier.then(surface).openItemSwipe { if (canOpenItem) openItem() }) {
        if (hasItem) {
            EmberPill(
                book = lastOpenedBook,
                now = nowPlaying,
                transport = transport,
                subtitle = subtitle,
                onOpenItem = onOpenItem,
                onItemAction = onItemAction,
                modifier = Modifier.fillMaxWidth(),
            )
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(vertical = Hearth.Spacing.XS)
                    .height(1.dp)
                    .background(palette.hairline),
            )
        }
        BoxWithConstraints(Modifier.fillMaxWidth().selectableGroup()) {
            val measurer = rememberTextMeasurer()
            val tabWidthPx = with(LocalDensity.current) {
                ((maxWidth - Hearth.Spacing.XXL * 2) / HearthTab.entries.size).roundToPx()
            }
            val labelsFitInline = remember(measurer, tabWidthPx) {
                HearthTab.entries.all { tab ->
                    measurer.measure(tab.label, HearthText.Overline, maxLines = 1, softWrap = false).size.width <= tabWidthPx
                }
            }
            if (labelsFitInline) {
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XXL),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    HearthTab.entries.forEach { tab ->
                        TabItem(tab, tab == selected, onSelect, Modifier.weight(1f))
                    }
                }
            } else {
                Column(Modifier.fillMaxWidth()) {
                    HearthTab.entries.chunked(2).forEach { pair ->
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            pair.forEach { tab ->
                                GridTabItem(tab, tab == selected, onSelect, Modifier.weight(1f))
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun Modifier.openItemSwipe(onOpen: () -> Unit): Modifier = pointerInput(Unit) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        val velocity = VelocityTracker().apply { addPointerInputChange(down) }
        var claimed = false
        var end = down.position
        while (true) {
            val change = awaitPointerEvent(PointerEventPass.Initial).changes.firstOrNull { it.id == down.id } ?: return@awaitEachGesture
            velocity.addPointerInputChange(change)
            end = change.position
            if (!claimed && (end - down.position).getDistance() > viewConfiguration.touchSlop) claimed = true
            if (claimed) change.consume()
            if (!change.pressed) break
        }
        if (!claimed) return@awaitEachGesture
        val rise = down.position.y - end.y
        val fastRise = rise >= 16.dp.toPx() && velocity.calculateVelocity().y <= -600.dp.toPx()
        if (rise > abs(end.x - down.position.x) && (rise >= 44.dp.toPx() || fastRise)) onOpen()
    }
}

@Composable
private fun TabItem(tab: HearthTab, selected: Boolean, onSelect: (HearthTab) -> Unit, modifier: Modifier) {
    val palette = Hearth.palette
    val tint = if (selected) palette.ember else palette.textTertiary
    Column(
        modifier
            .clip(RoundedCornerShape(Hearth.Radius.Inner))
            .selectable(selected = selected, role = Role.Tab) { onSelect(tab) }
            .heightIn(min = 48.dp)
            .padding(vertical = Hearth.Spacing.S),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(tab.glyph, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        Text(tab.label, style = HearthText.Overline, color = tint, maxLines = 1, softWrap = false)
    }
}

@Composable
private fun GridTabItem(tab: HearthTab, selected: Boolean, onSelect: (HearthTab) -> Unit, modifier: Modifier) {
    val palette = Hearth.palette
    val tint = if (selected) palette.ember else palette.textTertiary
    Row(
        modifier
            .clip(RoundedCornerShape(Hearth.Radius.Inner))
            .selectable(selected = selected, role = Role.Tab) { onSelect(tab) }
            .heightIn(min = 48.dp)
            .padding(Hearth.Spacing.S),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(tab.glyph, contentDescription = null, tint = tint, modifier = Modifier.size(22.dp))
        Text(tab.label, style = HearthText.Overline, color = tint, modifier = Modifier.weight(1f, fill = false))
    }
}

@Composable
private fun EmberPill(
    book: Book?,
    now: NowPlaying?,
    transport: PlaybackTransport,
    subtitle: String?,
    onOpenItem: () -> Unit,
    onItemAction: () -> Unit,
    modifier: Modifier,
) {
    val palette = Hearth.palette
    val isActiveAudio = when {
        book == null -> now != null
        else -> now?.bookKey == book.uniqueKey
    }
    val isEbook = !isActiveAudio && book?.mediaType == AppMediaType.EBOOK
    val title = book?.title ?: now?.title.orEmpty()
    val author = book?.author ?: now?.author
    val coverUrl = book?.coverUrl ?: now?.coverUrl
    val mediaType = book?.mediaType ?: now?.let { AppMediaType.AUDIOBOOK }
    val progress = when {
        isEbook -> (book.epubProgress ?: book.readProgress).coerceIn(0f, 1f)
        isActiveAudio -> transport.progress
        else -> book?.progress ?: 0f
    }
    Row(
        modifier
            .clip(RoundedCornerShape(Hearth.Radius.Inner))
            .clickable(onClick = onOpenItem)
            .semantics {
                customActions = listOf(CustomAccessibilityAction(if (isEbook) "Open book" else "Open player") { onOpenItem(); true })
            }
            .padding(Hearth.Spacing.XS),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PillArtwork(coverUrl, mediaType, progress)
        Spacer(Modifier.width(Hearth.Spacing.S))
        val line2 = if (isActiveAudio) subtitle ?: author else author
        Column(Modifier.weight(1f)) {
            Text(
                title,
                style = hearthDisplay(13.sp, FontWeight.SemiBold),
                color = palette.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            if (!line2.isNullOrBlank()) {
                Text(
                    line2,
                    style = HearthText.Overline,
                    color = palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        val isPlaying = isActiveAudio && transport.isPlaying
        Box(
            Modifier
                .size(48.dp)
                .clip(CircleShape)
                .clickable(onClick = onItemAction),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = when {
                    isEbook -> Icons.AutoMirrored.Outlined.MenuBook
                    isPlaying -> Icons.Filled.Pause
                    else -> Icons.Filled.PlayArrow
                },
                contentDescription = when {
                    isEbook -> "Open book"
                    isPlaying -> "Pause"
                    else -> "Play"
                },
                tint = palette.text,
                modifier = Modifier.size(26.dp),
            )
        }
    }
}

@Composable
private fun PillArtwork(coverUrl: String?, mediaType: AppMediaType?, progress: Float) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val isListening = mediaType == AppMediaType.AUDIOBOOK || mediaType == AppMediaType.PODCAST
    Box(Modifier.size(46.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(46.dp)) {
            val stroke = 2.5.dp.toPx()
            if (isListening) {
                val inset = stroke / 2f
                val arcSize = Size(size.width - stroke, size.height - stroke)
                val topLeft = Offset(inset, inset)

                if (!eink.monochrome) {
                    drawArc(palette.hairline, -90f, 360f, false, topLeft, arcSize, style = Stroke(stroke))
                }
                drawArc(
                    color = if (eink.monochrome) palette.text else palette.ember,
                    startAngle = -90f, sweepAngle = 360f * progress.coerceIn(0f, 1f),
                    useCenter = false, topLeft = topLeft, size = arcSize,
                    style = Stroke(stroke, cap = StrokeCap.Round),
                )
            } else {
                val trackWidth = 34.dp.toPx() - stroke
                val trackHeight = 46.dp.toPx() - stroke
                val left = (size.width - trackWidth) / 2f
                val top = (size.height - trackHeight) / 2f
                val right = left + trackWidth
                val bottom = top + trackHeight
                val radius = if (eink.sharpCorners) 0f else 8.dp.toPx()
                val diameter = radius * 2f
                val track = Path().apply {
                    moveTo(center.x, top)
                    lineTo(right - radius, top)
                    arcTo(Rect(right - diameter, top, right, top + diameter), -90f, 90f, false)
                    lineTo(right, bottom - radius)
                    arcTo(Rect(right - diameter, bottom - diameter, right, bottom), 0f, 90f, false)
                    lineTo(left + radius, bottom)
                    arcTo(Rect(left, bottom - diameter, left + diameter, bottom), 90f, 90f, false)
                    lineTo(left, top + radius)
                    arcTo(Rect(left, top, left + diameter, top + diameter), 180f, 90f, false)
                    close()
                }

                if (!eink.monochrome) {
                    drawPath(track, palette.hairline, style = Stroke(stroke))
                }
                val measure = PathMeasure().apply { setPath(track, false) }
                val completed = Path()
                measure.getSegment(0f, measure.length * progress.coerceIn(0f, 1f), completed, true)
                drawPath(
                    completed,
                    if (eink.monochrome) palette.text else palette.ember,
                    style = Stroke(stroke, cap = StrokeCap.Round),
                )
            }
        }
        val coverShape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else 6.dp)
        Box(
            Modifier
                .then(
                    if (isListening) {
                        Modifier.size(36.dp)
                    } else {
                        Modifier.width(28.dp).height(40.dp)
                    },
                )
                .clip(coverShape)
                .background(if (eink.active) palette.bgElevated else palette.emberSoft)
                .then(if (eink.active) Modifier.border(1.dp, palette.text, coverShape) else Modifier),
        ) {
            if (coverUrl != null) {
                val loader = LocalHearthImageLoader.current
                val imageModel = rememberCoverImageModel(coverUrl)
                if (loader != null) {
                    AsyncImage(imageModel, null, loader, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                } else {
                    AsyncImage(imageModel, null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                }
            } else {
                Icon(
                    Icons.AutoMirrored.Outlined.MenuBook,
                    contentDescription = null,
                    tint = palette.textTertiary,
                    modifier = Modifier.size(16.dp).align(Alignment.Center),
                )
            }
        }
    }
}
