package com.enve.hearth.bookorbit

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.bookorbit.BookOrbitAccount
import com.enve.engine.bookorbit.BookOrbitAchievements
import com.enve.engine.bookorbit.BookOrbitFacade
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

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class BookOrbitAchievementsViewModel @Inject constructor(
    private val bookOrbit: BookOrbitFacade,
) : ViewModel() {
    val accounts: StateFlow<List<BookOrbitAccount>> =
        bookOrbit.accounts.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private val chosenAccountId = MutableStateFlow<String?>(null)
    private val reloads = MutableStateFlow(0)
    private val earnedOnly = MutableStateFlow(false)

    val activeAccountId: StateFlow<String?> = combine(accounts, chosenAccountId) { available, chosen ->
        chosen?.takeIf { id -> available.any { it.connectionId == id } } ?: available.firstOrNull()?.connectionId
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    val showEarnedOnly: StateFlow<Boolean> = earnedOnly

    val state: StateFlow<BookOrbitLoad<BookOrbitAchievements>> =
        combine(accounts, activeAccountId, reloads) { available, id, _ ->
            available.isNotEmpty() to id
        }.flatMapLatest { (hasAccounts, connectionId) ->
            flow {
                if (!hasAccounts || connectionId == null) {
                    emit(BookOrbitLoad.NoAccount)
                    return@flow
                }
                emit(BookOrbitLoad.Loading)
                emit(loadBookOrbit { bookOrbit.achievements(connectionId) })
            }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), BookOrbitLoad.Loading)

    fun selectAccount(connectionId: String) {
        chosenAccountId.value = connectionId
    }

    fun setEarnedOnly(enabled: Boolean) {
        earnedOnly.value = enabled
    }

    fun retry() {
        reloads.value += 1
    }
}
