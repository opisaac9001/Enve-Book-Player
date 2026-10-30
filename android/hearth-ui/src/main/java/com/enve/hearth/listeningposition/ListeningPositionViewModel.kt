package com.enve.hearth.listeningposition

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.core.listeningposition.ListeningPositionPayloadException
import com.enve.engine.listeningposition.*
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

data class ListeningPositionUiState(
    val payload: ListeningPositionPayload? = null,
    val suggestions: List<ListeningPositionCandidate> = emptyList(),
    val search: List<ListeningPositionCandidate> = emptyList(),
    val query: String = "",
    val loading: Boolean = false,
    val searching: Boolean = false,
    val applying: Boolean = false,
    val error: String? = null,
    val result: ListeningPositionApplyResult? = null,
    val sharePayload: ListeningPositionPayload? = null,
)

@HiltViewModel
class ListeningPositionViewModel @Inject constructor(private val facade: ListeningPositionFacade) : ViewModel() {
    private val mutable = MutableStateFlow(ListeningPositionUiState())
    val state = mutable.asStateFlow()
    private var searchJob: Job? = null
    private var scanJob: Job? = null
    private var lastRejected: String? = null

    fun captureShare(book: Book) {
        mutable.value = mutable.value.copy(sharePayload = facade.share(book))
    }

    fun reset() {
        if (mutable.value.applying) return
        searchJob?.cancel()
        scanJob?.cancel()
        lastRejected = null
        mutable.value = ListeningPositionUiState()
    }

    fun scan(message: String) {
        if (mutable.value.payload != null || lastRejected == message) return
        val payload = try { ListeningPositionPayload.decode(message) } catch (error: ListeningPositionPayloadException) {
            lastRejected = message
            imageError(if (error.reason == "unsupportedVersion") "Update Enve to read this newer listening-position code." else "That isn't a valid Enve listening-position code.")
            return
        }
        mutable.value = mutable.value.copy(payload = payload, error = null, loading = true)
        scanJob = viewModelScope.launch {
            try {
                val suggestions = facade.suggestions(payload)
                currentCoroutineContext().ensureActive()
                mutable.value = mutable.value.copy(suggestions = suggestions, loading = false)
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { mutable.value = mutable.value.copy(error = "Couldn't search your library. Try searching below.", loading = false) }
        }
    }

    fun search(query: String) {
        searchJob?.cancel()
        mutable.value = mutable.value.copy(query = query, search = emptyList(), searching = query.isNotBlank())
        val payload = mutable.value.payload ?: return
        searchJob = viewModelScope.launch {
            delay(250)
            try {
                val results = facade.search(payload, query)
                currentCoroutineContext().ensureActive()
                mutable.value = mutable.value.copy(search = results, searching = false)
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { mutable.value = mutable.value.copy(error = "Couldn't search your library. Try again.", searching = false) }
        }
    }

    fun imageError(message: String = "Couldn't read that code. Use a clear screenshot under 20 MB.") { mutable.value = mutable.value.copy(error = message) }
    fun clearResult() { if (!mutable.value.applying) mutable.value = mutable.value.copy(result = null, error = null) }
    fun currentLocation(book: Book): ListeningPositionPayload? = facade.share(book)

    fun apply(candidate: ListeningPositionCandidate) {
        val payload = mutable.value.payload ?: return
        if (mutable.value.applying || mutable.value.result != null || !candidate.canApply) return
        mutable.value = mutable.value.copy(applying = true, error = null)
        viewModelScope.launch {
            try {
                val result = facade.apply(payload, candidate.book)
                mutable.value = mutable.value.copy(result = result, applying = false,
                    suggestions = mutable.value.suggestions.map { if (it.book.uniqueKey == result.book.uniqueKey) it.copy(book = result.book) else it },
                    search = mutable.value.search.map { if (it.book.uniqueKey == result.book.uniqueKey) it.copy(book = result.book) else it })
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { mutable.value = mutable.value.copy(error = "Couldn't move this copy. Its position or availability may have changed; try again.", applying = false) }
            finally { mutable.value = mutable.value.copy(applying = false) }
        }
    }
}
