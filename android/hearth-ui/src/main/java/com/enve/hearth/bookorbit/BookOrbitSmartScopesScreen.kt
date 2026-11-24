package com.enve.hearth.bookorbit

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.engine.bookorbit.BookOrbitFailureReason
import com.enve.engine.bookorbit.BookOrbitSmartScope
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthFormat
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.hearthDisplay
import com.enve.hearth.shell.profileViewModel

@Composable
fun BookOrbitSmartScopesScreen(
    initialAccountId: String?,
    selectedBookKey: String?,
    onBack: () -> Unit,
    onOpenBook: (Book) -> Unit,
) {
    val vm: BookOrbitSmartScopesViewModel = profileViewModel()
    LaunchedEffect(initialAccountId) { initialAccountId?.let(vm::selectAccount) }
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val accountId by vm.activeAccountId.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()
    val books by vm.books.collectAsStateWithLifecycle()
    val booksFailure by vm.booksFailure.collectAsStateWithLifecycle()
    val searchInput by vm.searchInput.collectAsStateWithLifecycle()
    val palette = Hearth.palette

    BookOrbitScreen(
        overline = "BookOrbit",
        title = "Smart scopes",
        accounts = accounts,
        selectedAccountId = accountId,
        onSelectAccount = vm::selectAccount,
        onBack = onBack,
        trailing = {
            Box(
                Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .clickable(enabled = !state.loading, role = Role.Button, onClick = vm::refresh)
                    .testTag("bookorbit-scopes-refresh"),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.Refresh,
                    contentDescription = "Refresh smart scopes",
                    tint = if (state.loading) palette.textTertiary else palette.text,
                    modifier = Modifier.size(22.dp),
                )
            }
        },
    ) {
        Column(Modifier.weight(1f).fillMaxWidth()) {
            val failure = state.failure
            when {
                state.noAccount -> BookOrbitPlaceholder(
                    headline = "No BookOrbit account",
                    body = "Add a BookOrbit source to browse the smart scopes saved on your server.",
                )
                state.unsupported -> BookOrbitPlaceholder(
                    headline = "Smart scopes unavailable",
                    body = "This BookOrbit server runs a build without smart scopes.",
                    onRetry = vm::refresh,
                )
                !state.loaded && failure != null -> BookOrbitPlaceholder(
                    headline = failure.headline(),
                    body = failure.explanation(),
                    onRetry = vm::refresh,
                )
                !state.loaded -> BookOrbitLoadingBlock()
                state.scopes.isEmpty() -> BookOrbitPlaceholder(
                    headline = "No smart scopes yet",
                    body = "Smart scopes you save in BookOrbit appear here by name. Create one on the server, then refresh.",
                    onRetry = vm::refresh,
                )
                else -> {
                    if (failure != null) {
                        BookOrbitInlineError(
                            message = "Couldn't refresh smart scopes. Showing the last list.",
                            onRetry = vm::refresh,
                            tag = "bookorbit-scopes-refresh-error",
                        )
                    }
                    ScopeRow(state.scopes, state.selectedScopeId, vm::selectScope)
                    ScopeSearchField(searchInput, vm::setSearch)
                    ScopeBooks(
                        scope = state.selectedScope,
                        books = books,
                        failure = booksFailure,
                        searching = searchInput.isNotBlank(),
                        selectedBookKey = selectedBookKey,
                        onRetry = vm::refreshBooks,
                        onLoadMore = vm::loadMoreBooks,
                        onOpenBook = onOpenBook,
                    )
                }
            }
        }
    }
}

@Composable
private fun ScopeRow(
    scopes: List<BookOrbitSmartScope>,
    selectedScopeId: Int?,
    onSelect: (Int) -> Unit,
) {
    LazyRow(
        contentPadding = PaddingValues(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XS),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
        modifier = Modifier.testTag("bookorbit-scopes-row"),
    ) {
        items(scopes, key = { it.id }) { scope ->
            HearthChip(
                label = scope.bookCount?.let { "${scope.name} · $it" } ?: scope.name,
                selected = scope.id == selectedScopeId,
                onClick = { onSelect(scope.id) },
                modifier = Modifier.testTag("bookorbit-scope-${scope.id}"),
            )
        }
    }
}

