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
import com.enve.engine.opds.OpdsSignInResult
import com.enve.engine.library.LibraryFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class OpdsBookSheetState(
    val book: Book,
    val options: List<OpdsAcquisitionOption> = emptyList(),
    val isLoading: Boolean = true,
)

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
) {
    val canGoBack: Boolean get() = page != null
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
