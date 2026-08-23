package com.enve.hearth.shell

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
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

    val surface = Modifier
        .fillMaxWidth()
        .navigationBarsPadding()
        .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.S)
        .then(if (eink.suppressShadows) Modifier else Modifier.shadow(16.dp, shape, clip = false))
        .clip(shape)
        .background(palette.bgElevated)
        .border(1.dp, palette.hairline, shape)
        .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS)

    Row(modifier.then(surface), verticalAlignment = Alignment.CenterVertically) {
        if (hasItem) {
            EmberPill(
                book = lastOpenedBook,
                now = nowPlaying,
                transport = transport,
                subtitle = subtitle,
                onOpenItem = onOpenItem,
                onItemAction = onItemAction,
                modifier = Modifier.weight(1f),
            )
            Box(
                Modifier
                    .padding(horizontal = Hearth.Spacing.XS)
                    .width(1.dp)
                    .height(30.dp)
                    .background(palette.hairline),
            )
            HearthTab.entries.forEach { tab ->
                CompactTab(tab, tab == selected, onSelect)
            }
        } else {
            HearthTab.entries.forEach { tab ->
                TabItem(tab, tab == selected, onSelect, Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun TabItem(tab: HearthTab, selected: Boolean, onSelect: (HearthTab) -> Unit, modifier: Modifier) {
    val palette = Hearth.palette
    val tint = if (selected) palette.ember else palette.textTertiary
    Column(
        modifier
            .clip(RoundedCornerShape(Hearth.Radius.Inner))
            .clickable { onSelect(tab) }
            .heightIn(min = 48.dp)
            .padding(vertical = Hearth.Spacing.S),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(tab.glyph, contentDescription = tab.label, tint = tint, modifier = Modifier.size(22.dp))
        Text(tab.label, style = HearthText.Overline, color = tint)
    }
}

@Composable
private fun CompactTab(tab: HearthTab, selected: Boolean, onSelect: (HearthTab) -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else CircleShape
    val tint = if (selected) palette.ember else palette.textTertiary
    Box(
        Modifier
            .size(48.dp)
            .clip(shape)
            .then(
                when {
                    !selected -> Modifier
                    eink.active -> Modifier.border(1.dp, palette.text, shape)
                    else -> Modifier.background(palette.emberSoft)
                },
            )
            .clickable { onSelect(tab) },
        contentAlignment = Alignment.Center,
    ) {
        Icon(tab.glyph, contentDescription = tab.label, tint = tint, modifier = Modifier.size(22.dp))
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
    val isEbook = book?.mediaType == AppMediaType.EBOOK
    val isActiveAudio = !isEbook && when {
        book == null -> now != null
        else -> now?.bookKey == book.uniqueKey
    }
    val title = book?.title ?: now?.title.orEmpty()
    val author = book?.author ?: now?.author
    val coverUrl = book?.coverUrl ?: now?.coverUrl
    val progress = when {
        isEbook -> (book.epubProgress ?: book.readProgress).coerceIn(0f, 1f)
        isActiveAudio -> transport.progress
        else -> book?.progress ?: 0f
    }
    Row(
        modifier
            .clip(RoundedCornerShape(Hearth.Radius.Inner))
            .clickable(onClick = onOpenItem)
            .padding(Hearth.Spacing.XS),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        PillArtwork(coverUrl, progress)
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
private fun PillArtwork(coverUrl: String?, progress: Float) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Box(Modifier.size(46.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.size(46.dp)) {
            val stroke = 2.5.dp.toPx()
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
        }
        val coverShape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else 6.dp)
        Box(
            Modifier
                .width(28.dp)
                .height(40.dp)
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
