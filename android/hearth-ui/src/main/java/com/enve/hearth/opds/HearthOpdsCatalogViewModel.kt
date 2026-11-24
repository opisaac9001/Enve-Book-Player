package com.enve.hearth.opds

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.engine.opds.OpdsAcquisitionAction
import com.enve.engine.opds.OpdsAcquisitionOption
import com.enve.engine.opds.OpdsAuthChallenge
import com.enve.engine.opds.OpdsAuthMethodKind
import com.enve.engine.opds.OpdsAuthMethodState
import com.enve.engine.opds.OpdsCatalogFacade
import com.enve.engine.opds.OpdsCatalogPage
import com.enve.engine.opds.OpdsCatalogResult
import com.enve.engine.opds.OpdsBrowseEntry
import com.enve.engine.opds.OpdsSearchState
import com.enve.engine.opds.OpdsShelfState
import com.enve.engine.opds.OpdsSignInResult
import com.enve.engine.library.LibraryDownloadStatus
import com.enve.engine.library.LibraryFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject

data class OpdsBookSheetState(
    val book: Book,
    val options: List<OpdsAcquisitionOption> = emptyList(),
    val isLoading: Boolean = true,
)

const val OPDS_BULK_LIMIT = 100

enum class OpdsBulkStatus { WAITING, DOWNLOADING, COMPLETED, FAILED, SKIPPED }

data class OpdsBulkItem(
    val book: Book,
    val options: List<OpdsAcquisitionOption> = emptyList(),
    val chosenHref: String? = null,
    val status: OpdsBulkStatus = OpdsBulkStatus.WAITING,
    val progress: Float = 0f,
    val message: String? = null,
) {
    val needsChoice: Boolean get() = status == OpdsBulkStatus.WAITING && chosenHref == null && options.size > 1
}

enum class OpdsBulkPhase { RESOLVING, REVIEW, IMPORTING, FINISHED }

data class OpdsBulkImportState(
    val phase: OpdsBulkPhase,
    val items: List<OpdsBulkItem>,
    val resolved: Int = 0,
    val wasCancelled: Boolean = false,
) {
    val ready: List<OpdsBulkItem> get() = items.filter { it.status == OpdsBulkStatus.WAITING && it.chosenHref != null }
    val ambiguous: List<OpdsBulkItem> get() = items.filter(OpdsBulkItem::needsChoice)
    val completedCount: Int get() = items.count { it.status == OpdsBulkStatus.COMPLETED }
    val failedCount: Int get() = items.count { it.status == OpdsBulkStatus.FAILED }
    val skippedCount: Int get() = items.count { it.status == OpdsBulkStatus.SKIPPED }
    val finishedCount: Int get() = items.count { it.status != OpdsBulkStatus.WAITING && it.status != OpdsBulkStatus.DOWNLOADING }
    val formatChoices: List<String>
        get() = ambiguous.flatMap { item -> item.options.mapNotNull(OpdsAcquisitionOption::formatLabel) }.distinct()
}

data class OpdsCatalogUiState(
    val connectionId: String = "",
    val isLoading: Boolean = false,
    val page: OpdsCatalogPage? = null,
    val challenge: OpdsAuthChallenge? = null,
    val pendingAuthorizeUrl: String? = null,
    val signInMethod: OpdsAuthMethodState? = null,
    val signInError: String? = null,
    val isSigningIn: Boolean = false,
    val error: String? = null,
    val notice: String? = null,
    val query: String = "",
    val sheet: OpdsBookSheetState? = null,
    val externalUrl: String? = null,
    val isSelecting: Boolean = false,
    val selection: Set<String> = emptySet(),
    val bulk: OpdsBulkImportState? = null,
) {
    val canGoBack: Boolean get() = page != null
    val selectableBooks: List<Book>
        get() = page?.let { page ->
            (listOfNotNull(page.singlePublication) + page.books + page.shelves.flatMap(OpdsShelfState::books)).distinctBy(Book::id)
        }.orEmpty()
    val selectedBooks: List<Book> get() = selectableBooks.filter { it.id in selection }
}

