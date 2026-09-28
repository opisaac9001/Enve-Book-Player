package com.enve.hearth.opds

import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.outlined.OpenInNew
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.engine.opds.OpdsAcquisitionAction
import com.enve.engine.opds.OpdsAcquisitionOption
import com.enve.engine.opds.OpdsAuthChallenge
import com.enve.engine.opds.OpdsAuthMethodKind
import com.enve.engine.opds.OpdsAuthMethodState
import com.enve.engine.opds.OpdsAvailabilityState
import com.enve.engine.opds.OpdsBrowseEntry
import com.enve.engine.opds.OpdsCatalogPage
import com.enve.engine.opds.OpdsPaginationState
import com.enve.engine.opds.OpdsShelfState
import com.enve.hearth.design.CoverTile
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.ShelfHeader
import com.enve.hearth.design.hearthDisplay

@Composable
fun HearthOpdsCatalogScreen(
    connectionId: String,
    sourceName: String,
    onBack: () -> Unit,
    onAuthorize: (connectionId: String, methodType: String, authorizeUrl: String) -> Unit,
    onOpenExternal: (String) -> Unit,
) {
    val vm: HearthOpdsCatalogViewModel = hiltViewModel()
    val state by vm.state.collectAsStateWithLifecycle()
    val palette = Hearth.palette

    LaunchedEffect(connectionId) { vm.start(connectionId) }
    LaunchedEffect(state.pendingAuthorizeUrl) {
        val url = state.pendingAuthorizeUrl ?: return@LaunchedEffect
        onAuthorize(connectionId, state.signInMethod?.type.orEmpty(), url)
        vm.consumeAuthorizeUrl()
    }
    BackHandler { if (!vm.back()) onBack() }

    Column(Modifier.fillMaxSize().background(palette.bg)) {
        CatalogTopBar(
            title = state.page?.title?.takeIf { it.isNotBlank() } ?: sourceName,
            subtitle = state.page?.pagination?.summary(),
            onBack = { if (!vm.back()) onBack() },
        )

        state.notice?.let { notice ->
            Text(
                notice,
                style = HearthText.Caption,
                color = palette.ember,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = Hearth.Spacing.XL, vertical = Hearth.Spacing.S),
            )
        }

        when {
            state.challenge != null -> SignInPanel(
                challenge = state.challenge!!,
                method = state.signInMethod,
                isSigningIn = state.isSigningIn,
                error = state.signInError,
                onChooseMethod = vm::chooseSignInMethod,
                onSignIn = vm::signIn,
                onAuthorize = vm::startImplicitSignIn,
                onDismiss = { vm.dismissChallenge(); onBack() },
                onOpenHelp = onOpenExternal,
            )

            state.isLoading && state.page == null -> LoadingPanel()

            state.error != null -> MessagePanel(
                title = "This catalog could not be opened",
                message = state.error!!,
                actionLabel = "Try again",
                onAction = vm::reload,
            )

            else -> CatalogBody(
                page = state.page,
                query = state.query,
                isLoading = state.isLoading,
                onQueryChange = vm::setQuery,
                onSearch = { state.page?.search?.let(vm::search) },
                onOpen = vm::open,
                onOpenEntry = vm::openEntry,
                onSelectBook = vm::selectBook,
            )
        }
    }

    state.sheet?.let { sheet ->
        AcquisitionSheet(sheet = sheet, onDismiss = vm::dismissBook, onChoose = vm::choose)
    }

    LaunchedEffect(state.externalUrl) {
        val url = state.externalUrl ?: return@LaunchedEffect
        onOpenExternal(url)
        vm.consumeExternalUrl()
    }
    LaunchedEffect(state.notice) {
        if (state.notice == null) return@LaunchedEffect
        delay(NOTICE_DURATION_MS)
        vm.dismissNotice()
    }
}

private const val NOTICE_DURATION_MS = 4_000L

@Composable
private fun CatalogTopBar(title: String, subtitle: String?, onBack: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().statusBarsPadding().padding(Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.AutoMirrored.Outlined.ArrowBack,
            "Back",
            tint = palette.text,
            modifier = Modifier
                .clip(CircleShape)
                .clickable(onClick = onBack)
                .padding(Hearth.Spacing.S)
                .size(26.dp),
        )
        Spacer(Modifier.size(Hearth.Spacing.S))
        Column(Modifier.weight(1f)) {
            Overline("Catalog")
            Text(
                title,
                style = HearthText.ScreenTitle,
                color = palette.text,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            subtitle?.let { Text(it, style = HearthText.Caption, color = palette.textTertiary) }
        }
    }
}

