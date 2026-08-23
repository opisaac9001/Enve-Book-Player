package com.enve.hearth.bookorbit

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.engine.bookorbit.BookOrbitAccount
import com.enve.engine.bookorbit.BookOrbitFacade
import com.enve.engine.bookorbit.BookOrbitInsights
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.stateIn
import javax.inject.Inject

val BOOK_ORBIT_INSIGHT_WINDOWS = listOf(30, 90, 365)

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class BookOrbitInsightsViewModel @Inject constructor(
    private val bookOrbit: BookOrbitFacade,
) : ViewModel() {
    val accounts: StateFlow<List<BookOrbitAccount>> =
        bookOrbit.accounts.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val chosenAccountId = MutableStateFlow<String?>(null)
    private val window = MutableStateFlow(BOOK_ORBIT_INSIGHT_WINDOWS[1])
    private val reloads = MutableStateFlow(0)

    val activeAccountId: StateFlow<String?> = combine(accounts, chosenAccountId) { available, chosen ->
        chosen?.takeIf { id -> available.any { it.connectionId == id } } ?: available.firstOrNull()?.connectionId
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val days: StateFlow<Int> = window

    val state: StateFlow<BookOrbitLoad<BookOrbitInsights>> =
        combine(accounts, activeAccountId, window, reloads) { available, id, days, _ ->
            InsightRequest(available.isNotEmpty(), id, days)
        }.flatMapLatest { request ->
            flow {
                if (!request.hasAccounts || request.connectionId == null) {
                    emit(BookOrbitLoad.NoAccount)
                    return@flow
                }
                emit(BookOrbitLoad.Loading)
                emit(loadBookOrbit { bookOrbit.insights(request.connectionId, request.days) })
            }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), BookOrbitLoad.Loading)

    fun selectAccount(connectionId: String) {
        chosenAccountId.value = connectionId
    }

    fun selectWindow(days: Int) {
        window.value = days
    }

    fun retry() {
        reloads.value += 1
    }

    suspend fun openBook(bookId: Int): Book? =
        activeAccountId.value?.let { bookOrbit.openBook(it, bookId) }

    private data class InsightRequest(
        val hasAccounts: Boolean,
        val connectionId: String?,
        val days: Int,
    )
}