@HiltViewModel
class HearthOpdsCatalogViewModel @Inject constructor(
    private val facade: OpdsCatalogFacade,
    private val library: LibraryFacade,
) : ViewModel() {

    private val _state = MutableStateFlow(OpdsCatalogUiState())
    val state: StateFlow<OpdsCatalogUiState> = _state.asStateFlow()

    private val history = ArrayDeque<String>()

    private var navigationJob: Job? = null

    private var bulkJob: Job? = null

    init {
        viewModelScope.launch {
            facade.signedIn.collect { connectionId ->
                if (connectionId == _state.value.connectionId) reload()
            }
        }
        viewModelScope.launch {
            facade.signInFailed.collect { message ->
                _state.update { it.copy(isSigningIn = false, signInError = message) }
            }
        }
        viewModelScope.launch {
            facade.progressionAuthChallenge.collect { challenge ->
                if (challenge == null) return@collect
                _state.update {
                    it.copy(
                        challenge = challenge,
                        signInMethod = challenge.methods.firstOrNull { method ->
                            method.kind != OpdsAuthMethodKind.UNSUPPORTED
                        },
                        signInError = null,
                    )
                }
            }
        }
    }

    fun start(connectionId: String) {
        if (_state.value.connectionId == connectionId && _state.value.page != null) return
        history.clear()
        _state.update { OpdsCatalogUiState(connectionId = connectionId, isLoading = true) }
        navigate { apply(facade.root(connectionId)) }
    }

    fun open(url: String) {
        val current = _state.value
        current.page?.url?.let(history::addLast)
        _state.update { it.copy(isLoading = true, error = null, query = "") }
        navigate { apply(facade.open(current.connectionId, url)) }
    }

    fun openEntry(entry: OpdsBrowseEntry) {
        if (entry.isWebCatalog) {
            _state.update { it.copy(externalUrl = entry.href) }
            return
        }
        open(entry.href)
    }

    fun back(): Boolean {
        val previous = history.removeLastOrNull() ?: return false
        _state.update { it.copy(isLoading = true, error = null, query = "") }
        navigate { apply(facade.open(_state.value.connectionId, previous)) }
        return true
    }

    fun setQuery(query: String) = _state.update { it.copy(query = query) }

    fun search(search: OpdsSearchState) {
        val current = _state.value
        current.page?.url?.let(history::addLast)
        _state.update { it.copy(isLoading = true, error = null) }
        navigate { apply(facade.search(current.connectionId, search, current.query)) }
    }

    fun reload() {
        val current = _state.value
        val url = current.page?.url
        _state.update { it.copy(isLoading = true, error = null) }
        navigate {
            apply(if (url == null) facade.root(current.connectionId) else facade.open(current.connectionId, url))
        }
    }

    private fun navigate(block: suspend () -> Unit) {
        navigationJob?.cancel()
        navigationJob = viewModelScope.launch { block() }
    }

    fun selectBook(book: Book) {
        _state.update { it.copy(sheet = OpdsBookSheetState(book = book)) }
        viewModelScope.launch {
            val options = facade.acquisitions(_state.value.connectionId, book.id)
            _state.update { current ->
                val sheet = current.sheet?.takeIf { it.book.id == book.id } ?: return@update current
                current.copy(sheet = sheet.copy(options = options, isLoading = false))
            }
        }
    }

    fun dismissBook() = _state.update { it.copy(sheet = null) }

    fun choose(option: OpdsAcquisitionOption) {
        if (!option.isActionable) return
        if (option.action != OpdsAcquisitionAction.OPEN && option.action != OpdsAcquisitionAction.SAMPLE) {
            _state.update { it.copy(externalUrl = option.href) }
            return
        }
        val current = _state.value
        val bookId = current.sheet?.book?.id ?: return
        viewModelScope.launch {
            val book = facade.selectAcquisition(current.connectionId, bookId, option.href)
            if (book == null) {
                _state.update { it.copy(externalUrl = option.href) }
                return@launch
            }
            library.download(book)
            _state.update { it.copy(sheet = null, notice = "Downloading ${book.title}") }
        }
    }

    fun setSelecting(selecting: Boolean) = _state.update { it.copy(isSelecting = selecting, selection = emptySet()) }

    fun toggleSelection(book: Book) = _state.update {
        when {
            book.id in it.selection -> it.copy(selection = it.selection - book.id)
            it.selection.size >= OPDS_BULK_LIMIT -> it.copy(notice = "You can import up to $OPDS_BULK_LIMIT books at a time")
            else -> it.copy(selection = it.selection + book.id)
        }
    }

    fun selectAllOnPage() = _state.update { state ->
        state.copy(selection = state.selectableBooks.take(OPDS_BULK_LIMIT).mapTo(mutableSetOf(), Book::id))
    }

    fun clearSelection() = _state.update { it.copy(selection = emptySet()) }

    fun reviewSelection() {
        val current = _state.value
        val books = current.selectedBooks
        if (books.isEmpty() || current.bulk != null) return
        _state.update {
            it.copy(bulk = OpdsBulkImportState(OpdsBulkPhase.RESOLVING, books.map { book -> OpdsBulkItem(book) }))
        }
        bulkJob = viewModelScope.launch {
            books.forEachIndexed { index, book ->
                val item = try {
                    opdsBulkItem(book, facade.acquisitions(current.connectionId, book.id))
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    OpdsBulkItem(book, status = OpdsBulkStatus.FAILED, message = "Couldn't read this book's downloads")
                }
                updateBulk { bulk -> bulk.copy(items = bulk.items.replace(item), resolved = index + 1) }
            }
            updateBulk { it.copy(phase = OpdsBulkPhase.REVIEW) }
        }
    }

    fun chooseBulkAcquisition(bookId: String, href: String) = updateBulk { bulk ->
        bulk.copy(items = bulk.items.map {
            if (it.book.id == bookId && it.status == OpdsBulkStatus.WAITING && it.options.any { option -> option.href == href }) {
                it.copy(chosenHref = href)
            } else it
        })
    }

    fun chooseBulkFormat(formatLabel: String) = updateBulk { bulk ->
        bulk.copy(
            items = bulk.items.map { item ->
                if (!item.needsChoice) return@map item
                item.options.firstOrNull { it.formatLabel == formatLabel }?.let { item.copy(chosenHref = it.href) } ?: item
            },
        )
    }

    fun skipBulkItem(bookId: String) = updateBulk { bulk ->
        bulk.copy(
            items = bulk.items.map {
                if (it.book.id == bookId && it.status == OpdsBulkStatus.WAITING) it.copy(status = OpdsBulkStatus.SKIPPED, message = "Skipped") else it
            },
        )
    }

    fun startBulkImport() {
        val current = _state.value
        val bulk = current.bulk?.takeIf { it.phase == OpdsBulkPhase.REVIEW && it.ready.isNotEmpty() } ?: return
        updateBulk {
            it.copy(
                phase = OpdsBulkPhase.IMPORTING,
                items = it.items.map { item ->
                    if (item.needsChoice) item.copy(status = OpdsBulkStatus.SKIPPED, message = "No file type chosen") else item
                },
            )
        }
        bulkJob = viewModelScope.launch {
            for (item in bulk.ready) {
                updateBulk { it.copy(items = it.items.replace(item.copy(status = OpdsBulkStatus.DOWNLOADING))) }
                val result = try {
                    downloadBulkItem(current.connectionId, item)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    item.copy(status = OpdsBulkStatus.FAILED, message = "The download failed")
                }
                updateBulk { it.copy(items = it.items.replace(result)) }
            }
            updateBulk { it.copy(phase = OpdsBulkPhase.FINISHED) }
            _state.update { it.copy(isSelecting = false, selection = emptySet()) }
        }
    }

    fun cancelBulk() {
        bulkJob?.cancel()
        bulkJob = null
        updateBulk { bulk ->
            bulk.copy(
                phase = OpdsBulkPhase.FINISHED,
                wasCancelled = true,
                items = bulk.items.map {
                    when (it.status) {
                        OpdsBulkStatus.DOWNLOADING ->
                            it.copy(status = OpdsBulkStatus.FAILED, message = "Stopped. A download already queued may still finish in Downloads.")
                        OpdsBulkStatus.WAITING -> it.copy(status = OpdsBulkStatus.SKIPPED, message = "Not started")
                        else -> it
                    }
                },
            )
        }
    }

    fun dismissBulk() {
        if (_state.value.bulk?.phase.let { it == OpdsBulkPhase.RESOLVING || it == OpdsBulkPhase.IMPORTING }) return
        _state.update { it.copy(bulk = null) }
    }

    private suspend fun downloadBulkItem(connectionId: String, item: OpdsBulkItem): OpdsBulkItem {
        val href = checkNotNull(item.chosenHref)
        val book = facade.selectAcquisition(connectionId, item.book.id, href)
            ?: return item.copy(status = OpdsBulkStatus.FAILED, message = "This catalog's download link couldn't be used")
        if (library.downloadState(book).first().status == LibraryDownloadStatus.COMPLETED) {
            return item.copy(status = OpdsBulkStatus.COMPLETED, progress = 1f, message = "Already downloaded")
        }
        library.download(book)
        val started = withTimeoutOrNull(DOWNLOAD_START_TIMEOUT_MS) {
            library.downloadState(book).first { it.isActive || it.status == LibraryDownloadStatus.COMPLETED }
        }
        val outcome = if (started == null) {
            library.downloadState(book).first()
        } else {
            library.downloadState(book)
                .onEach { state ->
                    if (state.isActive) {
                        updateBulk { it.copy(items = it.items.replace(item.copy(status = OpdsBulkStatus.DOWNLOADING, progress = state.progress))) }
                    }
                }
                .first { !it.isActive }
        }
        return when (outcome.status) {
            LibraryDownloadStatus.COMPLETED -> item.copy(status = OpdsBulkStatus.COMPLETED, progress = 1f, message = null)
            LibraryDownloadStatus.CANCELLED -> item.copy(status = OpdsBulkStatus.FAILED, message = "The download was cancelled")
            LibraryDownloadStatus.FAILED -> item.copy(status = OpdsBulkStatus.FAILED, message = outcome.errorMessage ?: "The download failed")
            else -> item.copy(status = OpdsBulkStatus.FAILED, message = "The download didn't start")
        }
    }

    private fun updateBulk(transform: (OpdsBulkImportState) -> OpdsBulkImportState) = _state.update { state ->
        state.bulk?.let { state.copy(bulk = transform(it)) } ?: state
    }

    fun consumeExternalUrl() = _state.update { it.copy(externalUrl = null) }

    fun dismissNotice() = _state.update { it.copy(notice = null) }

    fun chooseSignInMethod(method: OpdsAuthMethodState) =
        _state.update { it.copy(signInMethod = method, signInError = null) }

    fun signIn(username: String, password: String) {
        val method = _state.value.signInMethod ?: return
        val connectionId = _state.value.connectionId
        _state.update { it.copy(isSigningIn = true, signInError = null) }
        viewModelScope.launch {
            when (val result = facade.signIn(connectionId, method, username, password)) {
                OpdsSignInResult.Succeeded ->
                    _state.update {
                        it.copy(isSigningIn = false, challenge = null, signInMethod = null)
                    }

                is OpdsSignInResult.RedirectRequired ->
                    _state.update { it.copy(isSigningIn = false, pendingAuthorizeUrl = result.authorizeUrl) }

                is OpdsSignInResult.Failed ->
                    _state.update { it.copy(isSigningIn = false, signInError = result.message) }
            }
        }
    }

    fun startImplicitSignIn() {
        val method = _state.value.signInMethod ?: return
        if (method.kind != OpdsAuthMethodKind.OAUTH_IMPLICIT) return
        _state.update { it.copy(pendingAuthorizeUrl = method.authorizeUrl) }
    }

    fun consumeAuthorizeUrl() = _state.update { it.copy(pendingAuthorizeUrl = null) }

    fun dismissChallenge() {
        facade.dismissProgressionAuthChallenge()
        _state.update { it.copy(challenge = null, signInMethod = null, signInError = null) }
    }

    fun signOut() {
        val connectionId = _state.value.connectionId
        viewModelScope.launch {
            facade.signOut(connectionId)
            reload()
        }
    }

    private fun apply(result: OpdsCatalogResult) = _state.update { current ->
        when (result) {
            is OpdsCatalogResult.Loaded -> current.copy(
                isLoading = false,
                page = result.page,
                selection = emptySet(),
                challenge = null,
                signInMethod = null,
                error = null,
            )

            is OpdsCatalogResult.AuthenticationRequired -> current.copy(
                isLoading = false,
                challenge = result.challenge,
                signInMethod = result.challenge.methods.firstOrNull {
                    it.kind != OpdsAuthMethodKind.UNSUPPORTED
                },
                error = null,
            )

            is OpdsCatalogResult.Failed -> current.copy(isLoading = false, error = result.message)
        }
    }
}

private const val DOWNLOAD_START_TIMEOUT_MS = 15_000L

internal fun opdsBulkItem(book: Book, options: List<OpdsAcquisitionOption>): OpdsBulkItem {
    val downloadable = options.filter { it.isActionable && it.action == OpdsAcquisitionAction.OPEN }.distinctBy(OpdsAcquisitionOption::href)
    return when (downloadable.size) {
        0 -> OpdsBulkItem(
            book,
            options,
            status = OpdsBulkStatus.SKIPPED,
            message = when {
                options.any { it.isActionable && it.action in setOf(OpdsAcquisitionAction.BORROW, OpdsAcquisitionAction.BUY, OpdsAcquisitionAction.SUBSCRIBE) } ->
                    "Needs borrowing or purchase. Open the book on its own to continue."
                else -> options.firstNotNullOfOrNull(OpdsAcquisitionOption::unsupportedReason) ?: "No downloadable file"
            },
        )
        1 -> OpdsBulkItem(book, downloadable, chosenHref = downloadable.single().href)
        else -> OpdsBulkItem(book, downloadable)
    }
}

private fun List<OpdsBulkItem>.replace(item: OpdsBulkItem) = map { if (it.book.id == item.book.id) item else it }