@Composable
private fun ScopeSearchField(value: String, onValueChange: (String) -> Unit) {
    val palette = Hearth.palette
    TextField(
        value = value,
        onValueChange = onValueChange,
        placeholder = { Text("Search this scope", style = HearthText.Body) },
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S)
            .testTag("bookorbit-scopes-search"),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = palette.bgElevated,
            unfocusedContainerColor = palette.bgElevated,
            focusedIndicatorColor = Color.Transparent,
            unfocusedIndicatorColor = Color.Transparent,
            focusedTextColor = palette.text,
            unfocusedTextColor = palette.text,
            cursorColor = palette.ember,
            focusedPlaceholderColor = palette.textTertiary,
            unfocusedPlaceholderColor = palette.textTertiary,
        ),
        shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Inner),
    )
}

@Composable
private fun ScopeBooks(
    scope: BookOrbitSmartScope?,
    books: BookOrbitPagedList<Book>,
    failure: BookOrbitFailureReason?,
    searching: Boolean,
    selectedBookKey: String?,
    onRetry: () -> Unit,
    onLoadMore: () -> Unit,
    onOpenBook: (Book) -> Unit,
) {
    val palette = Hearth.palette
    when {
        books.failure == BookOrbitPageFailure.FIRST_PAGE -> {
            val reason = failure ?: BookOrbitFailureReason.UNREACHABLE
            BookOrbitPlaceholder(headline = reason.headline(), body = reason.explanation(), onRetry = onRetry)
        }
        books.showsFirstLoad || books.loadedPages == 0 -> BookOrbitLoadingBlock()
        books.items.isEmpty() -> BookOrbitPlaceholder(
            headline = if (searching) "No books match" else "This scope is empty",
            body = if (searching) {
                "Nothing in ${scope?.name ?: "this scope"} matches that search."
            } else {
                "No book on the server currently matches this scope's rules."
            },
            onRetry = onRetry,
        )
        else -> {
            if (books.failure == BookOrbitPageFailure.REFRESH) {
                BookOrbitInlineError(
                    message = "Couldn't refresh this scope. Showing the last results.",
                    onRetry = onRetry,
                    tag = "bookorbit-scope-books-refresh-error",
                )
            }
            val total = books.total ?: books.items.size
            Text(
                if (total == 1) "1 book" else "$total books",
                style = HearthText.Caption,
                color = palette.textTertiary,
                modifier = Modifier
                    .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.XS)
                    .testTag("bookorbit-scope-total"),
            )
            val listState = rememberLazyListState()
            val nearEnd by remember {
                derivedStateOf {
                    val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
                    last >= listState.layoutInfo.totalItemsCount - 6
                }
            }
            val autoLoad = books.canLoadMore && books.failure == null
            LaunchedEffect(nearEnd, autoLoad, books.items.size) {
                if (nearEnd && autoLoad) onLoadMore()
            }
            LazyColumn(
                state = listState,
                modifier = Modifier.fillMaxSize().testTag("bookorbit-scope-books"),
                contentPadding = PaddingValues(
                    start = Hearth.Spacing.XL,
                    top = Hearth.Spacing.XS,
                    end = Hearth.Spacing.XL,
                    bottom = LocalMantelInset.current + Hearth.Spacing.XXL,
                ),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                items(books.items, key = { it.uniqueKey }) { book ->
                    ScopeBookRow(book, selected = book.uniqueKey == selectedBookKey, onOpen = { onOpenBook(book) })
                }
                item {
                    BookOrbitPageFooter(
                        list = books,
                        noun = "books",
                        onLoadMore = onLoadMore,
                        tag = "bookorbit-scope-books-more",
                    )
                }
            }
        }
    }
}

@Composable
private fun ScopeBookRow(book: Book, selected: Boolean, onOpen: () -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Inner)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(if (selected) palette.bgElevated else Color.Transparent)
            .then(if (selected) Modifier.border(if (Hearth.eink.active) 2.dp else 1.dp, palette.ember, shape) else Modifier)
            .semantics { this.selected = selected }
            .clickable(role = Role.Button, onClick = onOpen)
            .padding(Hearth.Spacing.S)
            .testTag("bookorbit-scope-book-${book.id}"),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CoverTile(
            model = book.coverUrl,
            mediaType = book.mediaType,
            modifier = Modifier.width(44.dp),
            contentDescription = null,
            progress = HearthFormat.progress(book),
            isFinished = book.isFinished,
        )
        Spacer(Modifier.width(Hearth.Spacing.M))
        Column(Modifier.weight(1f)) {
            Text(
                book.title,
                style = hearthDisplay(15.sp, FontWeight.SemiBold),
                color = palette.text,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            book.author?.takeIf { it.isNotBlank() }?.let { author ->
                Text(author, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
        }
    }
}
