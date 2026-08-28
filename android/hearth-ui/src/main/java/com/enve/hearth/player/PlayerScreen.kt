package com.enve.hearth.player

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.outlined.Bookmark
import androidx.compose.material.icons.outlined.Bedtime
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.automirrored.outlined.Redo
import androidx.compose.material.icons.automirrored.outlined.Undo
import androidx.compose.material.icons.automirrored.outlined.List
import androidx.compose.material.icons.automirrored.outlined.QueueMusic
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberGlow
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay

enum class PlayerSheet { SPEED, SLEEP, CHAPTERS, BOOKMARKS, QUEUE }

@Composable
fun PlayerScreen(
    onDismiss: () -> Unit,
    topAction: @Composable () -> Unit = {},
) {
    val vm: HearthPlayerViewModel = hiltViewModel()
    val transport by vm.transport.collectAsStateWithLifecycle()
    val now by vm.nowPlaying.collectAsStateWithLifecycle()
    val chapters by vm.chapters.collectAsStateWithLifecycle()
    val chapterIndex by vm.currentChapterIndex.collectAsStateWithLifecycle()
    val sleepRemaining by vm.sleepRemainingSec.collectAsStateWithLifecycle()
    val queue by vm.queue.collectAsStateWithLifecycle()
    val skipForwardSeconds by vm.skipForwardSeconds.collectAsStateWithLifecycle()
    val skipBackwardSeconds by vm.skipBackwardSeconds.collectAsStateWithLifecycle()
    val palette = Hearth.palette
    var sheet by remember { mutableStateOf<PlayerSheet?>(null) }

    Box(Modifier.fillMaxSize().background(palette.bgSunken)) {
        EmberGlow(color = palette.ember, playing = transport.isPlaying, modifier = Modifier.fillMaxSize())

        BoxWithConstraints(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding(),
        ) {
            val density = LocalDensity.current
            val widePanel = maxWidth >= 600.dp
            val narrowPanel = maxWidth < 380.dp
            val shortPanel = maxHeight < 760.dp * density.fontScale
            val compactPanel = narrowPanel || shortPanel || Hearth.typeCompact
            val horizontalPadding = when {
                narrowPanel -> Hearth.Spacing.M
                maxWidth < 440.dp -> Hearth.Spacing.L
                else -> Hearth.Spacing.XL
            }
            val coverWidth = minOf(
                (maxWidth - horizontalPadding * 2f) * when {
                    widePanel -> 0.46f
                    compactPanel -> 0.54f
                    else -> 0.62f
                },
                maxHeight * when {
                    shortPanel -> 0.19f
                    widePanel -> 0.28f
                    else -> 0.26f
                },
            )
            val sectionGap = when {
                compactPanel -> Hearth.Spacing.S
                widePanel -> Hearth.Spacing.M
                else -> Hearth.Spacing.XL
            }
            val coverBottomGap = when {
                compactPanel -> Hearth.Spacing.M
                widePanel -> Hearth.Spacing.L
                else -> Hearth.Spacing.XXL
            }
            val playButtonSize = if (compactPanel) 64.dp else 76.dp
            val playIconSize = if (compactPanel) 34.dp else 38.dp
            val transportIconSize = if (compactPanel) 30.dp else 34.dp
            val transportTouchPadding = Hearth.Spacing.S
            val utilityIconSize = if (compactPanel) 20.dp else 22.dp
            val utilityTextSize = if (compactPanel) 9.sp else 10.sp

            Column(
                Modifier.fillMaxSize().padding(horizontal = horizontalPadding),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Row(Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        Modifier
                            .size(48.dp)
                            .clip(CircleShape)
                            .clickable(onClick = onDismiss),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Outlined.KeyboardArrowDown,
                            contentDescription = "Close",
                            tint = palette.textSecondary,
                            modifier = Modifier.size(30.dp),
                        )
                    }
                    Spacer(Modifier.weight(1f))
                    topAction()
                }

                Spacer(Modifier.height(if (compactPanel || widePanel) Hearth.Spacing.S else Hearth.Spacing.L))
                CoverTile(model = now?.coverUrl, modifier = Modifier.width(coverWidth))
                Spacer(Modifier.height(coverBottomGap))

                val chapterTitle = chapters.getOrNull(chapterIndex)?.title
                Overline(
                    when {
                        chapterTitle == null -> "Now playing"
                        chapterTitle.contains("chapter", ignoreCase = true) -> chapterTitle
                        else -> "Chapter ${chapterIndex + 1} · $chapterTitle"
                    },
                )
                Spacer(Modifier.height(Hearth.Spacing.S))
                Text(
                    now?.title ?: "",
                    style = hearthDisplay(if (compactPanel) 20.sp else 24.sp, FontWeight.SemiBold),
                    color = palette.text,
                    maxLines = 2,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth(),
                )
                now?.author?.let {
                    Spacer(Modifier.height(Hearth.Spacing.XS))
                    Text(
                        it,
                        style = HearthText.Body.copy(fontSize = if (compactPanel) 14.sp else 16.sp),
                        color = palette.textSecondary,
                        maxLines = 1,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }

                Spacer(Modifier.height(sectionGap))
                val scrubChapter by vm.scrubChapter.collectAsStateWithLifecycle()
                val chapterNow = chapters.getOrNull(chapterIndex)
                val chapterStartMs = (chapterNow?.startTime ?: 0L) * 1000
                val chapterEndMs = ((chapterNow?.endTime ?: 0L) * 1000).takeIf { it > chapterStartMs }
                    ?: transport.durationMs
                val chapterScope = scrubChapter && chapterNow != null && chapterEndMs > chapterStartMs
                val spanStartMs = if (chapterScope) chapterStartMs else 0L
                val spanLenMs = ((if (chapterScope) chapterEndMs else transport.durationMs) - spanStartMs).coerceAtLeast(1L)
                ChapterScrubber(
                    positionMs = (transport.positionMs - spanStartMs).coerceIn(0L, spanLenMs),
                    durationMs = spanLenMs,
                    chapters = if (chapterScope) emptyList() else chapters.map { it.startTime * 1000f / (transport.durationMs.takeIf { d -> d > 0 } ?: 1L) },
                    onSeek = { fraction -> vm.seekTo(spanStartMs + (fraction * spanLenMs).toLong()) },
                )
                Spacer(Modifier.height(Hearth.Spacing.S))
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(fmt((transport.positionMs - spanStartMs).coerceAtLeast(0)), style = HearthText.Caption, color = palette.textSecondary)
                    Text("-" + fmt((spanStartMs + spanLenMs - transport.positionMs).coerceAtLeast(0)), style = HearthText.Caption, color = palette.textSecondary)
                }
                if (chapters.isNotEmpty()) {
                    Spacer(Modifier.height(Hearth.Spacing.S))
                    Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        HearthChip("Book", selected = !scrubChapter, onClick = { vm.setScrubChapter(false) })
                        HearthChip("Chapter", selected = scrubChapter, onClick = { vm.setScrubChapter(true) })
                    }
                }

                Spacer(Modifier.height(sectionGap))
                val canGoPreviousChapter = chapterIndex > 0 && chapters.isNotEmpty()
                val canGoNextChapter = chapterIndex in 0 until chapters.lastIndex
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        Icon(
                            Icons.Filled.SkipPrevious,
                            contentDescription = "Previous chapter",
                            tint = if (canGoPreviousChapter) palette.text else palette.textSecondary,
                            modifier = Modifier
                                .clip(CircleShape)
                                .clickable(enabled = canGoPreviousChapter) { vm.previousChapter() }
                                .padding(transportTouchPadding)
                                .size(transportIconSize),
                        )
                    }
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        SkipIntervalButton(
                            seconds = skipBackwardSeconds,
                            forward = false,
                            tint = palette.text,
                            iconSize = transportIconSize,
                            touchPadding = transportTouchPadding,
                            onClick = vm::skipBackward,
                        )
                    }
                    Box(
                        Modifier.size(playButtonSize).clip(CircleShape).background(palette.ember).clickable { vm.togglePlay() },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            if (transport.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                            contentDescription = if (transport.isPlaying) "Pause" else "Play",
                            tint = palette.readableOnEmber, modifier = Modifier.size(playIconSize),
                        )
                    }
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        SkipIntervalButton(
                            seconds = skipForwardSeconds,
                            forward = true,
                            tint = palette.text,
                            iconSize = transportIconSize,
                            touchPadding = transportTouchPadding,
                            onClick = vm::skipForward,
                        )
                    }
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        Icon(
                            Icons.Filled.SkipNext,
                            contentDescription = "Next chapter",
                            tint = if (canGoNextChapter) palette.text else palette.textSecondary,
                            modifier = Modifier
                                .clip(CircleShape)
                                .clickable(enabled = canGoNextChapter) { vm.nextChapter() }
                                .padding(transportTouchPadding)
                                .size(transportIconSize),
                        )
                    }
                }

                Spacer(Modifier.weight(1f))
                Row(
                    Modifier.fillMaxWidth().padding(bottom = if (compactPanel) Hearth.Spacing.S else Hearth.Spacing.L),
                    horizontalArrangement = Arrangement.spacedBy(if (compactPanel) Hearth.Spacing.XS else Hearth.Spacing.S),
                ) {
                    UtilityPill(
                        Icons.Outlined.Speed,
                        speedLabel(transport.speed),
                        utilityIconSize,
                        utilityTextSize,
                        Modifier.weight(1f),
                    ) { sheet = PlayerSheet.SPEED }
                    UtilityPill(
                        Icons.Outlined.Bedtime,
                        sleepRemaining?.let { fmt(it * 1000) } ?: "Sleep",
                        utilityIconSize,
                        utilityTextSize,
                        Modifier.weight(1f),
                    ) { sheet = PlayerSheet.SLEEP }
                    UtilityPill(
                        Icons.AutoMirrored.Outlined.List,
                        "Chapters",
                        utilityIconSize,
                        utilityTextSize,
                        Modifier.weight(1f),
                    ) { sheet = PlayerSheet.CHAPTERS }
                    UtilityPill(
                        Icons.Outlined.Bookmark,
                        "Bookmarks",
                        utilityIconSize,
                        utilityTextSize,
                        Modifier.weight(1f),
                    ) { sheet = PlayerSheet.BOOKMARKS }
                    UtilityPill(
                        Icons.AutoMirrored.Outlined.QueueMusic,
                        if (queue.isEmpty()) "Queue" else "Queue ${queue.size}",
                        utilityIconSize,
                        utilityTextSize,
                        Modifier.weight(1f),
                    ) { sheet = PlayerSheet.QUEUE }
                }
            }
        }
    }

    PlayerSheets(sheet = sheet, vm = vm, onDismiss = { sheet = null })
}

