package com.enve.hearth.journal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import java.time.YearMonth
import java.time.ZoneId
import javax.inject.Inject

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
@HiltViewModel
class ReadingRecapViewModel @Inject constructor(
    private val library: LibraryFacade,
) : ViewModel() {
    private val zone = ZoneId.systemDefault()
    private val requested = MutableStateFlow<ReadingRecapPeriod?>(null)

    val recap: StateFlow<ReadingRecap?> = combine(
        library.historySessions,
        requested,
        ReadingHistory.minuteTicks(),
    ) { sessions, period, nowMs ->
        ReadingRecapPolicy.totals(sessions, period, nowMs, zone)
    }
        .distinctUntilChanged()
        .mapLatest { totals -> ReadingRecapPolicy.resolve(totals, books(ReadingRecapPolicy.lookupKeys(totals))) }
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun previous() {
        val current = recap.value ?: return
        if (current.canGoBack) requested.value = current.period.previous()
    }

    fun next() {
        val current = recap.value ?: return
        if (current.canGoForward) requested.value = current.period.next()
    }

    fun showMonths() {
        val period = recap.value?.period as? ReadingRecapPeriod.Year ?: return
        requested.value = ReadingRecapPeriod.Month(YearMonth.of(period.year, 12))
    }

    fun showYears() {
        val period = recap.value?.period as? ReadingRecapPeriod.Month ?: return
        requested.value = ReadingRecapPeriod.Year(period.month.year)
    }

    private suspend fun books(keys: List<String>): Map<String, Book> = buildMap {
        keys.forEach { key -> library.bookByKeyFlow(key).first()?.let { put(key, it) } }
    }
}
