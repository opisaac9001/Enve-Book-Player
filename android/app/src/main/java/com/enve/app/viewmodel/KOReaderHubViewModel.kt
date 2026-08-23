package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.sync.KOReaderBookLink
import com.enve.app.data.sync.KOReaderHubService
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import javax.inject.Inject

data class KOReaderHubState(
    val serverUrl: String = "",
    val username: String = "",
    val password: String = "",
    val autoSync: Boolean = true,
    val isConfigured: Boolean = false,
    val lastSyncTime: Long = 0L,
    val linkedCount: Int = 0,
    val busy: Boolean = false,
    val statusMessage: String? = null,
    val statusIsError: Boolean = false,

    val ebooks: List<Book> = emptyList(),
    val links: Map<String, KOReaderBookLink> = emptyMap(),
)

@HiltViewModel
class KOReaderHubViewModel @Inject constructor(
    private val service: KOReaderHubService,
    private val bookCacheDao: BookCacheDao,
    private val prefs: PreferencesManager,
) : ViewModel() {

    private val _state = MutableStateFlow(KOReaderHubState())
    val state: StateFlow<KOReaderHubState> = _state.asStateFlow()

    init {
        reload()
        viewModelScope.launch {
            val books = bookCacheDao.observeAll().first()
                .filter { it.mediaType == AppMediaType.EBOOK.name }
                .map { it.toBook() }
                .sortedBy { it.title.lowercase() }
            _state.update { it.copy(ebooks = books, links = service.links.associateBy { l -> l.bookStableId }) }
        }
        viewModelScope.launch {
            prefs.kosyncHubLastSyncTime.collect { ts ->
                _state.update { it.copy(lastSyncTime = ts) }
            }
        }
    }

    private fun reload() {
        val c = service.config
        _state.update {
            it.copy(
                serverUrl = c.serverUrl,
                username = c.username,
                autoSync = c.autoSyncEnabled,
                isConfigured = c.isConfigured,
                linkedCount = service.links.size,
                links = service.links.associateBy { l -> l.bookStableId },
            )
        }
    }

    fun setServerUrl(v: String) = _state.update { it.copy(serverUrl = v, statusMessage = null) }
    fun setUsername(v: String) = _state.update { it.copy(username = v, statusMessage = null) }
    fun setPassword(v: String) = _state.update { it.copy(password = v, statusMessage = null) }

    fun setAutoSync(enabled: Boolean) {
        viewModelScope.launch {
            val s = _state.value
            service.updateConfig(s.serverUrl, s.username, null, enabled)
            _state.update { it.copy(autoSync = enabled) }
        }
    }

    fun connect() {
        viewModelScope.launch {
            val s = _state.value
            _state.update { it.copy(busy = true, statusMessage = null) }
            service.updateConfig(
                serverUrl = s.serverUrl,
                username = s.username,
                plaintextPassword = s.password.ifEmpty { null },
                autoSync = s.autoSync,
            )
            val result = service.authorize()
            _state.update {
                it.copy(
                    busy = false,
                    password = if (result.isSuccess) "" else it.password,
                    statusIsError = result.isFailure,
                    statusMessage = if (result.isSuccess) "Connected to ${s.serverUrl}."
                    else result.exceptionOrNull()?.message ?: "Connection failed.",
                )
            }
            reload()
        }
    }

    fun register() {
        viewModelScope.launch {
            val s = _state.value
            _state.update { it.copy(busy = true, statusMessage = null) }
            val result = service.register(s.serverUrl, s.username, s.password)
            if (result.isSuccess) {
                service.updateConfig(s.serverUrl, s.username, s.password, s.autoSync)
            }
            _state.update {
                it.copy(
                    busy = false,
                    password = if (result.isSuccess) "" else it.password,
                    statusIsError = result.isFailure,
                    statusMessage = if (result.isSuccess) "Account created and connected."
                    else result.exceptionOrNull()?.message ?: "Registration failed.",
                )
            }
            reload()
        }
    }

    fun disconnect() {
        viewModelScope.launch {
            service.clearConfig()
            _state.update {
                it.copy(
                    isConfigured = false,
                    password = "",
                    statusMessage = null,
                    linkedCount = 0,
                )
            }
            reload()
        }
    }

    fun syncNow() {
        viewModelScope.launch {
            _state.update { it.copy(busy = true, statusMessage = null) }
            val applied = runCatching { service.pullAllAndMerge() }.getOrDefault(0)
            _state.update {
                it.copy(
                    busy = false,
                    statusIsError = false,
                    statusMessage = if (applied > 0) "Updated $applied book${if (applied == 1) "" else "s"}."
                    else "No new progress.",
                )
            }
        }
    }

    fun saveLink(book: Book, hash: String) {
        service.link(book, hash, isAutomatic = false)
        _state.update {
            it.copy(
                links = service.links.associateBy { l -> l.bookStableId },
                linkedCount = service.links.size,
            )
        }
    }

    fun removeLink(book: Book) {
        service.unlink(book.uniqueKey)
        _state.update {
            it.copy(
                links = service.links.associateBy { l -> l.bookStableId },
                linkedCount = service.links.size,
            )
        }
    }

    fun hasLocalFile(book: Book): Boolean = service.resolveEbookFile(book) != null

    fun computeHashFromFile(book: Book, onResult: (String?) -> Unit) {
        viewModelScope.launch {
            val file = service.resolveEbookFile(book)
            val hash = if (file != null) {
                withContext(Dispatchers.IO) { service.computePartialMd5(file) }
            } else null
            onResult(hash)
        }
    }
}
