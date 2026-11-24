package com.enve.hearth.journal

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.ReadingGoalStore
import com.enve.engine.library.LibraryFacade
import com.enve.engine.prefs.PreferencesFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.time.ZoneId
import javax.inject.Inject

@HiltViewModel
class ReadingGoalViewModel @Inject constructor(
    library: LibraryFacade,
    preferences: PreferencesFacade,
    private val goals: ReadingGoalStore,
) : ViewModel() {
    val progress: StateFlow<DailyGoalProgress?> = combine(
        goals.goal,
        library.historySessions,
        preferences.readingEnabled,
        ReadingHistory.minuteTicks(),
    ) { goal, sessions, readingEnabled, nowMs ->
        if (readingEnabled) ReadingGoalPolicy.progress(goal, sessions, nowMs, ZoneId.systemDefault()) else null
    }
        .distinctUntilChanged()
        .flowOn(Dispatchers.Default)
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), null)

    fun save(minutes: Int) {
        viewModelScope.launch { goals.save(minutes) }
    }

    fun disable() {
        viewModelScope.launch { goals.disable() }
    }
}
