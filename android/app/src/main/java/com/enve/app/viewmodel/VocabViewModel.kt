package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.PreferencesManager
import com.enve.app.data.repository.VocabRepository
import com.enve.core.data.model.VocabEntry
import com.enve.core.data.vocab.LeitnerScheduler
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

data class VocabHubState(
    val entries: List<VocabEntry> = emptyList(),
    val total: Int = 0,
    val due: Int = 0,
    val new: Int = 0,
    val dailyNewLimit: Int = 10,
)

data class VocabSettingsState(
    val autoLog: Boolean = true,
    val dailyNewLimit: Int = 10,
    val showSentenceFirst: Boolean = false,
    val shuffleQueue: Boolean = true,
)

data class StudySessionState(
    val queue: List<VocabEntry> = emptyList(),
    val index: Int = 0,
    val revealed: Boolean = false,
    val showSentenceFirst: Boolean = false,
    val gotIt: Int = 0,
    val again: Int = 0,
    val mastered: Int = 0,
) {
    val current: VocabEntry? get() = queue.getOrNull(index)
    val finished: Boolean get() = queue.isNotEmpty() && index >= queue.size
    val isEmpty: Boolean get() = queue.isEmpty()
}

@HiltViewModel
class VocabViewModel @Inject constructor(
    private val repo: VocabRepository,
    private val prefs: PreferencesManager,
) : ViewModel() {

    val hub: StateFlow<VocabHubState> =
        combine(repo.all, prefs.vocabDailyNewLimit) { entries, limit ->
            val now = System.currentTimeMillis()
            VocabHubState(
                entries = entries,
                total = entries.size,
                due = entries.count { it.isDue(now) && !it.isNew },
                new = entries.count { it.isNew },
                dailyNewLimit = limit,
            )
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), VocabHubState())

    val settings: StateFlow<VocabSettingsState> =
        combine(
            prefs.vocabAutoLogLookups,
            prefs.vocabDailyNewLimit,
            prefs.vocabShowSentenceFirst,
            prefs.vocabShuffleQueue,
        ) { auto, limit, sentence, shuffle ->
            VocabSettingsState(auto, limit, sentence, shuffle)
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), VocabSettingsState())

    suspend fun setAutoLog(v: Boolean) = prefs.setVocabAutoLogLookups(v)
    suspend fun setDailyNewLimit(v: Int) = prefs.setVocabDailyNewLimit(v)
    suspend fun setShowSentenceFirst(v: Boolean) = prefs.setVocabShowSentenceFirst(v)
    suspend fun setShuffleQueue(v: Boolean) = prefs.setVocabShuffleQueue(v)

    private val _session = MutableStateFlow(StudySessionState())
    val session: StateFlow<StudySessionState> = _session.asStateFlow()

    fun startSession() {
        viewModelScope.launch {
            val all = repo.getAll()
            val now = System.currentTimeMillis()
            val limit = prefs.vocabDailyNewLimit.first()
            val shuffle = prefs.vocabShuffleQueue.first()
            val showSentenceFirst = prefs.vocabShowSentenceFirst.first()

            val due = all.filter { !it.isNew && it.isDue(now) }
            val new = all.filter { it.isNew }
            val orderedDue = if (shuffle) due.shuffled() else due.sortedBy { it.nextReviewAt ?: 0 }
            val orderedNew = (if (shuffle) new.shuffled() else new.sortedBy { it.lookedUpAt }).take(limit)

            _session.value = StudySessionState(
                queue = orderedDue + orderedNew,
                showSentenceFirst = showSentenceFirst,
            )
        }
    }

    fun reveal() = _session.update { it.copy(revealed = true) }

    fun grade(action: LeitnerScheduler.Action) {
        val s = _session.value
        val card = s.current ?: return
        viewModelScope.launch { repo.review(card, action) }
        _session.value = s.copy(
            index = s.index + 1,
            revealed = false,
            gotIt = s.gotIt + if (action == LeitnerScheduler.Action.GOT_IT) 1 else 0,
            again = s.again + if (action == LeitnerScheduler.Action.AGAIN) 1 else 0,
            mastered = s.mastered + if (action == LeitnerScheduler.Action.MASTERED) 1 else 0,
        )
    }

    fun delete(entry: VocabEntry) {
        viewModelScope.launch { repo.delete(entry.id) }
    }

    fun saveNote(entry: VocabEntry, note: String) {
        viewModelScope.launch {
            repo.updateNoteAndDefinition(entry.id, note.ifBlank { null }, entry.definitionSnapshot)
        }
    }

    private inline fun MutableStateFlow<StudySessionState>.update(block: (StudySessionState) -> StudySessionState) {
        value = block(value)
    }
}
