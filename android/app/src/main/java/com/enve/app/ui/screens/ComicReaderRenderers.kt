package com.enve.app.ui.screens

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material3.Icon
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import coil.imageLoader
import coil.request.ImageRequest
import com.enve.core.data.model.Book
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.einkAwareBackground
import com.enve.app.viewmodel.ComicPageFit
import com.enve.app.viewmodel.ComicReaderSettings
import com.enve.app.viewmodel.ComicReadingDirection
import kotlinx.coroutines.flow.distinctUntilChanged
import java.io.File
import kotlin.math.abs

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ComicHorizontalPager(
    pages: List<File>,
    availablePages: Set<Int>,
    currentPage: Int,
    spreadActive: Boolean,
    settings: ComicReaderSettings,
    bgColor: Color,
    onPageChange: (Int) -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onToggleChrome: () -> Unit,
    onPagesNeeded: (List<Int>) -> Unit,
    modifier: Modifier = Modifier,
) {
    val entries: List<List<Int>> = remember(pages, spreadActive, settings.spreadMode) {
        buildPageEntries(pages.size, spreadActive)
    }

    val entryIndex = remember(currentPage, entries) {
        entries.indexOfFirst { currentPage in it }.coerceAtLeast(0)
    }

    val ctx = LocalContext.current

    PrefetchComicPages(
        pages = pages,
        availablePages = availablePages,
        currentPage = currentPage,
        spreadActive = spreadActive,
        onPagesNeeded = onPagesNeeded,
    )

    val isRtl = settings.readingDirection == ComicReadingDirection.RIGHT_TO_LEFT

    key(entries, isRtl) {
        val pagerState = rememberPagerState(
            initialPage = entryIndex,
            pageCount = { entries.size },
        )

        LaunchedEffect(pagerState.currentPage, entries) {
            val visible = entries.getOrNull(pagerState.currentPage) ?: return@LaunchedEffect
            if (currentPage !in visible) {
                onPageChange(visible.first())
                (ctx as? ComicReaderActivity)?.refreshEinkAfterPageTurn()
            }
        }

        LaunchedEffect(currentPage, entries) {
            val target = entries.indexOfFirst { currentPage in it }
            if (target >= 0 && target != pagerState.currentPage) {
                pagerState.animateScrollToPage(target)
            }
        }

        HorizontalPager(
            state = pagerState,
            modifier = modifier.background(bgColor),
            reverseLayout = isRtl,
            beyondViewportPageCount = 1,
            key = { idx -> entries.getOrNull(idx)?.joinToString() ?: idx.toString() },
        ) { pageIdx ->
            val pageIndices = entries.getOrElse(pageIdx) { listOf(pageIdx.coerceIn(pages.indices)) }
            LaunchedEffect(pageIndices) { onPagesNeeded(pageIndices) }

            ZoomableComicSpread(
                pageFiles = pageIndices.map { pages[it] },
                pageAvailability = pageIndices.map { it in availablePages },
                pageDescription = pageLabel(pageIndices, pages.size),
                settings = settings,
                bgColor = bgColor,
                onPrevious = onPrevious,
                onNext = onNext,
                isRtl = isRtl,
                onToggleChrome = onToggleChrome,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

internal fun buildPageEntries(pageCount: Int, spreadActive: Boolean): List<List<Int>> {
    if (!spreadActive || pageCount <= 0) return (0 until pageCount).map { listOf(it) }
    val result = mutableListOf<List<Int>>()
    var i = 0
    while (i < pageCount) {
        if (i + 1 < pageCount) {
            result.add(listOf(i, i + 1))
            i += 2
        } else {
            result.add(listOf(i))
            i++
        }
    }
    return result
}

@Composable
private fun ZoomableComicSpread(
    pageFiles: List<File>,
    pageAvailability: List<Boolean>,
    pageDescription: String,
    settings: ComicReaderSettings,
    bgColor: Color,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    isRtl: Boolean,
    onToggleChrome: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var scale by remember(pageFiles) { mutableFloatStateOf(1f) }
    var offset by remember(pageFiles) { mutableStateOf(Offset.Zero) }
    var swipeAccum by remember(pageFiles) { mutableFloatStateOf(0f) }
    var edgePull by remember(pageFiles) { mutableFloatStateOf(0f) }
    var edgePageTurnTriggered by remember(pageFiles) { mutableStateOf(false) }

    Box(
        modifier = modifier
            .background(bgColor)
            .pointerInput(pageFiles, settings.zoomEnabled, scale) {
                detectTapGestures(
                    onDoubleTap = {
                        if (!settings.zoomEnabled) return@detectTapGestures
                        if (scale > 1.05f) {
                            scale = 1f; offset = Offset.Zero
                        } else {
                            scale = 2.5f; offset = Offset.Zero
                        }
                    },
                    onTap = { onToggleChrome() },
                )
            }
            .pointerInput(pageFiles) {
                awaitEachGesture {
                    awaitFirstDown(requireUnconsumed = false)
                    do {
                        val event = awaitPointerEvent()
                    } while (event.changes.any { it.pressed })
                    edgePull = 0f
                    edgePageTurnTriggered = false
                }
            }
            .pointerInput(pageFiles, settings.zoomEnabled, isRtl) {
                if (!settings.zoomEnabled) return@pointerInput
                detectTransformGestures { _, pan, zoom, _ ->
                    val newScale = (scale * zoom).coerceIn(1f, 5f)
                    val maximumOffsetX = size.width * (newScale - 1f) / 2f
                    val maximumOffsetY = size.height * (newScale - 1f) / 2f
                    val proposedOffset = offset + pan
                    val clampedOffset = Offset(
                        x = proposedOffset.x.coerceIn(-maximumOffsetX, maximumOffsetX),
                        y = proposedOffset.y.coerceIn(-maximumOffsetY, maximumOffsetY),
                    )

                    if (newScale <= 1.02f || abs(zoom - 1f) >= 0.01f) {
                        edgePull = 0f
                    } else {
                        val overflow = proposedOffset.x - clampedOffset.x
                        if (abs(pan.x) > abs(pan.y) && abs(overflow) > 0.5f) {
                            if (edgePull != 0f && edgePull * overflow < 0f) edgePull = 0f
                            edgePull += overflow
                            if (!edgePageTurnTriggered && abs(edgePull) >= 56.dp.toPx()) {
                                edgePageTurnTriggered = true
                                when {
                                    edgePull > 0f && isRtl -> onNext()
                                    edgePull > 0f -> onPrevious()
                                    isRtl -> onPrevious()
                                    else -> onNext()
                                }
                            }
                        } else if (abs(overflow) <= 0.5f) {
                            edgePull = 0f
                        }
                    }

                    scale = newScale
                    offset = if (newScale <= 1.02f) Offset.Zero else clampedOffset
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(
            modifier = Modifier
                .matchParentSize()
                .pointerInput(pageFiles, scale) {
                    detectHorizontalDragGestures(
                        onHorizontalDrag = { change, dragAmount ->
                            if (scale > 1.02f) return@detectHorizontalDragGestures
                            change.consume()
                            swipeAccum += dragAmount
                        },
                        onDragEnd = {
                            if (scale > 1.02f) {
                                swipeAccum = 0f
                                return@detectHorizontalDragGestures
                            }
                            val threshold = 56f
                            val swipedLeft = swipeAccum <= -threshold
                            val swipedRight = swipeAccum >= threshold
                            when {
                                swipedLeft && !isRtl -> onNext()
                                swipedRight && !isRtl -> onPrevious()
                                swipedRight && isRtl -> onNext()
                                swipedLeft && isRtl -> onPrevious()
                            }
                            swipeAccum = 0f
                        },
                        onDragCancel = {
                            swipeAccum = 0f
                        },
                    )
                },
        )

        Row(
            modifier = Modifier
                .fillMaxSize()
                .graphicsLayer {
                    scaleX = scale; scaleY = scale
                    translationX = offset.x; translationY = offset.y
                },
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (pageFiles.size == 2) {
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxSize(),
                    contentAlignment = Alignment.CenterEnd,
                ) {
                    ComicPageImage(
                        file = pageFiles[0],
                        available = pageAvailability[0],
                        description = "$pageDescription img 1",
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Fit,
                        alignment = Alignment.CenterEnd,
                    )
                }

                Spacer(
                    Modifier
                        .width(1.dp)
                        .fillMaxHeight()
                        .background(Color.White.copy(alpha = 0.08f)),
                )

                Box(
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxSize(),
                    contentAlignment = Alignment.CenterStart,
                ) {
                    ComicPageImage(
                        file = pageFiles[1],
                        available = pageAvailability[1],
                        description = "$pageDescription img 2",
                        modifier = Modifier.fillMaxSize(),
                        contentScale = ContentScale.Fit,
                        alignment = Alignment.CenterStart,
                    )
                }
            } else {
                pageFiles.forEachIndexed { idx, file ->
                    ComicPageImage(
                        file = file,
                        available = pageAvailability[idx],
                        description = "$pageDescription img ${idx + 1}",
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight(),
                        contentScale = settings.pageFit.toContentScale(),
                    )
                    if (idx < pageFiles.lastIndex) {
                        Spacer(
                            Modifier
                                .width(1.dp)
                                .fillMaxHeight()
                                .background(Color.White.copy(alpha = 0.08f)),
                        )
                    }
                }
            }
        }
    }
}

@Composable
internal fun ComicVerticalStrip(
    pages: List<File>,
    availablePages: Set<Int>,
    currentPage: Int,
    fit: ComicPageFit,
    bgColor: Color,
    onPageVisible: (Int) -> Unit,
    onToggleChrome: () -> Unit,
    onPagesNeeded: (List<Int>) -> Unit,
    modifier: Modifier = Modifier,
) {
    val listState = rememberLazyListState(initialFirstVisibleItemIndex = currentPage.coerceIn(0, pages.lastIndex))
    LaunchedEffect(listState) {
        snapshotFlow { listState.firstVisibleItemIndex }
            .distinctUntilChanged()
            .collect { onPageVisible(it.coerceIn(0, pages.lastIndex)) }
    }

    LazyColumn(
        state = listState,
        modifier = modifier
            .background(bgColor)
            .pointerInput(Unit) {
                detectTapGestures(onTap = { onToggleChrome() })
            },
        verticalArrangement = Arrangement.spacedBy(2.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        itemsIndexed(pages, key = { i, f -> "$i:${f.absolutePath}" }) { i, file ->
            LaunchedEffect(i) { onPagesNeeded(listOf(i)) }
            ComicPageImage(
                file = file,
                available = i in availablePages,
                description = "Page ${i + 1}",
                modifier = Modifier.fillMaxWidth(),
                contentScale = when (fit) {
                    ComicPageFit.FIT_HEIGHT -> ContentScale.Fit
                    ComicPageFit.ORIGINAL_SIZE -> ContentScale.None
                    else -> ContentScale.FillWidth
                },
            )
        }
    }
}

@Composable
private fun PrefetchComicPages(
    pages: List<File>,
    availablePages: Set<Int>,
    currentPage: Int,
    spreadActive: Boolean,
    onPagesNeeded: (List<Int>) -> Unit,
) {
    val context = LocalContext.current
    LaunchedEffect(pages, availablePages, currentPage, spreadActive) {
        if (pages.isEmpty()) return@LaunchedEffect
        val radius = if (spreadActive) 6 else 3
        val nearby = ((currentPage - radius)..(currentPage + radius)).filter { it in pages.indices }
        onPagesNeeded(nearby)
        nearby
            .filter { it in availablePages && it != currentPage }
            .forEach { idx ->
                context.imageLoader.enqueue(
                    ImageRequest.Builder(context)
                        .data(pages[idx])
                        .memoryCacheKey(pages[idx].absolutePath)
                        .diskCacheKey(pages[idx].absolutePath)
                        .build(),
                )
            }
    }
}

@Composable
private fun ComicPageImage(
    file: File,
    available: Boolean,
    description: String,
    modifier: Modifier,
    contentScale: ContentScale,
    alignment: Alignment = Alignment.Center,
) {
    Box(modifier = modifier, contentAlignment = Alignment.Center) {
        if (available) {
            AsyncImage(
                model = file,
                contentDescription = description,
                modifier = Modifier.fillMaxSize(),
                contentScale = contentScale,
                alignment = alignment,
            )
        } else {
            CircularProgressIndicator()
        }
    }
}

private fun ComicPageFit.toContentScale(): ContentScale = when (this) {
    ComicPageFit.FIT_SCREEN -> ContentScale.Fit
    ComicPageFit.FIT_WIDTH -> ContentScale.FillWidth
    ComicPageFit.FIT_HEIGHT -> ContentScale.FillHeight
    ComicPageFit.ORIGINAL_SIZE -> ContentScale.None
}

@Composable
internal fun NextInSeriesButton(
    book: Book,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val accent = colors.accent
    val onAccent = colors.onAccent
    val visible = remember { mutableStateOf(false) }
    LaunchedEffect(book.id) { visible.value = true }

    AnimatedVisibility(
        visible = visible.value,
        enter = fadeIn(tween(280)) + slideInVertically(tween(360)) { it },
        modifier = modifier,
    ) {
        Surface(
            onClick = onClick,
            shape = RoundedCornerShape(20.dp),
            color = colors.cardBackground,
            shadowElevation = 12.dp,
            border = BorderStroke(1.5.dp, accent.copy(alpha = 0.6f)),
            modifier = Modifier.widthIn(max = 360.dp),
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .einkAwareBackground(
                        brush = Brush.horizontalGradient(
                            listOf(accent.copy(alpha = 0.18f), Color.Transparent),
                        ),
                        einkFill = Color.Transparent,
                    )
                    .padding(10.dp),
            ) {
                AsyncImage(
                    model = book.coverUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(width = 52.dp, height = 76.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(colors.secondaryBackground),
                )
                Spacer(Modifier.width(14.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(
                            modifier = Modifier
                                .size(6.dp)
                                .clip(CircleShape)
                                .background(accent),
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "NEXT IN SERIES",
                            color = accent,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Bold,
                            letterSpacing = 1.sp,
                        )
                    }
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = book.title,
                        color = colors.primaryText,
                        fontSize = 15.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        lineHeight = 18.sp,
                    )
                    book.seriesNumber?.takeIf { it.isNotBlank() }?.let { num ->
                        Text(
                            text = "Volume $num",
                            color = colors.tertiaryText,
                            fontSize = 11.sp,
                            fontWeight = FontWeight.Medium,
                        )
                    } ?: book.author?.takeIf { it.isNotBlank() }?.let { author ->
                        Text(
                            text = author,
                            color = colors.tertiaryText,
                            fontSize = 11.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                Spacer(Modifier.width(10.dp))
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(accent),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.ArrowForward,
                        contentDescription = null,
                        tint = onAccent,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}