@Composable
private fun CatalogBody(
    page: OpdsCatalogPage?,
    query: String,
    isLoading: Boolean,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit,
    onOpen: (String) -> Unit,
    onOpenEntry: (OpdsBrowseEntry) -> Unit,
    onSelectBook: (Book) -> Unit,
) {
    val palette = Hearth.palette
    if (page == null) {
        MessagePanel(title = "Nothing here yet", message = "This catalog returned no entries.")
        return
    }

    LazyColumn(
        Modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = Hearth.Spacing.XL,
            end = Hearth.Spacing.XL,
            bottom = LocalMantelInset.current + Hearth.Spacing.XXL,
        ),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        if (isLoading) {
            item("loading") {
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
                    CircularProgressIndicator(color = palette.ember, modifier = Modifier.size(22.dp))
                }
            }
        }

        page.search?.let { search ->
            item("search") {
                OutlinedTextField(
                    value = query,
                    onValueChange = onQueryChange,
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    label = { Text(search.title ?: "Search this catalog") },
                    trailingIcon = {
                        Icon(
                            Icons.Outlined.Search,
                            "Search",
                            tint = palette.ember,
                            modifier = Modifier
                                .clip(CircleShape)
                                .clickable(onClick = onSearch)
                                .padding(Hearth.Spacing.S),
                        )
                    },
                )
            }
        }

        page.facetGroups.forEachIndexed { groupIndex, group ->
            item("facet-$groupIndex") {
                Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    if (group.title.isNotBlank()) Overline(group.title)
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                        itemsIndexed(group.facets, key = { index, _ -> index }) { _, facet ->
                            HearthChip(
                                label = facet.label(),
                                selected = facet.isActive,
                                onClick = { onOpen(facet.href) },
                            )
                        }
                    }
                }
            }
        }

        if (page.navigation.isNotEmpty()) {
            item("nav-header") { Overline("Browse") }
            itemsIndexed(page.navigation, key = { index, _ -> "nav-$index" }) { _, entry ->
                NavigationRow(entry, onClick = { onOpenEntry(entry) })
            }
        }

        page.shelves.forEachIndexed { shelfIndex, shelf ->
            item("shelf-$shelfIndex") {
                ShelfRow(shelf, onOpen = onOpen, onOpenEntry = onOpenEntry, onSelectBook = onSelectBook)
            }
        }

        page.singlePublication?.let { book ->
            item("single-${book.id}") { PublicationCard(book, onClick = { onSelectBook(book) }) }
        }

        if (page.books.isNotEmpty()) {
            item("books-header") { Overline("Publications") }
            itemsIndexed(page.books, key = { index, _ -> "book-$index" }) { _, book ->
                PublicationRow(book, onClick = { onSelectBook(book) })
            }
        }

        if (page.isEmpty && !isLoading) {
            item("empty") {
                Text(
                    "This catalog returned no entries.",
                    style = HearthText.Body,
                    color = palette.textSecondary,
                )
            }
        }

        item("pagination") { PaginationRow(page.pagination, onOpen) }
    }
}

@Composable
private fun NavigationRow(entry: OpdsBrowseEntry, onClick: () -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Row(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = Hearth.Spacing.L, vertical = Hearth.Spacing.M),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                entry.title.ifBlank { "Untitled" },
                style = HearthText.Label,
                color = palette.text,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            val caption = when {
                entry.isWebCatalog -> "Opens in your browser"
                entry.count != null -> "${entry.count} ${if (entry.count == 1) "entry" else "entries"}"
                else -> null
            }
            caption?.let { Text(it, style = HearthText.Caption, color = palette.textTertiary) }
        }
        Icon(
            if (entry.isWebCatalog) Icons.AutoMirrored.Outlined.OpenInNew else Icons.AutoMirrored.Outlined.KeyboardArrowRight,
            null,
            tint = palette.textTertiary,
            modifier = Modifier.size(20.dp),
        )
    }
}

