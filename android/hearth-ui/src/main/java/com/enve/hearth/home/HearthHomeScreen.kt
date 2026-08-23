package com.enve.hearth.home

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.automirrored.outlined.TrendingUp
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.EmberGlow
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.Ribbon
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI
import com.enve.hearth.design.rememberAmbientTint
import kotlin.math.roundToInt
import kotlinx.coroutines.launch
import com.enve.engine.prefs.HearthHomeSection

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HearthHomeScreen(
    isPlaying: Boolean,
    onSelectBook: (Book) -> Unit,
    onPlayBook: (Book) -> Unit,
    onOpenSettings: () -> Unit,
) {
    val vm: HearthHomeViewModel = hiltViewModel()
    val continueBooks by vm.continueBooks.collectAsStateWithLifecycle()
    val lastOpenedBook by vm.lastOpenedBook.collectAsStateWithLifecycle()
    val editionLinks by vm.editionLinks.collectAsStateWithLifecycle()
    val recent by vm.recentlyAdded.collectAsStateWithLifecycle()
    val downloaded by vm.downloaded.collectAsStateWithLifecycle()
    val allBooks by vm.allBooks.collectAsStateWithLifecycle()
    val refreshing by vm.isRefreshing.collectAsStateWithLifecycle()
    val lastSyncMillis by vm.lastSyncMillis.collectAsStateWithLifecycle()
    val homeSectionOrder by vm.homeSectionOrder.collectAsStateWithLifecycle()
    val palette = Hearth.palette

    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = vm::refresh,
        modifier = Modifier.fillMaxSize().background(palette.bg),
    ) {
        val hero = lastOpenedBook ?: continueBooks.firstOrNull()

        val (allListening, allReading) = splitContinueShelves(continueBooks, editionLinks)

        val heroCounterpart = hero?.let { h ->
            editionLinks.firstNotNullOfOrNull { l ->
                when (h.uniqueKey) {
                    l.ebookKey -> l.audiobookKey
                    l.audiobookKey -> l.ebookKey
                    else -> null
                }
            }
        }
        val excluded = setOfNotNull(hero?.uniqueKey, heroCounterpart)
        val listening = allListening.filter { it.uniqueKey !in excluded }
        val reading = allReading.filter { it.uniqueKey !in excluded }
        val hasNoMedia = hero == null &&
            continueBooks.isEmpty() &&
            recent.isEmpty() &&
            downloaded.isEmpty() &&
            allBooks.isEmpty()

        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                top = 0.dp, bottom = LocalMantelInset.current + Hearth.Spacing.L,
            ),
            verticalArrangement = Arrangement.spacedBy(if (Hearth.typeCompact) Hearth.Spacing.L else Hearth.Spacing.XXL),
        ) {
            if (hasNoMedia) {
                item { EmptyHearth(onOpenSettings) }
            } else {
                item { HomeHeader(lastSyncMillis, onOpenSettings) }
                item { QuoteBlock() }
                hero?.let { book ->
                    item {
                        HeroSection(book, book.source.displayName, isPlaying, onContinue = { onPlayBook(book) }, onOpen = { onSelectBook(book) })
                    }
                    item {
                        TodayStack(
                            activeCount = continueBooks.distinctBy { it.uniqueKey }.size,
                            downloadedCount = allBooks.count { it.isDownloaded },
                            freshCount = recent.size,
                            progress = HearthFormat.progress(book),
                            tint = rememberAmbientTint(book),
                        )
                    }
                }
                homeSectionOrder.forEach { section ->
                    when (section) {
                        HearthHomeSection.CONTINUE_READING -> if (reading.isNotEmpty()) {
                            item { BookShelf("Continue reading", reading, showProgress = true, onOpen = onSelectBook) }
                        }
                        HearthHomeSection.CONTINUE_LISTENING -> if (listening.isNotEmpty()) {
                            item { BookShelf("Continue listening", listening, showProgress = true, onOpen = onSelectBook) }
                        }
                        HearthHomeSection.RECENTLY_ADDED -> if (recent.isNotEmpty()) {
                            item { BookShelf("Fresh ink", recent, showProgress = false, onOpen = onSelectBook) }
                        }
                        HearthHomeSection.DOWNLOADED -> if (downloaded.isNotEmpty()) {
                            item { BookShelf("On this device", downloaded, showProgress = false, onOpen = onSelectBook) }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HomeHeader(lastSyncMillis: Long, onOpenSettings: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = Hearth.Spacing.XL)
            .padding(top = Hearth.Spacing.L),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Overline(HearthFormat.greeting())
            Text("Hearth", style = HearthText.ScreenTitle, color = palette.text)
            HearthFormat.relativeAgo(lastSyncMillis)?.let {
                Text("Synced $it", style = hearthUI(11.sp), color = palette.textTertiary)
            }
        }
        Box(
            Modifier
                .size(40.dp)
                .clip(CircleShape)
                .background(palette.bgElevated)
                .border(1.dp, palette.hairline, CircleShape)
                .clickable(onClick = onOpenSettings),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Outlined.Settings, contentDescription = "Settings", tint = palette.textSecondary, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun QuoteBlock() {
    val palette = Hearth.palette
    val compact = Hearth.typeCompact
    val quote = HearthQuotes.daily
    Column(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL),
        verticalArrangement = Arrangement.spacedBy(if (compact) Hearth.Spacing.XS else Hearth.Spacing.S),
    ) {
        Text(
            "“${quote.text}”",
            style = hearthDisplay(if (compact) 14.sp else 16.sp, FontWeight.Normal).copy(fontStyle = FontStyle.Italic),
            color = palette.textSecondary,
            maxLines = if (compact) 2 else 3,
            overflow = TextOverflow.Ellipsis,
        )
        Overline(quote.author, color = palette.textTertiary)
    }
}

@Composable
private fun HeroSection(book: Book, sourceName: String, isPlaying: Boolean, onContinue: () -> Unit, onOpen: () -> Unit) {
    val palette = Hearth.palette
    val tint = rememberAmbientTint(book)
    val shape = RoundedCornerShape(Hearth.Radius.Card)
    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL)
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape),
    ) {
        EmberGlow(color = tint, playing = isPlaying, modifier = Modifier.matchParentSize())
        val compact = Hearth.typeCompact
        Column(
            Modifier.padding(if (compact) Hearth.Spacing.L else 22.dp),
            verticalArrangement = Arrangement.spacedBy(if (compact) Hearth.Spacing.L else Hearth.Spacing.XL),
        ) {
            Row(horizontalArrangement = Arrangement.spacedBy(if (compact) Hearth.Spacing.L else Hearth.Spacing.XL)) {
                CoverTile(
                    model = book.coverUrl,
                    ambient = tint,
                    aspect = if (book.mediaType == AppMediaType.EBOOK) 2f / 3f else 1f,
                    modifier = Modifier.width(if (compact) 106.dp else 132.dp).clickable(onClick = onOpen),
                )
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    Overline(HearthFormat.heroOverline(book), color = tint)
                    Text(
                        book.title,
                        style = hearthDisplay(if (compact) 20.sp else 24.sp, FontWeight.SemiBold),
                        color = palette.text,
                        maxLines = if (compact) 2 else 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                    book.author?.let { Text(it, style = hearthUI(14.sp), color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                    SourceBadge(sourceName)
                    Spacer(Modifier.height(Hearth.Spacing.XS))
                    Ribbon(progress = HearthFormat.progress(book), fill = tint, ticks = HearthFormat.chapterTicks(book))
                    HearthFormat.timeLeft(book)?.let { Text(it, style = hearthUI(12.sp, FontWeight.Medium), color = palette.textTertiary) }
                }
            }
            val started = HearthFormat.progress(book) > 0.001f
            EmberButton(
                text = when {
                    started -> "Continue"
                    book.mediaType == AppMediaType.EBOOK -> "Start reading"
                    else -> "Start listening"
                },
                onClick = onContinue,
                modifier = Modifier.fillMaxWidth(),
                leadingIcon = if (book.mediaType == AppMediaType.EBOOK) Icons.AutoMirrored.Outlined.MenuBook else Icons.Filled.PlayArrow,
                tint = tint,
            )
        }
    }
}

@Composable
private fun SourceBadge(name: String) {
    val palette = Hearth.palette
    Text(
        name,
        style = hearthUI(10.sp, FontWeight.SemiBold),
        color = palette.textTertiary,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(palette.bg.copy(alpha = 0.62f))
            .border(1.dp, palette.hairline.copy(alpha = 0.75f), RoundedCornerShape(50))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

@Composable
private fun TodayStack(activeCount: Int, downloadedCount: Int, freshCount: Int, progress: Float, tint: Color) {
    val palette = Hearth.palette
    val pct = (progress.coerceIn(0f, 1f) * 100).roundToInt()
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL)
            .clip(RoundedCornerShape(Hearth.Radius.Card))
            .background(palette.bgElevated.copy(alpha = 0.82f))
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card))
            .padding(15.dp),
        verticalArrangement = Arrangement.spacedBy(13.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Outlined.Search, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
            Overline("Today's stack", color = palette.textTertiary)
            Spacer(Modifier.weight(1f))
            Text("$pct% current", style = hearthUI(11.sp, FontWeight.SemiBold), color = tint)
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
            StackTile(Icons.Outlined.LocalFireDepartment, capped(activeCount, 32), "Continue", tint, Modifier.weight(1f))
            StackTile(Icons.Outlined.ArrowCircleDown, capped(downloadedCount, 16), "Saved", palette.statusOK, Modifier.weight(1f))
            StackTile(Icons.Outlined.AutoAwesome, capped(freshCount, 12), "Added", palette.ember, Modifier.weight(1f))
            StackTile(
                if (progress >= 0.98f) Icons.Outlined.Verified else Icons.AutoMirrored.Outlined.TrendingUp,
                "$pct%", "Current", tint, Modifier.weight(1f),
            )
        }
    }
}

private fun capped(count: Int, cap: Int): String = if (count > cap) "$cap+" else count.toString()

@Composable
private fun StackTile(icon: androidx.compose.ui.graphics.vector.ImageVector, value: String, label: String, tint: Color, modifier: Modifier = Modifier) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(8.dp)
    Column(
        modifier
            .heightIn(min = 82.dp)
            .clip(shape)
            .background(palette.bg.copy(alpha = 0.42f))
            .border(1.dp, palette.hairline.copy(alpha = 0.75f), shape)
            .padding(vertical = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(7.dp, Alignment.CenterVertically),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(14.dp))
        Text(value, style = hearthDisplay(19.sp, FontWeight.SemiBold), color = palette.text, maxLines = 1)
        Text(label, style = hearthUI(10.sp, FontWeight.Medium), color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun BookShelf(title: String, books: List<Book>, showProgress: Boolean, onOpen: (Book) -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader(title, modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL))
        LazyRow(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Hearth.Spacing.XL),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            items(books, key = { it.id + (it.connectionId ?: "") }) { book ->
                ShelfCard(book, showProgress, onOpen)
            }
        }
    }
}

