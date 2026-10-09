package com.enve.wear.listening

import android.app.Application
import android.content.Intent
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import androidx.work.WorkManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

data class WatchListeningState(
    val signedIn: Boolean = false,
    val accounts: List<WatchAccountChoice> = emptyList(),
    val activeAccount: WatchAccountChoice? = null,
    val libraries: List<WatchLibraryChoice> = emptyList(),
    val books: List<WatchBook> = emptyList(),
    val library: WatchLibraryChoice? = null,
    val loading: Boolean = false,
    val error: String? = null,
    val hasMore: Boolean = false,
)

data class WatchAccountChoice(
    val key: String,
    val source: WatchSource,
    val username: String,
    val server: String,
)

class WatchListeningViewModel(application: Application) : AndroidViewModel(application) {
    private val vault = CredentialVault(application)
    private val providers = WatchProviderRegistry(vault)
    val store = WatchLibraryStore.get(application)
    val work = WorkManager.getInstance(application)
    private val mutable = MutableStateFlow(accountState())
    val state = mutable.asStateFlow()
    private var page = 0

    init {
        if (mutable.value.signedIn) WatchProgressSyncWorker.enqueue(application)
        viewModelScope.launch {
            WatchProvisioningEvents.events.collect {
                refreshAccounts()
                mutable.update { it.copy(libraries = emptyList(), books = emptyList(), library = null, hasMore = false) }
                libraries()
            }
        }
    }

    fun refreshPhoneLink() = WatchProvisioningManager(getApplication()).publishRequest()

    fun selectAccount(key: String) = request {
        withContext(Dispatchers.IO) { vault.select(key) }
        page = 0
        mutable.update { it.copy(libraries = emptyList(), books = emptyList(), library = null, hasMore = false) }
        refreshAccounts()
        loadLibraries()
    }

    fun libraries() = request { loadLibraries() }
    private suspend fun loadLibraries() {
        val account = withContext(Dispatchers.IO) { vault.read() } ?: return
        val libraries = providers.provider(account).libraries(account)
        mutable.update { it.copy(libraries = libraries) }
    }

    fun books(library: WatchLibraryChoice, more: Boolean = false) = request {
        val account = withContext(Dispatchers.IO) { vault.read() } ?: return@request
        val next = if (more) page + 1 else 0
        val result = providers.provider(account).books(account, library.id, next)
        page = next
        mutable.update { it.copy(library = library, books = if (more) (it.books + result.books).distinctBy { book -> book.key } else result.books, hasMore = result.hasMore) }
    }

    fun download(book: WatchBook) = request {
        withContext(Dispatchers.IO) {
            if (store.state.value.books.none { it.key == book.key && it.downloaded }) store.saveBook(book)
            WatchDownloadWorker.enqueue(getApplication(), book.key)
        }
    }

    fun pauseDownload(book: WatchBook) { work.cancelUniqueWork("watch-download-${book.key}") }

    fun sync(book: WatchBook) = WatchProgressSyncWorker.enqueue(getApplication(), book.key)

    fun useWatchProgress(book: WatchBook) {
        store.acceptLocalProgress(book.key)
        WatchProgressSyncWorker.enqueue(getApplication(), book.key)
    }

    fun useServerProgress(book: WatchBook) {
        if (WatchPlaybackService.state.value.book?.key == book.key) {
            mutable.update { it.copy(error = "Close this book before using the server position.") }
            return
        }
        store.acceptRemoteProgress(book.key)
    }

    fun remove(book: WatchBook) = request {
        if (WatchPlaybackService.state.value.book?.key == book.key) {
            mutable.update { it.copy(error = "Close the current book before removing its download.") }
            return@request
        }
        withContext(Dispatchers.IO) { store.removeDownload(book.key) }
    }

    fun play(book: WatchBook, speaker: Boolean) {
        getApplication<Application>().startService(Intent(getApplication(), WatchPlaybackService::class.java)
            .setAction(WatchPlaybackService.ACTION_OPEN).putExtra("key", book.key).putExtra("speaker", speaker))
    }

    fun signOut() = request {
        val account = withContext(Dispatchers.IO) { vault.read() }
        account?.let { signedIn ->
            store.state.value.books.filter { it.account == signedIn.key }.forEach { book ->
                work.cancelUniqueWork("watch-download-${book.key}")
                work.cancelUniqueWork("watch-progress-sync-${book.key}")
            }
            withContext(Dispatchers.IO) { vault.remove(signedIn.key) }
        }
        val remaining = withContext(Dispatchers.IO) { vault.read() }
        mutable.value = accountState()
        if (remaining != null) loadLibraries()
    }

    private fun refreshAccounts() {
        val snapshot = accountState()
        mutable.update { current -> current.copy(
            signedIn = snapshot.signedIn,
            accounts = snapshot.accounts,
            activeAccount = snapshot.activeAccount,
        ) }
    }

    private fun accountState(): WatchListeningState {
        val active = vault.read()
        fun WatchAccount.choice() = WatchAccountChoice(key, source, username, server)
        return WatchListeningState(
            signedIn = active != null,
            accounts = vault.all().map { it.choice() },
            activeAccount = active?.choice(),
        )
    }

    private fun request(block: suspend () -> Unit) {
        if (mutable.value.loading) return
        viewModelScope.launch {
            mutable.update { it.copy(loading = true, error = null) }
            try { block() }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) {
                mutable.update { it.copy(error = if (error is WatchRequestException) error.message else "Couldn’t connect. Check the server address and watch connection.") }
            } finally { mutable.update { it.copy(loading = false) } }
        }
    }
}
