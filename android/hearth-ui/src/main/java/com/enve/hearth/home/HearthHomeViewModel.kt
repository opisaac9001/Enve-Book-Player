package com.enve.hearth.home

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryFacade
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.PreferencesFacade
import com.enve.hearth.observeLastOpenedBook
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HearthHomeViewModel @Inject constructor(
    private val library: LibraryFacade,
    lastOpenedBookStore: LastOpenedBookStore,
    prefs: PreferencesManager,
    preferences: PreferencesFacade,
) : ViewModel() {

    val lastSyncMillis: StateFlow<Long> =
        prefs.lastSyncTime.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), 0L)

    val continueBooks: StateFlow<List<Book>> =
        library.continueBooks.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val lastOpenedBook: StateFlow<Book?> =
        library.observeLastOpenedBook(lastOpenedBookStore)
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), null)
    val editionLinks: StateFlow<List<com.enve.engine.library.LibraryEditionLink>> =
        library.editionLinks.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val recentlyAdded: StateFlow<List<Book>> =
        library.recentlyAdded.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val allBooks: StateFlow<List<Book>> =
        library.allBooks.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val downloaded: StateFlow<List<Book>> =
        library.downloaded.map { it.take(16) }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())
    val isRefreshing: StateFlow<Boolean> = library.isRefreshing
    val homeSectionOrder: StateFlow<List<HearthHomeSection>> =
        preferences.homeSectionOrder.stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5000),
            HearthHomeSection.entries,
        )

    fun refresh() {
        viewModelScope.launch { library.refresh() }
    }
}
