package com.enve.hearth.home

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.TrendingUp
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.ArrowCircleDown
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.AutoStories
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Explore
import androidx.compose.material.icons.outlined.LocalFireDepartment
import androidx.compose.material.icons.outlined.Podcasts
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.AccountCircle
import androidx.compose.material.icons.outlined.Verified
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.hearth.shell.profileViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD
import com.enve.engine.prefs.HearthHomeSection
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.design.hearthUI
import com.enve.hearth.design.rememberAmbientTint
import com.enve.hearth.detail.detailListenTarget
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HearthHomeScreen(
    isPlaying: Boolean,
    onSelectBook: (Book) -> Unit,
    onPlayBook: (Book) -> Unit,
    onListenBook: (Book) -> Unit,
    onReadBook: (Book) -> Unit,
    onOpenSettings: () -> Unit,
    onAddSource: () -> Unit,
    onOpenPodcasts: () -> Unit,
    onOpenHardcover: () -> Unit,
    onOpenProfiles: (() -> Unit)? = null,
    profileName: String? = null,
) {
    val vm: HearthHomeViewModel = profileViewModel()
    val continueBooks by vm.continueBooks.collectAsStateWithLifecycle()
    val lastOpenedBook by vm.lastOpenedBook.collectAsStateWithLifecycle()
    val editionLinks by vm.editionLinks.collectAsStateWithLifecycle()
    val recent by vm.recentlyAdded.collectAsStateWithLifecycle()
    val downloaded by vm.downloaded.collectAsStateWithLifecycle()
    val allBooks by vm.allBooks.collectAsStateWithLifecycle()
    val refreshing by vm.isRefreshing.collectAsStateWithLifecycle()
    val lastSyncMillis by vm.lastSyncMillis.collectAsStateWithLifecycle()
    val homeSectionOrder by vm.homeSectionOrder.collectAsStateWithLifecycle()
    val networkAvailable by vm.networkAvailable.collectAsStateWithLifecycle()
    val dismissedKeys by vm.dismissedShelfKeys.collectAsStateWithLifecycle()
    var showingDiscover by rememberSaveable { mutableStateOf(false) }
    var seeAllSection by rememberSaveable { mutableStateOf<HearthHomeSection?>(null) }
    var contextBook by remember { mutableStateOf<Book?>(null) }
    var contextDismissable by rememberSaveable { mutableStateOf(false) }
    val palette = Hearth.palette

    if (showingDiscover) {
        DiscoverScreen(onBack = { showingDiscover = false }, onOpenBook = onSelectBook, onPlayBook = onPlayBook)
        return
    }

    val visibleContinue = continueBooks.filterNot { it.uniqueKey in dismissedKeys }
    val (allListening, allReading) = splitContinueShelves(visibleContinue, editionLinks)
    val selectedSection = seeAllSection
    if (selectedSection != null) {
        val books = when (selectedSection) {
            HearthHomeSection.CONTINUE_READING -> allReading
            HearthHomeSection.CONTINUE_LISTENING -> allListening
            HearthHomeSection.RECENTLY_ADDED -> recent
            HearthHomeSection.DOWNLOADED -> downloaded
            else -> emptyList()
        }
        BackHandler { seeAllSection = null }
        HomeSeeAll(selectedSection.label, books, onBack = { seeAllSection = null }, onOpen = onSelectBook)
        return
    }

    contextBook?.let { book ->
        AlertDialog(
            onDismissRequest = { contextBook = null },
            title = { Text(book.title) },
            text = {
                Column {
                    if (contextDismissable) TextButton(onClick = { vm.dismissFromShelf(book); contextBook = null }) { Text("Hide from Hearth") }
                    TextButton(onClick = { vm.setFinished(book, !book.isFinished); contextBook = null }) { Text(if (book.isFinished) "Mark unfinished" else "Mark finished") }
                    if (book.progress > 0f) TextButton(onClick = { vm.resetProgress(book); contextBook = null }) { Text("Reset progress") }
                    TextButton(onClick = { onPlayBook(book); contextBook = null }) { Text(if (book.mediaType == AppMediaType.EBOOK) "Read" else "Listen") }
                }
            },
            confirmButton = { TextButton(onClick = { contextBook = null }) { Text("Done") } },
        )
    }

    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = vm::refresh,
        modifier = Modifier.fillMaxSize().background(palette.bg).statusBarsPadding(),
    ) {
        val hero = lastOpenedBook?.takeUnless { it.uniqueKey in dismissedKeys }
            ?: visibleContinue.firstOrNull() ?: recent.firstOrNull { it.uniqueKey !in dismissedKeys }
        val heroLinks by produceState<Pair<Book?, Book?>>(null to null, hero?.uniqueKey) {
            value = hero?.let { vm.linkedAudiobook(it) to vm.linkedEbook(it) } ?: (null to null)
        }

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
            visibleContinue.isEmpty() &&
            recent.isEmpty() &&
            downloaded.isEmpty() &&
            allBooks.isEmpty()

        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                top = 0.dp, bottom = LocalMantelInset.current + Hearth.Spacing.L,
            ),
            verticalArrangement = Arrangement.spacedBy(if (Hearth.typeCompact) Hearth.Spacing.L else Hearth.Spacing.XXL),
        ) {
            item { HomeHeader(lastSyncMillis, onOpenSettings, onOpenProfiles, profileName) }
            if (!networkAvailable) item { OfflineBanner() }
            item { QuoteBlock() }
            if (hasNoMedia) {
                item { EmptyHearth(onAddSource) }
            } else {
                hero?.let { book ->
                    item {
                        BookCard(
                            book,
                            onOpen = { onSelectBook(book) },
                            onPlay = { onPlayBook(book) },
                            modifier = Modifier.padding(horizontal = Hearth.Spacing.XL),
                            prominent = true,
                            isPlaying = isPlaying,
                            listenTarget = detailListenTarget(book, heroLinks.first),
                            readTarget = if (book.mediaType == AppMediaType.EBOOK || book.hasEbook) book else heroLinks.second,
                            onListen = onListenBook,
                            onRead = onReadBook,
                        )
                    }
                    item {
                        TodayStack(
                            activeCount = visibleContinue.distinctBy { it.uniqueKey }.size,
                            downloadedCount = allBooks.count { it.isDownloaded },
                            freshCount = recent.size,
                            progress = HearthFormat.progress(book),
                            tint = rememberAmbientTint(book),
                        )
                    }
                }
                homeSectionOrder.forEach { section ->
                    when (section) {
                        HearthHomeSection.DOORWAYS -> if (hero != null) item {
                            Doorways(
                                onDiscover = { showingDiscover = true },
                                onPodcasts = onOpenPodcasts,
                                onHardcover = onOpenHardcover,
                            )
                        }
                        HearthHomeSection.CONTINUE_READING -> if (reading.isNotEmpty()) {
                            item {
                                ContinueCarousel(
                                    "Continue reading", reading,
                                    onOpen = onSelectBook,
                                    onPlay = onPlayBook,
                                    onSeeAll = { seeAllSection = section },
                                    onContextBook = { contextBook = it; contextDismissable = true },
                                )
                            }
                        }
                        HearthHomeSection.CONTINUE_LISTENING -> if (listening.isNotEmpty()) {
                            item {
                                ContinueCarousel(
                                    "Continue listening", listening,
                                    onOpen = onSelectBook,
                                    onPlay = onPlayBook,
                                    onSeeAll = { seeAllSection = section },
                                    onContextBook = { contextBook = it; contextDismissable = true },
                                )
                            }
                        }
                        HearthHomeSection.RECENTLY_ADDED -> if (recent.any { it.uniqueKey != hero?.uniqueKey }) {
                            item {
                                BookShelf(
                                    "Recently Added", recent.filter { it.uniqueKey != hero?.uniqueKey },
                                    onOpen = onSelectBook,
                                    onSeeAll = { seeAllSection = section },
                                    onContextBook = { contextBook = it; contextDismissable = false },
                                )
                            }
                        }
                        HearthHomeSection.DOWNLOADED -> if (downloaded.isNotEmpty()) {
                            item {
                                BookShelf(
                                    "On this device", downloaded,
                                    onOpen = onSelectBook,
                                    onSeeAll = { seeAllSection = section },
                                    onContextBook = { contextBook = it; contextDismissable = false },
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun HomeHeader(lastSyncMillis: Long, onOpenSettings: () -> Unit, onOpenProfiles: (() -> Unit)?, profileName: String?) {
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxWidth()
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
        if (onOpenProfiles != null) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClick = onOpenProfiles),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Outlined.AccountCircle, contentDescription = profileName?.let { "Profiles, $it" } ?: "Profiles", tint = palette.ember, modifier = Modifier.size(26.dp))
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
                if (progress >= FINISHED_PROGRESS_THRESHOLD) Icons.Outlined.Verified else Icons.AutoMirrored.Outlined.TrendingUp,
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
private fun BookShelf(title: String, books: List<Book>, onOpen: (Book) -> Unit, onSeeAll: () -> Unit, onContextBook: (Book) -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        ShelfHeader(title, modifier = Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), actionLabel = "See all", onAction = onSeeAll)
        LazyRow(
            contentPadding = PaddingValues(horizontal = Hearth.Spacing.XL),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        ) {
            items(books, key = { it.id + (it.connectionId ?: "") }) { book ->
                ShelfCard(book, onOpen, onContextBook)
            }
        }
    }
}

@Composable
private fun ShelfCard(book: Book, onOpen: (Book) -> Unit, onLongClick: (Book) -> Unit) {
    val palette = Hearth.palette
    Column(
        Modifier.width(96.dp).combinedClickable(onClick = { onOpen(book) }, onLongClick = { onLongClick(book) }),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
    ) {
        CoverTile(
            model = book.coverUrl,
            mediaType = book.mediaType,
            modifier = Modifier.width(96.dp),
        )
        Text(
            book.title,
            style = hearthDisplay(13.sp, FontWeight.Medium),
            color = palette.text,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
        val byline = if (book.mediaType == AppMediaType.PODCAST) book.podcastName ?: book.author else book.author
        if (!byline.isNullOrBlank()) {
            Text(byline, style = hearthUI(11.sp), color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Text(
            book.source.displayName,
            style = HearthText.Overline,
            color = palette.textTertiary,
            maxLines = 1,
            modifier = Modifier
                .clip(RoundedCornerShape(Hearth.Radius.Inner))
                .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Inner))
                .padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.XS),
        )
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

@Composable
private fun EmptyHearth(onAddSource: () -> Unit) {
    val palette = Hearth.palette
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        Box(Modifier.fillMaxWidth().height(180.dp), contentAlignment = Alignment.Center) {
            if (!Hearth.eink.suppressGradients) {
                Box(Modifier.size(180.dp).drawBehind {
                    drawCircle(
                        brush = Brush.radialGradient(
                            colors = listOf(palette.ember.copy(alpha = 0.25f), Color.Transparent),
                            radius = size.minDimension / 2f,
                        ),
                    )
                })
            }
            Icon(Icons.Outlined.LocalFireDepartment, contentDescription = null, tint = palette.ember, modifier = Modifier.size(44.dp))
        }
        Text("Light the fire.", style = hearthDisplay(26.sp), color = palette.text)
        Text(
            "Connect a server or import your books, and your reading life gathers here.",
            style = HearthText.Body,
            color = palette.textSecondary,
        )
        EmberButton("Add a source", onClick = onAddSource, leadingIcon = Icons.Outlined.Add)
    }
}

@Composable
private fun OfflineBanner() {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL)
            .clip(RoundedCornerShape(Hearth.Radius.Inner))
            .background(palette.statusWarn.copy(alpha = 0.12f))
            .padding(Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Icon(Icons.Outlined.WifiOff, null, tint = palette.statusWarn, modifier = Modifier.size(18.dp))
        Text("Offline · Your downloaded books are ready", style = HearthText.Caption, color = palette.text)
    }
}

@Composable
private fun Doorways(onDiscover: () -> Unit, onPodcasts: () -> Unit, onHardcover: () -> Unit) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        Overline("DOORWAYS")
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Card))
                .background(palette.bgElevated).border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card)),
        ) {
            DoorwayRow("Discover", "Find your next read", Icons.Outlined.Explore, onDiscover)
            DoorwayRow("Podcasts", "Browse shows and episodes", Icons.Outlined.Podcasts, onPodcasts)
            DoorwayRow("Hardcover", "Explore your reading life", Icons.Outlined.AutoStories, onHardcover)
        }
    }
}

