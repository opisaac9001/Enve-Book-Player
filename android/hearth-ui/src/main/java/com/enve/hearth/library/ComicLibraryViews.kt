package com.enve.hearth.library

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyGridItemSpanScope
import androidx.compose.foundation.lazy.grid.LazyGridScope
import androidx.compose.foundation.lazy.grid.LazyGridState
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.Book
import com.enve.core.data.model.ComicSection
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.coverAspectRatio
import com.enve.hearth.design.fadeHorizontalEdges
import com.enve.hearth.design.hearthDisplay

internal fun comicIssueCount(count: Int): String = if (count == 1) "1 issue" else "$count issues"

internal fun comicSeriesSummaryLine(total: Int, unread: Int): String =
    "${comicIssueCount(total)} · ${if (unread == 0) "All read" else "$unread unread"}"

internal fun comicContinueTitle(book: Book): String = when {
    isReadInLibrary(book) -> "Read again"
    comicProgress(book) > 0.001f -> "Continue reading"
    else -> "Read next"
}

private fun comicIssueCaption(book: Book): String =
    listOfNotNull(book.comic?.issueLabel?.takeIf(String::isNotBlank), book.title).joinToString(" · ")

@Composable
internal fun ComicFacetRow(selected: LibraryFacet?, onSelect: (LibraryFacet) -> Unit) {
    Row(
        Modifier.fillMaxWidth().fadeHorizontalEdges().horizontalScroll(rememberScrollState()).padding(horizontal = Hearth.Spacing.L),
        horizontalArrangement = Arrangement.spacedBy(if (Hearth.typeCompact) Hearth.Spacing.XS else Hearth.Spacing.S),
    ) {
        ComicFacets.forEach { facet ->
            val isSelected = facet == selected
            Box(
                Modifier
                    .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                    .selectable(selected = isSelected, role = Role.Tab) { onSelect(facet) }
                    .padding(horizontal = Hearth.Spacing.XS),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (facet == LibraryFacet.SERIES) "Series" else "Issues",
                    style = HearthText.Overline,
                    color = if (isSelected) Hearth.palette.ember else Hearth.palette.textTertiary,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun ComicSeriesList(
    series: List<ComicSeriesSummary>,
    columns: Int,
    state: LazyGridState,
    onOpen: (ComicSeriesSummary) -> Unit,
    onContinue: (Book) -> Unit,
) {
    val palette = Hearth.palette
    val listLayout = columns == 1 || Hearth.eink.denseListLibrary
    LazyVerticalGrid(
        columns = GridCells.Fixed(if (listLayout) 1 else columns.coerceIn(2, 4)),
        state = state,
        contentPadding = PaddingValues(start = Hearth.Spacing.XL, end = Hearth.Spacing.XL, bottom = LocalMantelInset.current + Hearth.Spacing.L),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(if (listLayout) Hearth.Spacing.XS else Hearth.Spacing.L),
        modifier = Modifier.fillMaxSize(),
    ) {
        items(series, key = ComicSeriesSummary::key) { item ->
            var menu by remember { mutableStateOf(false) }
            val summary = comicSeriesSummaryLine(item.total, item.unread)
            val nextLabel = item.next?.let { next -> "Next: ${next.comic?.issueLabel ?: next.title}" }
            val description = listOfNotNull(item.name, item.run, summary, nextLabel).joinToString(", ")
            val open = Modifier
                .semantics(mergeDescendants = true) { contentDescription = description }
                .combinedClickable(onClickLabel = "Open series", onClick = { onOpen(item) }, onLongClick = { menu = true })
            Box {
                if (listLayout) {
                    Row(open.fillMaxWidth().padding(vertical = Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
                        CoverTile(model = item.coverUrl, modifier = Modifier.width(44.dp))
                        Spacer(Modifier.width(Hearth.Spacing.M))
                        Column(Modifier.weight(1f)) {
                            Text(item.name, style = hearthDisplay(17.sp, FontWeight.SemiBold), color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                            Text(listOfNotNull(item.run, summary).joinToString(" · "), style = HearthText.Caption, color = palette.textSecondary, maxLines = 1)
                            nextLabel?.let { Text(it, style = HearthText.Caption, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis) }
                        }
                        item.next?.let { next ->
                            TextButton(onClick = { onContinue(next) }) { Text(comicContinueTitle(next), color = palette.ember) }
                        }
                    }
                } else {
                    Column(open.fillMaxWidth()) {
                        CoverTile(model = item.coverUrl, modifier = Modifier.fillMaxWidth())
                        Spacer(Modifier.size(Hearth.Spacing.S))
                        Text(item.name, style = hearthDisplay(14.sp, FontWeight.SemiBold), color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        Text(summary, style = HearthText.Caption, color = if (item.unread == 0) palette.ember else palette.textTertiary, maxLines = 1)
                        item.run?.let { Text(it, style = HearthText.Caption, color = palette.textTertiary, maxLines = 1) }
                    }
                }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    item.next?.let { next ->
                        DropdownMenuItem(text = { Text(comicContinueTitle(next)) }, onClick = { menu = false; onContinue(next) })
                    }
                    DropdownMenuItem(text = { Text("Open series") }, onClick = { menu = false; onOpen(item) })
                }
            }
        }
    }
}

@Composable
internal fun ComicSeriesContent(
    view: ComicSeriesView,
    columns: Int,
    onBack: () -> Unit,
    onSelectSection: (ComicSection) -> Unit,
    onToggleVolume: (String) -> Unit,
    onRead: (Book) -> Unit,
    onDetails: (Book) -> Unit,
) {
    val palette = Hearth.palette
    val listLayout = columns == 1 || Hearth.eink.denseListLibrary
    val gridState = rememberSaveable(view.key, saver = LazyGridState.Saver) { LazyGridState() }
    val full: LazyGridItemSpanScope.() -> GridItemSpan = { GridItemSpan(maxLineSpan) }
    LazyVerticalGrid(
        columns = GridCells.Fixed(if (listLayout) 1 else columns.coerceIn(2, 4)),
        state = gridState,
        contentPadding = PaddingValues(start = Hearth.Spacing.XL, end = Hearth.Spacing.XL, bottom = LocalMantelInset.current + Hearth.Spacing.L),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
        modifier = Modifier.fillMaxSize(),
    ) {
        item(key = "back", span = full) {
            Row(Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "‹ Back",
                    style = HearthText.Label,
                    color = palette.ember,
                    modifier = Modifier.clickable(role = Role.Button, onClickLabel = "Back to comics", onClick = onBack),
                )
            }
        }
        item(key = "header", span = full) {
            Column(Modifier.semantics(mergeDescendants = true) {}) {
                Overline(if (view.isStandalone) "Comic" else "Series")
                Text(view.name, style = hearthDisplay(24.sp, FontWeight.SemiBold), color = palette.text)
                Text(comicSeriesSummaryLine(view.total, view.unread), style = HearthText.Caption, color = palette.textSecondary)
            }
        }
        view.continueBook?.let { book ->
            item(key = "continue", span = full) {
                Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS)) {
                    EmberButton(
                        text = comicContinueTitle(book),
                        onClick = { onRead(book) },
                        leadingIcon = Icons.AutoMirrored.Outlined.MenuBook,
                    )
                    Text(comicIssueCaption(book), style = HearthText.Caption, color = palette.textSecondary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        if (view.grouping.sections.size > 1) {
            item(key = "sections", span = full) {
                ComicSectionPicker(view, onSelectSection)
            }
        }
        val current = view.current
        val direct = current?.directVolume
        when {
            current == null -> item(key = "empty", span = full) {
                Text(
                    "No issues match this view.",
                    style = HearthText.Body,
                    color = palette.textSecondary,
                    modifier = Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.XXL),
                )
            }
            direct != null -> issues(direct.books, listLayout, onRead, onDetails)
            else -> {
                issues(current.looseBooks, listLayout, onRead, onDetails)
                current.volumes.forEach { volume ->
                    val expanded = volume.id in view.expandedVolumeIds
                    item(key = "volume:${volume.id}", span = full) {
                        ComicVolumeHeader(volume, expanded) { onToggleVolume(volume.id) }
                    }
                    if (expanded) issues(volume.books, listLayout, onRead, onDetails)
                }
            }
        }
    }
}

private fun LazyGridScope.issues(
    books: List<Book>,
    listLayout: Boolean,
    onRead: (Book) -> Unit,
    onDetails: (Book) -> Unit,
) {
    items(books, key = { "issue:${it.uniqueKey}" }) { book -> ComicIssueTile(book, listLayout, onRead, onDetails) }
}

@Composable
private fun ComicSectionPicker(view: ComicSeriesView, onSelect: (ComicSection) -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        view.grouping.sections.forEach { group ->
            val selected = group.section == view.selectedSection
            Column(
                Modifier
                    .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                    .semantics { contentDescription = "${group.section.title}, ${comicIssueCount(group.bookCount)}" }
                    .selectable(selected = selected, role = Role.Tab) { onSelect(group.section) },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Overline(group.section.title, color = if (selected) palette.ember else palette.textTertiary)
                Spacer(Modifier.height(4.dp))
                Box(
                    Modifier.width(22.dp).height(2.dp).background(if (selected) palette.ember else Color.Transparent),
                )
            }
        }
    }
}

@Composable
private fun ComicVolumeHeader(volume: ComicVolume, expanded: Boolean, onToggle: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier
            .fillMaxWidth()
            .heightIn(min = 48.dp)
            .semantics(mergeDescendants = true) { stateDescription = if (expanded) "Expanded" else "Collapsed" }
            .clickable(role = Role.Button, onClickLabel = if (expanded) "Hide these issues" else "Show these issues", onClick = onToggle),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(volume.displayTitle, style = hearthDisplay(17.sp, FontWeight.SemiBold), color = palette.text)
            Text(comicIssueCount(volume.books.size), style = HearthText.Caption, color = palette.textTertiary)
        }
        Icon(
            Icons.Outlined.ExpandMore,
            contentDescription = null,
            tint = palette.textTertiary,
            modifier = Modifier.size(20.dp).rotate(if (expanded) 0f else -90f),
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ComicIssueTile(book: Book, listLayout: Boolean, onRead: (Book) -> Unit, onDetails: (Book) -> Unit) {
    val palette = Hearth.palette
    var menu by remember { mutableStateOf(false) }
    val label = book.comic?.issueLabel?.takeIf(String::isNotBlank)
    val progress = HearthFormat.progress(book)
    val status = when {
        isReadInLibrary(book) -> "Read"
        progress > 0.001f -> "${(progress * 100).toInt()} percent read"
        else -> "Unread"
    }
    val description = listOfNotNull(label, book.title, status, if (book.isDownloaded) "Available offline" else null).joinToString(", ")
    val click = Modifier
        .semantics(mergeDescendants = true) { contentDescription = description }
        .combinedClickable(onClickLabel = "Open the reader", onClick = { onRead(book) }, onLongClick = { menu = true })
    Box {
        if (listLayout) {
            Row(click.fillMaxWidth().padding(vertical = Hearth.Spacing.XS), verticalAlignment = Alignment.CenterVertically) {
                CoverTile(
                    model = book.coverUrl,
                    mediaType = book.mediaType,
                    modifier = Modifier.width(44.dp),
                    progress = progress,
                    isFinished = book.isFinished,
                )
                Spacer(Modifier.width(Hearth.Spacing.M))
                ComicIssueText(book, label, Modifier.weight(1f), maxTitleLines = 2)
            }
        } else {
            Column(click.fillMaxWidth()) {
                Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f), contentAlignment = Alignment.BottomCenter) {
                    CoverTile(
                        model = book.coverUrl,
                        mediaType = book.mediaType,
                        modifier = Modifier.fillMaxWidth(coverAspectRatio(book.mediaType)),
                        progress = progress,
                        isFinished = book.isFinished,
                    )
                }
                Spacer(Modifier.size(6.dp))
                ComicIssueText(book, label, Modifier.fillMaxWidth(), maxTitleLines = 2)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("Read") }, onClick = { menu = false; onRead(book) })
            DropdownMenuItem(text = { Text("Details") }, onClick = { menu = false; onDetails(book) })
        }
    }
}

@Composable
private fun ComicIssueText(book: Book, label: String?, modifier: Modifier, maxTitleLines: Int) {
    val palette = Hearth.palette
    Column(modifier) {
        label?.let { Text(it, style = HearthText.Caption.copy(fontWeight = FontWeight.SemiBold), color = palette.ember, maxLines = 1) }
        Text(book.title, style = hearthDisplay(13.sp, FontWeight.SemiBold), color = palette.text, maxLines = maxTitleLines, overflow = TextOverflow.Ellipsis)
        if (book.isDownloaded) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Outlined.Download, contentDescription = null, tint = palette.statusOK, modifier = Modifier.size(12.dp))
                Spacer(Modifier.width(4.dp))
                Text("Offline", style = HearthText.Caption, color = palette.statusOK)
            }
        }
    }
}
