package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.LibraryCacheDao
import com.enve.core.data.model.BookSource
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

data class MetadataHubState(
    val totalBooks: Int = 0,
    val totalLibraries: Int = 0,
    val enabledConnections: Int = 0,
    val totalConnections: Int = 0,
    val activeSources: List<BookSource> = emptyList(),
    val pendingNarratorEnrichment: Int = 0,
    val isRefreshingCache: Boolean = false,
    val isEnrichingNarrators: Boolean = false,
    val error: String? = null,
    val message: String? = null,
)

@HiltViewModel
class MetadataHubViewModel @Inject constructor(
    private val cacheRepository: LibraryCacheRepository,
    private val bookCacheDao: BookCacheDao,
    private val libraryCacheDao: LibraryCacheDao,
    private val connectionRegistry: ConnectionRegistry,
) : ViewModel() {
    private val _state = MutableStateFlow(MetadataHubState())
    val state: StateFlow<MetadataHubState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            combine(
                cacheRepository.totalCount,
                cacheRepository.isRefreshing,
                cacheRepository.refreshError,
                cacheRepository.libraries,
                connectionRegistry.connections,
            ) { total, refreshing, refreshError, libraries, connections ->
                val enabled = connections.filter { it.enabled }
                MetadataHubState(
                    totalBooks = total,
                    totalLibraries = libraries.size,
                    enabledConnections = enabled.size,
                    totalConnections = connections.size,
                    activeSources = enabled.map { it.source }.distinct().sortedBy { it.displayName },
                    isRefreshingCache = refreshing,
                    error = refreshError,
                )
            }.collect { snapshot ->
                val pending = runCatching { bookCacheDao.countAudiobooksNeedingNarratorEnrichment() }.getOrDefault(0)
                _state.update { current ->
                    snapshot.copy(
                        pendingNarratorEnrichment = pending,
                        isEnrichingNarrators = current.isEnrichingNarrators,
                        message = current.message,
                        error = current.error ?: snapshot.error,
                    )
                }
            }
        }
        refreshSnapshot()
    }

    fun refreshSnapshot() {
        viewModelScope.launch {
            val pending = runCatching { bookCacheDao.countAudiobooksNeedingNarratorEnrichment() }.getOrDefault(0)
            val libraries = runCatching { libraryCacheDao.getAll().size }.getOrDefault(0)
            _state.update {
                it.copy(
                    totalLibraries = libraries,
                    pendingNarratorEnrichment = pending,
                )
            }
        }
    }

    fun refreshLibraryCache() {
        cacheRepository.refreshInBackground()
        _state.update { it.copy(message = "Refreshing library metadata cache") }
    }

    fun enrichNarrators() {
        if (_state.value.isEnrichingNarrators) return
        viewModelScope.launch {
            _state.update { it.copy(isEnrichingNarrators = true, message = null, error = null) }
            try {
                val processed = cacheRepository.enrichAudiobookNarratorsNow()
                val pending = bookCacheDao.countAudiobooksNeedingNarratorEnrichment()
                _state.update {
                    it.copy(
                        isEnrichingNarrators = false,
                        pendingNarratorEnrichment = pending,
                        message = if (processed == 0) {
                            "No audiobook narrator metadata needed enrichment"
                        } else {
                            "Checked narrator metadata for $processed audiobook${if (processed == 1) "" else "s"}"
                        },
                    )
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                _state.update {
                    it.copy(
                        isEnrichingNarrators = false,
                        error = error.message ?: "Narrator enrichment failed",
                    )
                }
            }
        }
    }

    fun clearTransientMessage() {
        _state.update { it.copy(error = null, message = null) }
    }
}
