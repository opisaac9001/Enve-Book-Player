package com.enve.hearth.podcasts

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.engine.podcasts.PodcastFeedUrl
import com.enve.engine.podcasts.PodcastRoutine
import com.enve.engine.podcasts.PodcastRoutineLimits
import com.enve.engine.podcasts.PodcastRoutinePick
import com.enve.engine.podcasts.PodcastRoutineRule
import com.enve.engine.podcasts.PodcastRoutineRun
import com.enve.engine.podcasts.PodcastSubscription
import com.enve.engine.podcasts.PodcastsFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.util.Collections
import java.util.UUID
import javax.inject.Inject

data class PodcastRoutineRunStatus(
    val runningRoutineId: String? = null,
    val lastRun: PodcastRoutineRun? = null,
    val error: String? = null,
)

data class PodcastRoutinesUiState(
    val routines: List<PodcastRoutine> = emptyList(),
    val subscriptions: List<PodcastSubscription> = emptyList(),
    val editingRoutineId: String? = null,
    val run: PodcastRoutineRunStatus = PodcastRoutineRunStatus(),
) {
    val canCreate: Boolean get() = subscriptions.isNotEmpty() && routines.size < PodcastRoutineLimits.MAX_ROUTINES
}

@HiltViewModel
class PodcastRoutinesViewModel @Inject constructor(
    private val podcasts: PodcastsFacade,
) : ViewModel() {
    private val editingRoutineId = MutableStateFlow<String?>(null)
    private val run = MutableStateFlow(PodcastRoutineRunStatus())
    private var runJob: Job? = null

    val state: StateFlow<PodcastRoutinesUiState> = combine(
        podcasts.routines,
        podcasts.subscriptions,
        editingRoutineId,
        run,
    ) { routines, subscriptions, editing, run ->
        PodcastRoutinesUiState(routines, subscriptions, editing?.takeIf { id -> routines.any { it.id == id } }, run)
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), PodcastRoutinesUiState())

    fun create() {
        val state = state.value
        val first = state.subscriptions.firstOrNull() ?: return
        val routine = podcasts.createRoutine(
            "Routine ${state.routines.size + 1}",
            listOf(PodcastRoutineRule(UUID.randomUUID().toString(), first.feedUrl, first.title)),
        ) ?: return
        editingRoutineId.value = routine.id
    }

    fun edit(id: String?) {
        editingRoutineId.value = id
    }

    fun rename(routine: PodcastRoutine, name: String) = podcasts.saveRoutine(routine.copy(name = name))

    fun move(routine: PodcastRoutine, delta: Int) = podcasts.moveRoutine(routine.id, delta)

    fun delete(routine: PodcastRoutine) {
        podcasts.deleteRoutine(routine.id)
        if (editingRoutineId.value == routine.id) editingRoutineId.value = null
    }

    fun addRule(routine: PodcastRoutine) {
        if (routine.rules.size >= PodcastRoutineLimits.MAX_RULES) return
        val used = routine.rules.mapTo(mutableSetOf()) { PodcastFeedUrl.key(it.feedUrl) }
        val subscriptions = state.value.subscriptions
        val subscription = subscriptions.firstOrNull { PodcastFeedUrl.key(it.feedUrl) !in used } ?: subscriptions.firstOrNull() ?: return
        podcasts.saveRoutine(
            routine.copy(rules = routine.rules + PodcastRoutineRule(UUID.randomUUID().toString(), subscription.feedUrl, subscription.title)),
        )
    }

    fun setShow(routine: PodcastRoutine, rule: PodcastRoutineRule, subscription: PodcastSubscription) =
        updateRule(routine, rule.copy(feedUrl = subscription.feedUrl, showTitle = subscription.title))

    fun setPick(routine: PodcastRoutine, rule: PodcastRoutineRule, pick: PodcastRoutinePick) = updateRule(routine, rule.copy(pick = pick))

    fun moveRule(routine: PodcastRoutine, rule: PodcastRoutineRule, delta: Int) {
        val source = routine.rules.indexOfFirst { it.id == rule.id }
        val target = source + delta
        if (source < 0 || target !in routine.rules.indices) return
        podcasts.saveRoutine(routine.copy(rules = routine.rules.toMutableList().apply { Collections.swap(this, source, target) }))
    }

    fun removeRule(routine: PodcastRoutine, rule: PodcastRoutineRule) =
        podcasts.saveRoutine(routine.copy(rules = routine.rules.filterNot { it.id == rule.id }))

    fun play(routine: PodcastRoutine) {
        if (routine.rules.isEmpty()) return
        runJob?.cancel()
        run.value = PodcastRoutineRunStatus(runningRoutineId = routine.id)
        runJob = viewModelScope.launch {
            run.value = try {
                PodcastRoutineRunStatus(lastRun = podcasts.runRoutine(routine))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                PodcastRoutineRunStatus(error = "Couldn't choose episodes for ${routine.name}.")
            }
        }
    }

    fun cancelRun() {
        runJob?.cancel()
        runJob = null
        run.value = PodcastRoutineRunStatus()
    }

    fun dismissResult() {
        run.value = PodcastRoutineRunStatus()
    }

    private fun updateRule(routine: PodcastRoutine, rule: PodcastRoutineRule) =
        podcasts.saveRoutine(routine.copy(rules = routine.rules.map { if (it.id == rule.id) rule else it }))
}