@Composable
private fun ShelfRow(
    shelf: OpdsShelfState,
    onOpen: (String) -> Unit,
    onOpenEntry: (OpdsBrowseEntry) -> Unit,
    onSelectBook: (Book) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        ShelfHeader(
            title = shelf.title.ifBlank { "Group" },
            modifier = Modifier.fillMaxWidth(),
            actionLabel = shelf.moreHref?.let { "See all" },
            onAction = shelf.moreHref?.let { href -> { onOpen(href) } },
        )
        if (shelf.books.isNotEmpty()) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                itemsIndexed(shelf.books, key = { index, _ -> index }) { _, book ->
                    Column(Modifier.width(112.dp).clickable { onSelectBook(book) }) {
                        CoverTile(
                            model = book.coverUrl,
                            modifier = Modifier.fillMaxWidth(),
                            mediaType = book.mediaType,
                        )
                        Spacer(Modifier.size(Hearth.Spacing.S))
                        Text(
                            book.title,
                            style = hearthDisplay(13.sp, FontWeight.SemiBold),
                            color = Hearth.palette.text,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
        shelf.navigation.forEach { entry ->
            NavigationRow(entry, onClick = { onOpenEntry(entry) })
        }
    }
}

@Composable
private fun PublicationRow(book: Book, onClick: () -> Unit) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        CoverTile(model = book.coverUrl, modifier = Modifier.width(56.dp), mediaType = book.mediaType)
        Column(Modifier.weight(1f).padding(top = Hearth.Spacing.XS)) {
            Text(
                book.title,
                style = hearthDisplay(15.sp, FontWeight.SemiBold),
                color = palette.text,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            book.author?.let {
                Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            listOfNotNull(book.primaryFileType, book.publisher, book.language)
                .joinToString(" · ")
                .takeIf { it.isNotBlank() }
                ?.let { Text(it, style = HearthText.Caption, color = palette.textTertiary, maxLines = 1) }
        }
    }
}

@Composable
private fun PublicationCard(book: Book, onClick: () -> Unit) {
    val palette = Hearth.palette
    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
        PublicationRow(book, onClick)
        book.description?.takeIf { it.isNotBlank() }?.let {
            Text(it, style = HearthText.Body, color = palette.textSecondary, maxLines = 12, overflow = TextOverflow.Ellipsis)
        }
        EmberButton("View editions", onClick = onClick, modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun PaginationRow(pagination: OpdsPaginationState, onOpen: (String) -> Unit) {
    val palette = Hearth.palette
    val hasLinks = listOfNotNull(
        pagination.firstUrl,
        pagination.previousUrl,
        pagination.nextUrl,
        pagination.lastUrl,
    ).isNotEmpty()
    if (!hasLinks && !pagination.truncated) return

    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        if (hasLinks) {
            Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                pagination.firstUrl?.let { QuietButton("First", onClick = { onOpen(it) }) }
                pagination.previousUrl?.let { QuietButton("Previous", onClick = { onOpen(it) }) }
                pagination.nextUrl?.let { QuietButton("Next", onClick = { onOpen(it) }) }
                pagination.lastUrl?.let { QuietButton("Last", onClick = { onOpen(it) }) }
            }
        }
        if (pagination.truncated) {
            Text(
                "This catalog is larger than Enve will crawl in one pass.",
                style = HearthText.Caption,
                color = palette.textTertiary,
            )
        }
    }
}

@Composable
private fun SignInPanel(
    challenge: OpdsAuthChallenge,
    method: OpdsAuthMethodState?,
    isSigningIn: Boolean,
    error: String?,
    onChooseMethod: (OpdsAuthMethodState) -> Unit,
    onSignIn: (String, String) -> Unit,
    onAuthorize: () -> Unit,
    onDismiss: () -> Unit,
    onOpenHelp: (String) -> Unit,
) {
    val palette = Hearth.palette
    var username by remember(method?.type) { mutableStateOf("") }
    var password by remember(method?.type) { mutableStateOf("") }
    val usable = challenge.methods.filter { it.kind != OpdsAuthMethodKind.UNSUPPORTED }

    Column(
        Modifier
            .fillMaxSize()
            .padding(horizontal = Hearth.Spacing.XL)
            .padding(bottom = LocalMantelInset.current),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
    ) {
        Overline("Sign in")
        Text(
            challenge.title ?: "This catalog needs an account",
            style = HearthText.BookTitle,
            color = palette.text,
        )
        challenge.description?.let { Text(it, style = HearthText.Body, color = palette.textSecondary) }

        if (usable.size > 1) {
            LazyRow(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                itemsIndexed(usable, key = { index, _ -> index }) { _, candidate ->
                    HearthChip(
                        label = candidate.kind.label(),
                        selected = candidate.type == method?.type,
                        onClick = { onChooseMethod(candidate) },
                    )
                }
            }
        }

        when (method?.kind) {
            OpdsAuthMethodKind.BASIC, OpdsAuthMethodKind.OAUTH_PASSWORD -> {
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    label = { Text(method.loginLabel ?: "Username") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text(method.passwordLabel ?: "Password") },
                    singleLine = true,
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = KeyboardType.Password,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                EmberButton(
                    if (isSigningIn) "Signing in…" else "Sign in",
                    onClick = { if (!isSigningIn) onSignIn(username, password) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            OpdsAuthMethodKind.OAUTH_IMPLICIT -> EmberButton(
                "Continue in browser",
                onClick = onAuthorize,
                modifier = Modifier.fillMaxWidth(),
            )

            else -> Text(
                "Enve does not support the sign-in methods this catalog offers.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
        }

        error?.let { Text(it, style = HearthText.Caption, color = palette.ember) }

        challenge.helpUrls.firstOrNull()?.let { help ->
            QuietButton("Get help", onClick = { onOpenHelp(help) }, modifier = Modifier.fillMaxWidth())
        }
        QuietButton("Not now", onClick = onDismiss, modifier = Modifier.fillMaxWidth())
    }
}

@Composable
private fun AcquisitionSheet(
    sheet: OpdsBookSheetState,
    onDismiss: () -> Unit,
    onChoose: (OpdsAcquisitionOption) -> Unit,
) {
    val palette = Hearth.palette
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        confirmButton = {
            androidx.compose.material3.TextButton(onClick = onDismiss) {
                Text("Close", color = palette.ember)
            }
        },
        title = {
            Text(sheet.book.title, style = HearthText.BookTitle, color = palette.text, maxLines = 3)
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M)) {
                when {
                    sheet.isLoading -> Text("Reading editions…", style = HearthText.Caption, color = palette.textTertiary)
                    sheet.options.isEmpty() -> Text(
                        "This catalog listed no download or purchase options for this title.",
                        style = HearthText.Body,
                        color = palette.textSecondary,
                    )

                    else -> sheet.options.forEach { option ->
                        AcquisitionOptionRow(option, onChoose)
                    }
                }
            }
        },
        containerColor = palette.bgElevated,
    )
}

@Composable
private fun AcquisitionOptionRow(option: OpdsAcquisitionOption, onChoose: (OpdsAcquisitionOption) -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .border(1.dp, palette.hairline, shape)
            .then(
                if (option.isActionable) Modifier.clickable { onChoose(option) } else Modifier,
            )
            .padding(Hearth.Spacing.M),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(option.label, style = HearthText.Label, color = palette.text, modifier = Modifier.weight(1f))
            option.priceLabel?.let { Text(it, style = HearthText.Label, color = palette.ember) }
        }
        listOfNotNull(option.formatLabel, option.action.label())
            .joinToString(" · ")
            .takeIf { it.isNotBlank() }
            ?.let { Text(it, style = HearthText.Caption, color = palette.textTertiary) }
        option.availability?.summary()?.let {
            Text(it, style = HearthText.Caption, color = palette.textSecondary)
        }
        option.unsupportedReason?.let {
            Text(it, style = HearthText.Caption, color = palette.textSecondary)
        }
    }
}

@Composable
private fun LoadingPanel() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = Hearth.palette.ember)
    }
}

