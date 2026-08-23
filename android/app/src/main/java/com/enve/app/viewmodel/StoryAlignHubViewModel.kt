package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.repository.LibraryCacheRepository
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch

data class StoryAlignHubState(
    val storytellerConnections: List<ProviderConnection> = emptyList(),
    val readyReadAloudBooks: List<Book> = emptyList(),
    val linkedFormatBooks: List<Book> = emptyList(),
    val isRefreshing: Boolean = false,
    val error: String? = null,
) {
    val activeStorytellerConnections: Int
        get() = storytellerConnections.count { it.enabled }
}

@HiltViewModel
class StoryAlignHubViewModel @Inject constructor(
    private val connectionRegistry: ConnectionRegistry,
    private val libraryCacheRepository: LibraryCacheRepository,
) : ViewModel() {
    private val _state = MutableStateFlow(StoryAlignHubState())
    val state: StateFlow<StoryAlignHubState> = _state.asStateFlow()

    init {
        viewModelScope.launch {
            combine(
                connectionRegistry.connections,
                libraryCacheRepository.allBooks,
                libraryCacheRepository.isRefreshing,
                libraryCacheRepository.refreshError,
            ) { connections, books, refreshing, error ->
                StoryAlignHubState(
                    storytellerConnections = connections.filter { it.source == BookSource.STORYTELLER },
                    readyReadAloudBooks = books
                        .filter { it.source == BookSource.STORYTELLER && it.readAlongAvailable }
                        .sortedByDescending { it.lastReadTime.coerceAtLeast(it.addedOn) }
                        .take(12),
                    linkedFormatBooks = books
                        .filter { it.hasAudio && it.hasEbook }
                        .sortedBy { it.title.lowercase() }
                        .take(12),
                    isRefreshing = refreshing,
                    error = error,
                )
            }.collect { next -> _state.value = next }
        }
    }

    fun refreshLibrary() {
        libraryCacheRepository.refreshInBackground()
        _state.update { it.copy(error = null) }
    }

}
