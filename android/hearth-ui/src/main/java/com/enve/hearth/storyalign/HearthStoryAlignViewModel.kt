package com.enve.hearth.storyalign

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.library.LibraryFacade
import com.enve.engine.storyalign.StoryAlignFacade
import com.enve.engine.storyalign.StoryAlignJobUi
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.mapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

enum class PickTarget { EBOOK, AUDIOBOOK }

@OptIn(ExperimentalCoroutinesApi::class)
@HiltViewModel
class HearthStoryAlignViewModel @Inject constructor(
    private val storyAlign: StoryAlignFacade,
    private val library: LibraryFacade,
) : ViewModel() {

    val jobs: StateFlow<List<StoryAlignJobUi>> =
        storyAlign.jobs.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    val selectedEbook = MutableStateFlow<Book?>(null)
    val selectedAudiobook = MutableStateFlow<Book?>(null)

    val picking = MutableStateFlow<PickTarget?>(null)
    val pickQuery = MutableStateFlow("")

    private data class PickInput(val target: PickTarget?, val query: String, val ebook: Book?, val all: List<Book>)

    val pickResults: StateFlow<List<Book>> =
        combine(picking, pickQuery, selectedEbook, library.allBooks) { target, q, ebook, all ->
            PickInput(target, q, ebook, all)
        }.mapLatest { input ->
            when (input.target) {
                PickTarget.EBOOK -> input.all
                    .filter { it.mediaType == AppMediaType.EBOOK || it.hasEbook }
                    .filter { input.query.isBlank() || it.matches(input.query) }
                    .sortedBy { it.title.lowercase() }
                    .take(40)
                PickTarget.AUDIOBOOK -> {
                    val ebook = input.ebook
                    if (ebook != null) {
                        library.linkCandidates(ebook, input.query).map { it.book }.take(40)
                    } else {
                        input.all
                            .filter { it.mediaType == AppMediaType.AUDIOBOOK || it.hasAudio }
                            .filter { input.query.isBlank() || it.matches(input.query) }
                            .sortedBy { it.title.lowercase() }
                            .take(40)
                    }
                }
                null -> emptyList()
            }
        }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun openPicker(target: PickTarget) {
        pickQuery.value = ""
        picking.value = target
    }

    fun closePicker() { picking.value = null }

    fun setQuery(q: String) { pickQuery.value = q }

    fun choose(book: Book) {
        when (picking.value) {
            PickTarget.EBOOK -> {
                selectedEbook.value = book

            }
            PickTarget.AUDIOBOOK -> selectedAudiobook.value = book
            null -> {}
        }
        picking.value = null
    }

    fun clearEbook() { selectedEbook.value = null }
    fun clearAudiobook() { selectedAudiobook.value = null }

    val canStart: StateFlow<Boolean> =
        combine(selectedEbook, selectedAudiobook) { e, a -> e != null && a != null }
            .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), false)

    fun startAlignment() {
        val ebook = selectedEbook.value ?: return
        val audiobook = selectedAudiobook.value ?: return
        viewModelScope.launch {
            library.linkEditions(ebook, audiobook)
            storyAlign.createJob(ebook.uniqueKey, audiobook.uniqueKey)
            selectedEbook.value = null
            selectedAudiobook.value = null
        }
    }

    fun cancel(id: String) = launch { storyAlign.cancelJob(id) }
    fun retry(id: String) = launch { storyAlign.retryJob(id) }
    fun delete(id: String) = launch { storyAlign.deleteJob(id, deleteOutput = true) }

    private inline fun launch(crossinline block: suspend () -> Unit) {
        viewModelScope.launch { block() }
    }
}

private fun Book.matches(q: String): Boolean {
    val needle = q.trim().lowercase()
    return title.lowercase().contains(needle) ||
        author.orEmpty().lowercase().contains(needle) ||
        seriesName.orEmpty().lowercase().contains(needle)
}