@Composable
private fun MessagePanel(
    title: String,
    message: String,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    val palette = Hearth.palette
    Column(
        Modifier.fillMaxSize().padding(Hearth.Spacing.XL),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Text(title, style = HearthText.BookTitle, color = palette.text)
        Text(message, style = HearthText.Body, color = palette.textSecondary)
        if (actionLabel != null && onAction != null) {
            EmberButton(actionLabel, onClick = onAction)
        }
    }
}

private fun OpdsBrowseEntry.label(): String =
    if (count == null) title.ifBlank { "Untitled" } else "${title.ifBlank { "Untitled" }} ($count)"

private fun OpdsAcquisitionAction.label(): String = when (this) {
    OpdsAcquisitionAction.OPEN -> "Download"
    OpdsAcquisitionAction.SAMPLE -> "Sample"
    OpdsAcquisitionAction.BORROW -> "Borrow"
    OpdsAcquisitionAction.BUY -> "Purchase"
    OpdsAcquisitionAction.SUBSCRIBE -> "Subscription"
    OpdsAcquisitionAction.UNSUPPORTED -> "Not supported"
}

private fun OpdsAuthMethodKind.label(): String = when (this) {
    OpdsAuthMethodKind.BASIC -> "Password"
    OpdsAuthMethodKind.OAUTH_PASSWORD -> "OAuth"
    OpdsAuthMethodKind.OAUTH_IMPLICIT -> "Browser"
    OpdsAuthMethodKind.UNSUPPORTED -> "Unsupported"
}

private fun OpdsPaginationState.summary(): String? = listOfNotNull(
    totalResults?.let { "$it ${if (it == 1) "result" else "results"}" },
    currentPage?.let { "page $it" },
).joinToString(" · ").takeIf { it.isNotBlank() }

private fun OpdsAvailabilityState.summary(): String? = listOfNotNull(
    state?.replaceFirstChar(Char::uppercase),
    copiesAvailable?.let { available ->
        copiesTotal?.let { "$available of $it available" } ?: "$available available"
    },
    holdPosition?.let { "hold #$it" },
    holdsTotal?.takeIf { holdPosition == null }?.let { "$it on hold" },
    until?.let { "until $it" },
).joinToString(" · ").takeIf { it.isNotBlank() }
