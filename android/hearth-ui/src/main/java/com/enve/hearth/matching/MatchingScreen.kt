package com.enve.hearth.matching

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Slider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.hearth.shell.profileViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.DuplicateBookCluster
import com.enve.core.data.model.MetadataMatchAnalyzer
import com.enve.engine.library.LibraryMetadataMatch
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline

@Composable
fun MatchingScreen(onBack: () -> Unit, vm: MatchingViewModel = profileViewModel()) {
    val books by vm.books.collectAsStateWithLifecycle()
    val links by vm.links.collectAsStateWithLifecycle()
    val matches by vm.matches.collectAsStateWithLifecycle()
    val candidates by vm.candidates.collectAsStateWithLifecycle()
    val busy by vm.busy.collectAsStateWithLifecycle()
    val searched by vm.searched.collectAsStateWithLifecycle()
    val message by vm.message.collectAsStateWithLifecycle()
    val matchedKeys by vm.matchedKeys.collectAsStateWithLifecycle()
    val persistedMatchedKeys by vm.locallyMatchedKeys.collectAsStateWithLifecycle()
    val pending by vm.pending.collectAsStateWithLifecycle()
    val threshold by vm.threshold.collectAsStateWithLifecycle()
    val batchProgress by vm.batchProgress.collectAsStateWithLifecycle()
    val duplicateClusters by vm.duplicateClusters.collectAsStateWithLifecycle()
    val groupedDuplicates by vm.groupedDuplicates.collectAsStateWithLifecycle()
    var tab by rememberSaveable { mutableStateOf(0) }
    var sourceFilter by rememberSaveable { mutableStateOf<String?>(null) }
    var sourceMenu by remember { mutableStateOf(false) }
    var showBatchConfirm by remember { mutableStateOf(false) }
    var showClearConfirm by remember { mutableStateOf(false) }
    var showMergeConfirm by remember { mutableStateOf(false) }
    var unmergeKey by remember { mutableStateOf<String?>(null) }
    var selected by remember { mutableStateOf<Book?>(null) }
    var selectedCluster by remember { mutableStateOf<DuplicateBookCluster?>(null) }
    var keeperKey by remember(selectedCluster?.id) { mutableStateOf(selectedCluster?.books?.firstOrNull()?.uniqueKey.orEmpty()) }
    var query by remember(selected?.uniqueKey) { mutableStateOf(selected?.let(vm::defaultQuery).orEmpty()) }
    var selectedMatch by remember { mutableStateOf<LibraryMetadataMatch?>(null) }
    var selectedLink by remember { mutableStateOf<Book?>(null) }
    val unmatched = remember(books, matchedKeys, persistedMatchedKeys) {
        MetadataMatchAnalyzer.unmatchedBooks(books.filter { it.mediaType != AppMediaType.PODCAST },
            matchedKeys + books.filter { "${it.source.name}:${it.id}" in persistedMatchedKeys }.map(Book::uniqueKey))
    }
    val sourceNames = remember(books) { books.map { it.libraryName ?: it.source.name }.distinct().sorted() }
    val batchBooks = unmatched.map { it.book }.filter { it.mediaType == AppMediaType.AUDIOBOOK &&
        (sourceFilter == null || (it.libraryName ?: it.source.name) == sourceFilter) &&
        pending.none { entry -> entry.bookKey == it.uniqueKey }
    }
    val linkedKeys = remember(links) { links.flatMap { listOf(it.ebookKey, it.audiobookKey) }.toSet() }
    val groupedByKeeper = remember(groupedDuplicates) { groupedDuplicates.entries.groupBy({ it.value }, { it.key }) }
    val unlinked = remember(books, linkedKeys) { books.filter { it.mediaType == AppMediaType.EBOOK && it.uniqueKey !in linkedKeys } }
    val palette = Hearth.palette
    val back = { when {
        selectedCluster != null -> selectedCluster = null
        selected != null -> selected = null
        else -> onBack()
    } }
    BackHandler(onBack = back)
    LaunchedEffect(selected?.uniqueKey, tab) {
        selected?.let { book ->
            if (tab == 1) vm.searchLinks(book, "")
            else vm.searchMetadata(book, vm.defaultQuery(book))
        }
    }

    LazyColumn(
        Modifier.fillMaxSize().background(palette.bg).statusBarsPadding(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(bottom = LocalMantelInset.current + 24.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        item {
            Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = back) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = palette.text) }
                Column(Modifier.weight(1f)) {
                    Overline("Library matching")
                    Text(selectedCluster?.title ?: selected?.title ?: "Match your books", style = HearthText.ScreenTitle, color = palette.text,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        item {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 24.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                HearthChip(label = "Metadata · ${unmatched.size}", selected = tab == 0, onClick = { selected = null; tab = 0 })
                HearthChip(label = "Audio + ebook · ${unlinked.size}", selected = tab == 1, onClick = { selected = null; tab = 1 })
                HearthChip(label = "Review · ${pending.size}", selected = tab == 2, onClick = { selected = null; tab = 2 })
                HearthChip(label = "Duplicates · ${duplicateClusters.size}", selected = tab == 3, onClick = { selected = null; tab = 3 })
            }
        }
        message?.let { text -> item {
            Text(text, color = palette.ember, style = HearthText.Caption,
                modifier = Modifier.fillMaxWidth().clickable { vm.clearMessage() }.padding(horizontal = 24.dp))
        } }
        if (tab == 0 && selected == null) {
            item {
                Column(Modifier.fillMaxWidth().padding(horizontal = 24.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Batch metadata", style = HearthText.Label, color = palette.text)
                    Text("Confident audiobook matches apply automatically. Others go to Review.",
                        style = HearthText.Caption, color = palette.textSecondary)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Auto-match at $threshold%", style = HearthText.Caption, color = palette.text,
                            modifier = Modifier.weight(1f))
                        TextButton(onClick = { sourceMenu = true }) { Text(sourceFilter ?: "All libraries") }
                        DropdownMenu(expanded = sourceMenu, onDismissRequest = { sourceMenu = false }) {
                            DropdownMenuItem(text = { Text("All libraries") }, onClick = { sourceFilter = null; sourceMenu = false })
                            sourceNames.forEach { name -> DropdownMenuItem(text = { Text(name) }, onClick = { sourceFilter = name; sourceMenu = false }) }
                        }
                    }
                    Slider(value = threshold.toFloat(), onValueChange = { vm.setThreshold(it.toInt()) }, valueRange = 70f..95f,
                        steps = 4)
                    if (batchProgress.running) {
                        Text("${batchProgress.processed}/${batchProgress.total} checked · ${batchProgress.applied} applied · ${batchProgress.queued} for review",
                            style = HearthText.Caption, color = palette.textSecondary)
                        TextButton(onClick = vm::cancelBatch) { Text("Stop batch") }
                    } else {
                        TextButton(onClick = { showBatchConfirm = true }, enabled = batchBooks.isNotEmpty()) {
                            Text("Match ${batchBooks.size} audiobooks")
                        }
                        if (batchProgress.total > 0) Text("Last run: ${batchProgress.applied} applied · ${batchProgress.queued} for review · ${batchProgress.errors} errors",
                            style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
            }
        }
        if (tab == 3) {
            if (selectedCluster == null) {
                if (duplicateClusters.isEmpty() && groupedByKeeper.isEmpty()) item {
                    Text("No likely duplicates found.", style = HearthText.Body, color = palette.textSecondary,
                        modifier = Modifier.padding(24.dp))
                }
                items(duplicateClusters, key = DuplicateBookCluster::id) { cluster ->
                    Column(Modifier.fillMaxWidth().clickable { selectedCluster = cluster }
                        .padding(horizontal = 24.dp, vertical = 12.dp)) {
                        Text(cluster.title, style = HearthText.Label, color = palette.text)
                        Text("${cluster.books.size} editions · ${cluster.reason.displayName} · ${cluster.confidence}%",
                            style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
                if (groupedByKeeper.isNotEmpty()) item {
                    Text("Grouped copies", style = HearthText.Label, color = palette.text,
                        modifier = Modifier.padding(horizontal = 24.dp, vertical = 12.dp))
                }
                items(groupedByKeeper.entries.toList(), key = { it.key }) { (keeper, hidden) ->
                    Row(Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(books.firstOrNull { it.uniqueKey == keeper }?.title ?: keeper,
                                style = HearthText.Label, color = palette.text)
                            Text("${hidden.size} grouped ${if (hidden.size == 1) "copy" else "copies"}",
                                style = HearthText.Caption, color = palette.textSecondary)
                        }
                        TextButton(onClick = { unmergeKey = keeper }) { Text("Separate") }
                    }
                }
            } else {
                val cluster = selectedCluster!!
                item { Text("Choose the edition to show in Library. Other copies remain stored and can be separated later.",
                    style = HearthText.Body, color = palette.textSecondary, modifier = Modifier.padding(horizontal = 24.dp)) }
                items(cluster.books, key = Book::uniqueKey) { book ->
                    Row(Modifier.fillMaxWidth().clickable { keeperKey = book.uniqueKey }
                        .padding(horizontal = 24.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = keeperKey == book.uniqueKey, onClick = { keeperKey = book.uniqueKey })
                        Column(Modifier.weight(1f)) {
                            Text(book.title, style = HearthText.Label, color = palette.text)
                            Text("${book.author.orEmpty()} · ${book.source.name}", style = HearthText.Caption,
                                color = palette.textSecondary)
                        }
                    }
                }
                item { TextButton(onClick = { showMergeConfirm = true }, enabled = !busy,
                    modifier = Modifier.padding(horizontal = 24.dp)) { Text("Group ${cluster.books.size - 1} duplicates") } }
            }
        } else if (selected == null) {
            if (tab == 2 && pending.isNotEmpty()) item {
                TextButton(onClick = { showClearConfirm = true }, modifier = Modifier.padding(horizontal = 24.dp)) { Text("Clear review queue") }
            }
            val rows = when (tab) {
                0 -> unmatched.map { it.book }
                1 -> unlinked
                else -> pending.mapNotNull { entry -> books.firstOrNull { it.uniqueKey == entry.bookKey } }
            }
            if (rows.isEmpty()) item { Text(when (tab) {
                0 -> "No books need metadata matching."
                1 -> "No unlinked ebooks found."
                else -> "The review queue is empty."
            },
                style = HearthText.Body, color = palette.textSecondary, modifier = Modifier.padding(24.dp)) }
            items(rows, key = Book::uniqueKey) { book ->
                val subtitle = when (tab) {
                    0 -> unmatched.firstOrNull { it.book.uniqueKey == book.uniqueKey }?.summary
                    2 -> pending.firstOrNull { it.bookKey == book.uniqueKey }?.let { "${(it.confidence * 100).toInt()}% · ${it.sourceName}" }
                    else -> null
                }
                MatchBookRow(book, subtitle) {
                    selected = book
                }
            }
        } else {
            val book = selected!!
            item {
                OutlinedTextField(query, { query = it }, label = { Text("Search title or author") }, singleLine = true,
                    trailingIcon = { TextButton(onClick = {
                        if (tab == 1) vm.searchLinks(book, query) else vm.searchMetadata(book, query)
                    }) { Text("Search") } },
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp))
            }
            if (busy) item { CircularProgressIndicator(Modifier.padding(24.dp).size(24.dp), color = palette.ember) }
            if (tab != 1) {
                if (tab == 2) item {
                    TextButton(onClick = { vm.discardPending(book.uniqueKey); selected = null },
                        modifier = Modifier.padding(horizontal = 24.dp)) { Text("Discard suggestion") }
                }
                if (searched && !busy && matches.isEmpty()) item {
                    Text("No matches found. Try a shorter search.", style = HearthText.Body, color = palette.textSecondary,
                        modifier = Modifier.padding(24.dp))
                }
                items(matches, key = LibraryMetadataMatch::id) { match ->
                    Column(Modifier.fillMaxWidth().clickable { selectedMatch = match }.padding(horizontal = 24.dp, vertical = 12.dp)) {
                        Text(match.title, style = HearthText.Label, color = palette.text)
                        val queued = pending.firstOrNull { it.bookKey == book.uniqueKey && it.candidateId == match.id }
                        Text("${if (queued != null) "Queued suggestion · " else ""}${match.author.orEmpty()} · ${match.sourceName} · ${(match.confidence * 100).toInt()}%",
                            style = HearthText.Caption, color = palette.textSecondary)
                    }
                }
            } else {
                if (searched && !busy && candidates.isEmpty()) item {
                    Text("No audiobook matches found. Try the title or author.", style = HearthText.Body, color = palette.textSecondary,
                        modifier = Modifier.padding(24.dp))
                }
                items(candidates, key = { it.book.uniqueKey }) { candidate ->
                    MatchBookRow(candidate.book, "${candidate.confidence}% match") { selectedLink = candidate.book }
                }
                links.firstOrNull { it.ebookKey == book.uniqueKey || it.audiobookKey == book.uniqueKey }?.let {
                    item { TextButton(onClick = { vm.unlink(book) }, modifier = Modifier.padding(horizontal = 24.dp)) { Text("Unlink current edition") } }
                }
            }
        }
    }

    selectedMatch?.let { match ->
        AlertDialog(onDismissRequest = { selectedMatch = null }, title = { Text("Apply metadata match?") },
            text = { Text("${match.title} by ${match.author.orEmpty()}\n${match.sourceName} · ${(match.confidence * 100).toInt()}% confidence\n${match.matchReason}") },
            confirmButton = { TextButton(onClick = { selected?.let { vm.applyMetadata(it, match) }; selected = null; selectedMatch = null }) { Text("Apply") } },
            dismissButton = { TextButton(onClick = { selectedMatch = null }) { Text("Cancel") } })
    }
    selectedLink?.let { counterpart ->
        AlertDialog(onDismissRequest = { selectedLink = null }, title = { Text("Link these editions?") },
            text = { Text("${selected?.title} and ${counterpart.title} will share an ebook and audiobook link.") },
            confirmButton = { TextButton(onClick = { selected?.let { vm.link(it, counterpart) }; selected = null; selectedLink = null }) { Text("Link") } },
            dismissButton = { TextButton(onClick = { selectedLink = null }) { Text("Cancel") } })
    }
    if (showBatchConfirm) {
        AlertDialog(onDismissRequest = { showBatchConfirm = false }, title = { Text("Match ${batchBooks.size} audiobooks?") },
            text = { Text("Matches at or above $threshold% confidence with a clear lead will be applied. Other suggestions will wait in Review.") },
            confirmButton = { TextButton(onClick = { vm.runBatch(batchBooks); showBatchConfirm = false }) { Text("Start") } },
            dismissButton = { TextButton(onClick = { showBatchConfirm = false }) { Text("Cancel") } })
    }
    if (showClearConfirm) {
        AlertDialog(onDismissRequest = { showClearConfirm = false }, title = { Text("Clear review queue?") },
            text = { Text("This removes pending suggestions. Matched book metadata stays in your library.") },
            confirmButton = { TextButton(onClick = { vm.clearPending(); showClearConfirm = false }) { Text("Clear") } },
            dismissButton = { TextButton(onClick = { showClearConfirm = false }) { Text("Cancel") } })
    }
    if (showMergeConfirm && selectedCluster != null) {
        val cluster = selectedCluster!!
        AlertDialog(onDismissRequest = { showMergeConfirm = false }, title = { Text("Group duplicate copies?") },
            text = { Text("${cluster.books.size - 1} copies will appear under the selected edition. Their files and reading data stay stored.") },
            confirmButton = { TextButton(onClick = {
                vm.mergeDuplicate(cluster, keeperKey)
                selectedCluster = null
                showMergeConfirm = false
            }) { Text("Group") } },
            dismissButton = { TextButton(onClick = { showMergeConfirm = false }) { Text("Cancel") } })
    }
    unmergeKey?.let { keeper ->
        AlertDialog(onDismissRequest = { unmergeKey = null }, title = { Text("Separate copies?") },
            text = { Text("Each copy will appear in Library again with its own reading data.") },
            confirmButton = { TextButton(onClick = { vm.unmergeDuplicate(keeper); unmergeKey = null }) { Text("Separate") } },
            dismissButton = { TextButton(onClick = { unmergeKey = null }) { Text("Cancel") } })
    }
}

@Composable
private fun MatchBookRow(book: Book, subtitle: String?, onClick: () -> Unit) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 24.dp, vertical = 12.dp)) {
        Text(book.title, style = HearthText.Label, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
        Text(subtitle ?: book.author.orEmpty(), style = HearthText.Caption, color = palette.textSecondary, maxLines = 1)
    }
}