@Composable
private fun ShelfCard(book: Book, showProgress: Boolean, onOpen: (Book) -> Unit) {
    val palette = Hearth.palette
    val cardWidth = if (showProgress) 118.dp else 92.dp
    Column(
        Modifier.width(cardWidth).clickable { onOpen(book) },
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
    ) {
        CoverTile(
            model = book.coverUrl,
            modifier = if (showProgress) {
                Modifier.fillMaxWidth()
            } else {
                Modifier.width(76.dp).align(Alignment.CenterHorizontally)
            },
        )
        Text(
            book.title,
            style = HearthText.Label,
            color = palette.text,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
        if (showProgress) {
            Ribbon(progress = HearthFormat.progress(book))
            HearthFormat.timeLeft(book)?.let {
                Text(it, style = HearthText.Overline, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}

internal fun splitContinueShelves(
    books: List<Book>,
    links: List<com.enve.engine.library.LibraryEditionLink>,
): Pair<List<Book>, List<Book>> {
    val linkedAudioToEbook = links.associate { it.audiobookKey to it.ebookKey }
    val presentKeys = books.mapTo(HashSet()) { it.uniqueKey }
    val listening = ArrayList<Book>()
    val reading = ArrayList<Book>()
    for (b in books) {
        val forcedReading = b.readAlongAvailable || b.uniqueKey in linkedAudioToEbook
        if (b.mediaType == AppMediaType.AUDIOBOOK && !forcedReading) {
            listening.add(b)
        } else {

            val pairedEbook = linkedAudioToEbook[b.uniqueKey]
            if (pairedEbook != null && pairedEbook in presentKeys) continue
            reading.add(b)
        }
    }
    return listening to reading
}

private data class EmptyHearthRoom(
    val icon: ImageVector,
    val overline: String,
    val title: String,
    val body: String,
)

@Composable
private fun EmptyHearth(onOpenSettings: () -> Unit) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val rooms = remember {
        listOf(
            EmptyHearthRoom(
                Icons.Outlined.LocalFireDepartment,
                "The first room",
                "Hearth",
                "Your current book lives here, glowing in its own colors. Everything you're reading waits beside it.",
            ),
            EmptyHearthRoom(
                Icons.AutoMirrored.Outlined.MenuBook,
                "The second room",
                "Library",
                "Every book from every source, gathered into one set of stacks. Search is always close at hand.",
            ),
            EmptyHearthRoom(
                Icons.Outlined.AutoAwesome,
                "The third room",
                "Journal",
                "See the hours you've kept and the passages you've saved: a record of your reading life.",
            ),
            EmptyHearthRoom(
                Icons.Outlined.ArrowCircleDown,
                "The mantel",
                "One bar, two jobs",
                "The bar below is both compass and player. When a book is active, tap it to open the full player.",
            ),
        )
    }
    val pagerState = rememberPagerState(pageCount = { rooms.size })
    val scope = rememberCoroutineScope()
    val goToPage: (Int) -> Unit = { page ->
        scope.launch {
            if (eink.suppressAnimations) pagerState.scrollToPage(page)
            else pagerState.animateScrollToPage(page)
        }
    }

    Column(
        Modifier
            .fillMaxWidth()
            .statusBarsPadding()
            .padding(horizontal = Hearth.Spacing.L)
            .padding(top = Hearth.Spacing.M),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Overline("Welcome to Enve")
            QuietButton("Add a source", onClick = onOpenSettings)
        }

        HorizontalPager(
            state = pagerState,
            modifier = Modifier.fillMaxWidth().height(350.dp),
            contentPadding = PaddingValues(horizontal = Hearth.Spacing.XS),
            pageSpacing = Hearth.Spacing.M,
        ) { page ->
            val room = rooms[page]
            val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Card)
            Box(
                Modifier
                    .fillMaxSize()
                    .clip(shape)
                    .background(palette.bgElevated.copy(alpha = if (eink.active) 1f else 0.48f))
                    .border(1.dp, palette.hairline, shape),
                contentAlignment = Alignment.Center,
            ) {
                EmberGlow(palette.ember, playing = true, modifier = Modifier.fillMaxSize())
                Column(
                    Modifier.padding(horizontal = Hearth.Spacing.XXL),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
                ) {
                    Box(
                        Modifier
                            .size(76.dp)
                            .clip(CircleShape)
                            .background(palette.ember.copy(alpha = if (eink.active) 0f else 0.14f))
                            .border(1.dp, palette.ember.copy(alpha = 0.5f), CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(room.icon, contentDescription = null, tint = palette.ember, modifier = Modifier.size(38.dp))
                    }
                    Overline(room.overline)
                    Text(room.title, style = hearthDisplay(32.sp), color = palette.text)
                    Text(
                        room.body,
                        style = HearthText.Body,
                        color = palette.textSecondary,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }

        Row(
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            rooms.indices.forEach { page ->
                Box(
                    Modifier
                        .size(32.dp)
                        .semantics { contentDescription = "Show ${rooms[page].title} page" }
                        .clickable { goToPage(page) },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(
                        Modifier
                            .size(if (pagerState.currentPage == page) 10.dp else 7.dp)
                            .clip(CircleShape)
                            .background(if (pagerState.currentPage == page) palette.ember else palette.hairline),
                    )
                }
            }
        }

        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (pagerState.currentPage > 0) {
                QuietButton("Back", onClick = { goToPage(pagerState.currentPage - 1) })
            } else {
                Spacer(Modifier.width(72.dp))
            }
            EmberButton(
                text = if (pagerState.currentPage == rooms.lastIndex) "Add a source" else "Next",
                onClick = {
                    if (pagerState.currentPage == rooms.lastIndex) onOpenSettings()
                    else goToPage(pagerState.currentPage + 1)
                },
            )
        }

        Text(
            "Connect your library when you're ready. Your books will appear here automatically.",
            style = HearthText.Caption,
            color = palette.textTertiary,
            textAlign = TextAlign.Center,
        )
    }
}