@Composable
private fun SkipIntervalButton(
    seconds: Int,
    forward: Boolean,
    tint: Color,
    iconSize: Dp,
    touchPadding: Dp,
    onClick: () -> Unit,
) {
    val direction = if (forward) "forward" else "back"
    Box(
        modifier = Modifier
            .semantics {
                contentDescription = "Skip $direction $seconds seconds"
            }
            .clip(CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(touchPadding)
            .size(iconSize),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            imageVector = if (forward) Icons.AutoMirrored.Outlined.Redo else Icons.AutoMirrored.Outlined.Undo,
            contentDescription = null,
            tint = tint,
            modifier = Modifier.fillMaxSize(),
        )
        Text(
            text = seconds.toString(),
            color = tint,
            fontSize = 9.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun UtilityPill(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    iconSize: Dp,
    textSize: TextUnit,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    Column(
        modifier
            .sizeIn(minHeight = 52.dp)
            .clip(RoundedCornerShape(Hearth.Radius.Inner))
            .clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.XS, vertical = Hearth.Spacing.S),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Icon(icon, contentDescription = label, tint = palette.textSecondary, modifier = Modifier.size(iconSize))
        Text(
            label,
            style = HearthText.Overline.copy(fontSize = textSize, letterSpacing = 0.5.sp),
            color = palette.textSecondary,
            maxLines = 1,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

@Composable
private fun ChapterScrubber(positionMs: Long, durationMs: Long, chapters: List<Float>, onSeek: (Float) -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val progress = if (durationMs > 0) (positionMs.toFloat() / durationMs).coerceIn(0f, 1f) else 0f
    var dragFraction by remember { mutableStateOf<Float?>(null) }
    val shown = dragFraction ?: progress

    Canvas(
        Modifier.fillMaxWidth().height(28.dp).pointerInput(durationMs) {
            detectHorizontalDragGestures(
                onDragStart = { offset -> dragFraction = (offset.x / size.width).coerceIn(0f, 1f) },
                onHorizontalDrag = { change, _ -> dragFraction = (change.position.x / size.width).coerceIn(0f, 1f) },
                onDragEnd = { dragFraction?.let(onSeek); dragFraction = null },
                onDragCancel = { dragFraction = null },
            )
        },
    ) {
        val barH = if (eink.active) 6.dp.toPx() else 4.dp.toPx()
        val y = size.height / 2f
        val fill = if (eink.monochrome) palette.text else palette.ember

        drawLine(palette.hairline, Offset(0f, y), Offset(size.width, y), strokeWidth = barH, cap = StrokeCap.Round)

        drawLine(fill, Offset(0f, y), Offset(size.width * shown, y), strokeWidth = barH, cap = StrokeCap.Round)

        val tickColor = if (palette.isInk) Color.White.copy(alpha = 0.5f) else palette.bg
        chapters.forEach { t ->
            val x = size.width * t.coerceIn(0f, 1f)
            drawLine(tickColor, Offset(x, y - barH), Offset(x, y + barH), strokeWidth = 1.5.dp.toPx())
        }

        drawCircle(fill, radius = barH * 1.6f, center = Offset(size.width * shown, y))
    }
}

private fun fmt(ms: Long): String {
    val s = (ms / 1000).coerceAtLeast(0)
    val h = s / 3600; val m = (s % 3600) / 60; val sec = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%d:%02d".format(m, sec)
}
