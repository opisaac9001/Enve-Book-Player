package com.enve.hearth.home

import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.EmberGlow
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.LocalHearthImageLoader
import com.enve.hearth.design.Ribbon
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI
import com.enve.hearth.design.rememberAmbientTint
import com.enve.hearth.design.rememberCoverImageModel
import org.json.JSONObject
import kotlin.math.ceil
import kotlin.math.roundToInt

private const val MAX_PAGE_DOTS = 10

@Composable
internal fun ContinueCarousel(
    title: String,
    books: List<Book>,
    onOpen: (Book) -> Unit,
    onPlay: (Book) -> Unit,
    onSeeAll: () -> Unit,
    onContextBook: (Book) -> Unit,
) {
    val palette = Hearth.palette
    val pagerState = rememberPagerState(pageCount = { books.size })
    val peek = if (books.size > 1) 24.dp else 0.dp

    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader(title, modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), actionLabel = "See all", onAction = onSeeAll)
        HorizontalPager(
            state = pagerState,
            contentPadding = PaddingValues(start = Hearth.Spacing.XL, end = Hearth.Spacing.XL + peek),
            pageSpacing = Hearth.Spacing.M,
            key = { books[it].uniqueKey },
        ) { page ->
            val book = books[page]
            BookCard(book, onOpen = { onOpen(book) }, onPlay = { onPlay(book) }, onLongClick = { onContextBook(book) })
        }
        if (books.size > 1) {
            val current = pagerState.currentPage
            Box(
                Modifier
                    .fillMaxWidth()
                    .semantics { contentDescription = "Book ${current + 1} of ${books.size}" },
                contentAlignment = Alignment.Center,
            ) {
                if (books.size <= MAX_PAGE_DOTS) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        books.indices.forEach { index ->
                            val width by animateDpAsState(if (index == current) 14.dp else 6.dp, label = "pageDot")
                            Box(
                                Modifier
                                    .size(width = width, height = 6.dp)
                                    .clip(CircleShape)
                                    .background(if (index == current) palette.ember else palette.hairline),
                            )
                        }
                    }
                } else {
                    Text(
                        "${current + 1} of ${books.size}",
                        style = hearthUI(11.sp, FontWeight.SemiBold),
                        color = palette.textTertiary,
                    )
                }
            }
        }
    }
}