@Composable
private fun DoorwayRow(title: String, subtitle: String, icon: ImageVector, onClick: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Icon(icon, null, tint = palette.ember, modifier = Modifier.size(23.dp))
        Column(Modifier.weight(1f)) {
            Text(title, style = hearthUI(15.sp, FontWeight.SemiBold), color = palette.text)
            Text(subtitle, style = HearthText.Caption, color = palette.textSecondary)
        }
        Icon(Icons.Outlined.ChevronRight, null, tint = palette.textTertiary)
    }
}

@Composable
private fun HomeSeeAll(title: String, books: List<Book>, onBack: () -> Unit, onOpen: (Book) -> Unit) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxSize().background(palette.bg).statusBarsPadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.L), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = palette.text, modifier = Modifier.clickable(onClick = onBack).padding(8.dp))
            Text(title, style = hearthDisplay(28.sp, FontWeight.SemiBold), color = palette.text, modifier = Modifier.padding(start = Hearth.Spacing.M))
        }
        LazyVerticalGrid(
            columns = GridCells.Fixed(3),
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = Hearth.Spacing.XL, end = Hearth.Spacing.XL, bottom = LocalMantelInset.current + Hearth.Spacing.L),
            horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
        ) {
            items(books.size, key = { books[it].uniqueKey }) { index ->
                val book = books[index]
                Column(Modifier.clickable { onOpen(book) }, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
                    CoverTile(book.coverUrl, mediaType = book.mediaType, modifier = Modifier.fillMaxWidth())
                    Text(book.title, style = hearthDisplay(13.sp, FontWeight.Medium), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    book.author?.let { Text(it, style = hearthUI(11.sp), color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                }
            }
        }
    }
}