@Composable
internal fun BookCard(
    book: Book,
    onOpen: () -> Unit,
    onPlay: () -> Unit,
    modifier: Modifier = Modifier,
    prominent: Boolean = false,
    isPlaying: Boolean = false,
    listenTarget: Book? = null,
    readTarget: Book? = null,
    onListen: (Book) -> Unit = {},
    onRead: (Book) -> Unit = {},
    onLongClick: (() -> Unit)? = null,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val tint = rememberAmbientTint(book)
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Card)
    val isEbook = book.mediaType == AppMediaType.EBOOK
    val progress = HearthFormat.progress(book)
    val percent = (progress * 100).roundToInt()
    val coverHeight = if (prominent) 140.dp else 92.dp
    val padding = if (prominent) 18.dp else 14.dp
    val labelStyle = hearthUI(if (prominent) 12.sp else 10.sp, FontWeight.SemiBold)

    Box(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(if (eink.active) 1.5.dp else 1.dp, if (eink.active) palette.text else palette.hairline, shape)
            .then(if (onLongClick == null) Modifier.clickable(onClick = onOpen) else Modifier.combinedClickable(onClick = onOpen, onLongClick = onLongClick)),
    ) {
        if (!eink.active) {
            CardBackdrop(book, tint, Modifier.matchParentSize())
            if (prominent) {
                EmberGlow(color = tint, playing = isPlaying, modifier = Modifier.matchParentSize())
            }
        }
        Column(Modifier.padding(padding), verticalArrangement = Arrangement.spacedBy(if (prominent) Hearth.Spacing.L else Hearth.Spacing.M)) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Ribbon(progress = progress, fill = tint, ticks = if (prominent) HearthFormat.chapterTicks(book) else emptyList())
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                    Text(if (book.isFinished) "Finished" else "$percent% complete", style = labelStyle, color = palette.text)
                    Spacer(Modifier.weight(1f))
                    chapterTitle(book)?.let {
                        Text(it, style = labelStyle, color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(if (prominent) 18.dp else 14.dp)) {
                CoverTile(
                    model = book.coverUrl,
                    ambient = tint,
                    mediaType = book.mediaType,
                    isFinished = book.isFinished,
                    modifier = Modifier.height(coverHeight),
                )
                Column(Modifier.weight(1f).height(coverHeight), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
                    Text(
                        book.title,
                        style = hearthDisplay(if (prominent) 22.sp else 17.sp, if (prominent) FontWeight.Bold else FontWeight.SemiBold),
                        color = palette.text,
                        maxLines = if (prominent) 3 else 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    (book.podcastName ?: book.author)?.let {
                        Text(it, style = hearthUI(if (prominent) 14.sp else 12.sp, FontWeight.Medium), color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                    Spacer(Modifier.weight(1f))
                    Text(book.source.displayName, style = hearthUI(if (prominent) 11.sp else 10.sp, FontWeight.SemiBold), color = palette.textSecondary, maxLines = 1)
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                PositionBar(positionReading(book, progress), tint, prominent, Modifier.weight(1f))
                if (!prominent) {
                    PlayButton(isEbook, book.title, tint, onPlay)
                }
            }
            if (prominent) {
                if (listenTarget != null && readTarget != null) {
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                        val read = @Composable { filled: Boolean ->
                            CardActionButton("Read", Icons.AutoMirrored.Filled.MenuBook, filled, tint, { onRead(readTarget) }, Modifier.weight(1f))
                        }
                        val listen = @Composable { filled: Boolean ->
                            CardActionButton("Listen", Icons.Filled.PlayArrow, filled, tint, { onListen(listenTarget) }, Modifier.weight(1f))
                        }
                        if (isEbook) {
                            read(true)
                            listen(false)
                        } else {
                            listen(true)
                            read(false)
                        }
                    }
                } else {
                    EmberButton(
                        text = when {
                            progress > 0.001f -> "Continue"
                            isEbook -> "Start reading"
                            else -> "Start listening"
                        },
                        onClick = onPlay,
                        leadingIcon = if (isEbook) Icons.AutoMirrored.Filled.MenuBook else Icons.Filled.PlayArrow,
                        tint = tint,
                    )
                }
            }
        }
    }
}

@Composable
private fun CardBackdrop(book: Book, tint: Color, modifier: Modifier) {
    val palette = Hearth.palette
    Box(modifier) {
        book.coverUrl?.let { url ->
            val loader = LocalHearthImageLoader.current
            val imageModel = rememberCoverImageModel(url)
            val imageModifier = Modifier.fillMaxSize().scale(1.4f).blur(40.dp)
            if (loader != null) {
                AsyncImage(imageModel, null, loader, modifier = imageModifier, contentScale = ContentScale.Crop)
            } else {
                AsyncImage(imageModel, null, modifier = imageModifier, contentScale = ContentScale.Crop)
            }
        }
        Box(Modifier.fillMaxSize().background(palette.bg.copy(alpha = 0.6f)))
        Box(Modifier.fillMaxSize().background(Brush.linearGradient(listOf(tint.copy(alpha = 0.2f), Color.Transparent))))
    }
}

private data class PositionReading(val label: String, val detail: String?, val fraction: Float)

@Composable
private fun PositionBar(reading: PositionReading, tint: Color, prominent: Boolean, modifier: Modifier = Modifier) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else 50.dp)
    val style = hearthUI(if (prominent) 13.sp else 11.sp, FontWeight.SemiBold)
    Box(
        modifier
            .heightIn(min = if (prominent) 38.dp else 32.dp)
            .clip(shape)
            .background(if (eink.active) palette.bg else palette.bg.copy(alpha = 0.55f))
            .border(1.dp, if (eink.active) palette.text else palette.hairline, shape),
        contentAlignment = Alignment.CenterStart,
    ) {
        Box(Modifier.matchParentSize()) {
            Box(
                Modifier
                    .fillMaxHeight()
                    .fillMaxWidth(reading.fraction.coerceIn(0f, 1f))
                    .background(if (eink.active) palette.hairline else tint.copy(alpha = 0.35f)),
            )
        }
        Row(
            Modifier.fillMaxWidth().padding(horizontal = if (prominent) 14.dp else Hearth.Spacing.M),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        ) {
            Text(reading.label, style = style, color = palette.text, maxLines = 1, softWrap = false)
            reading.detail?.let {
                Text(
                    it,
                    style = style,
                    color = palette.textSecondary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.End,
                    modifier = Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun CardActionButton(
    text: String,
    icon: ImageVector,
    filled: Boolean,
    tint: Color,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else 50.dp)
    val fill = when {
        eink.active -> palette.bg
        filled -> tint
        else -> palette.bgElevated
    }
    val foreground = when {
        eink.active || !filled -> palette.text
        tint.luminance() < 0.52f -> Color(0xFFFFF7EA)
        else -> palette.onEmber
    }
    Row(
        modifier
            .clip(shape)
            .background(fill)
            .border(if (eink.active && filled) 2.dp else 1.dp, if (eink.active) palette.text else palette.hairline, shape)
            .heightIn(min = 52.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = Hearth.Spacing.M, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = foreground, modifier = Modifier.size(18.dp))
        Text(text, style = hearthUI(16.sp, FontWeight.SemiBold), color = foreground, maxLines = 1, softWrap = false)
    }
}

@Composable
private fun PlayButton(isEbook: Boolean, title: String, tint: Color, onPlay: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val foreground = when {
        eink.active -> palette.text
        tint.luminance() < 0.52f -> Color(0xFFFFF7EA)
        else -> palette.onEmber
    }
    Box(
        Modifier
            .size(44.dp)
            .clip(CircleShape)
            .background(if (eink.active) palette.bg else tint)
            .then(if (eink.active) Modifier.border(2.dp, palette.text, CircleShape) else Modifier)
            .clickable(role = Role.Button, onClick = onPlay)
            .semantics { contentDescription = if (isEbook) "Read $title" else "Listen to $title" },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (isEbook) Icons.AutoMirrored.Filled.MenuBook else Icons.Filled.PlayArrow,
            contentDescription = null,
            tint = foreground,
            modifier = Modifier.size(22.dp),
        )
    }
}

private fun locatorJson(book: Book): JSONObject? =
    book.epubLocator?.let { runCatching { JSONObject(it) }.getOrNull() }

private fun chapterTitle(book: Book): String? {
    if (book.mediaType == AppMediaType.EBOOK) {
        return locatorJson(book)?.optString("title")?.trim()?.takeIf(String::isNotEmpty)
    }
    if (book.chapters.isEmpty()) return null
    val index = book.chapters.indexOfLast { it.startTime <= book.currentTime }.coerceAtLeast(0)
    return book.chapters[index].title.ifBlank { "Chapter ${index + 1}" }
}

private fun positionReading(book: Book, progress: Float): PositionReading {
    if (book.mediaType == AppMediaType.EBOOK) {
        val total = book.pageCount
        if (total != null && total > 0) {
            val page = ceil(progress * total).toInt().coerceIn(1, total)
            return PositionReading("Page $page of $total", "${total - page} left", page.toFloat() / total)
        }
        val position = locatorJson(book)?.optJSONObject("locations")?.optInt("position", 0)?.takeIf { it > 0 }
        return PositionReading(position?.let { "Page $it" } ?: "Page count unavailable", null, progress)
    }
    if (book.duration <= 0L) return PositionReading(clock(book.currentTime), null, progress)
    return PositionReading(
        "${clock(book.currentTime)} / ${clock(book.duration)}",
        "-" + clock((book.duration - book.currentTime).coerceAtLeast(0L)),
        progress,
    )
}

private fun clock(seconds: Long): String {
    val total = seconds.coerceAtLeast(0L)
    val h = total / 3600
    val m = (total % 3600) / 60
    val s = total % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, s) else "%d:%02d".format(m, s)
}
