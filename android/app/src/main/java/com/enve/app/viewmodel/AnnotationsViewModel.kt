package com.enve.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.repository.AnnotationRepository
import com.enve.app.data.repository.TagIndexStore
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

enum class HighlightFilter(val label: String) {
    ALL("All"),
    HIGHLIGHTS("Highlights"),
    UNDERLINES("Underlines"),
    SQUIGGLES("Squiggles"),
    STRIKES("Strikes"),
    NOTES("Notes"),
}

data class AnnotationBookSection(
    val bookId: String,
    val book: Book?,
    val title: String,
    val author: String?,
    val coverUrl: String?,
    val annotations: List<ReaderAnnotation>,
) {
    val latestUpdatedAt: Long = annotations.maxOfOrNull { it.updatedAt } ?: 0L
}

data class AnnotationsScreenState(
    val annotations: List<ReaderAnnotation> = emptyList(),
    val booksByBookId: Map<String, Book> = emptyMap(),
    val filter: HighlightFilter = HighlightFilter.ALL,
    val query: String = "",
    val isLoading: Boolean = true,
    val undoableDelete: ReaderAnnotation? = null,
)

@HiltViewModel
class AnnotationsViewModel @Inject constructor(
    private val repo: AnnotationRepository,
    private val bookCacheDao: BookCacheDao,
    tagIndex: TagIndexStore,
) : ViewModel() {

    private val _state = MutableStateFlow(AnnotationsScreenState())
    val state: StateFlow<AnnotationsScreenState> = _state.asStateFlow()

    val knownTags: StateFlow<List<String>> = tagIndex.tagsByUsage
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    init {
        viewModelScope.launch {
            combine(repo.all(), bookCacheDao.observeAllForList()) { annotations, books ->
                annotations to books.map { it.toBook() }.associateBy { it.id }
            }.collect { (annotations, booksById) ->
                _state.update {
                    it.copy(
                        annotations = annotations,
                        booksByBookId = booksById,
                        isLoading = false,
                    )
                }
            }
        }
    }

    fun setQuery(query: String) = _state.update { it.copy(query = query) }
    fun setFilter(filter: HighlightFilter) = _state.update { it.copy(filter = filter) }

    fun clearFilters() = _state.update {
        it.copy(
            query = "",
            filter = HighlightFilter.ALL,
        )
    }

    fun delete(annotation: ReaderAnnotation) {
        viewModelScope.launch { repo.delete(annotation.id) }
        _state.update { it.copy(undoableDelete = annotation) }
    }

    fun undoDelete() {
        val annotation = _state.value.undoableDelete ?: return
        viewModelScope.launch { repo.restore(annotation.id) }
        _state.update { it.copy(undoableDelete = null) }
    }

    fun update(
        annotation: ReaderAnnotation,
        style: AnnotationStyle,
        colorHex: String,
        note: String,
        tags: List<String>,
    ) {
        viewModelScope.launch {
            repo.update(annotation, style = style, colorHex = colorHex, note = note, tags = tags)
        }
    }

    fun visibleSections(): List<AnnotationBookSection> {
        val state = _state.value
        return state.annotations
            .asSequence()
            .filter { it.deletedAt == null }
            .filter { it.matches(state.filter) }
            .filter { it.matchesQuery(state.query, state.booksByBookId[it.bookId]) }
            .groupBy { it.bookId }
            .map { (bookId, annotations) ->
                val book = state.booksByBookId[bookId]
                AnnotationBookSection(
                    bookId = bookId,
                    book = book,
                    title = book?.title ?: bookId,
                    author = book?.author,
                    coverUrl = book?.coverUrl,
                    annotations = annotations.sortedWith(
                        compareBy<ReaderAnnotation> { it.sortProgress() == null }
                            .thenBy { it.sortProgress() ?: 0.0 }
                            .thenBy { it.createdAt },
                    ),
                )
            }
            .sortedByDescending { it.latestUpdatedAt }
    }

    fun visibleAnnotations(): List<ReaderAnnotation> =
        visibleSections().flatMap { it.annotations }

    fun tagsFor(annotation: ReaderAnnotation): List<String> = repo.tagsFromJson(annotation.tagsJson)

    private fun ReaderAnnotation.matches(filter: HighlightFilter): Boolean {
        val kind = AnnotationKind.parse(kind)
        val style = AnnotationStyle.parse(style)
        return when (filter) {
            HighlightFilter.ALL -> kind != AnnotationKind.BOOKMARK
            HighlightFilter.HIGHLIGHTS -> kind == AnnotationKind.HIGHLIGHT && style == AnnotationStyle.HIGHLIGHT
            HighlightFilter.UNDERLINES -> kind == AnnotationKind.HIGHLIGHT && style == AnnotationStyle.UNDERLINE
            HighlightFilter.SQUIGGLES -> kind == AnnotationKind.HIGHLIGHT && style == AnnotationStyle.SQUIGGLY
            HighlightFilter.STRIKES -> kind == AnnotationKind.HIGHLIGHT && style == AnnotationStyle.STRIKETHROUGH
            HighlightFilter.NOTES -> kind == AnnotationKind.NOTE
        }
    }

    private fun ReaderAnnotation.matchesQuery(query: String, book: Book?): Boolean {
        if (query.isBlank()) return true
        val normalized = query.trim().lowercase()
        return selectedText.lowercase().contains(normalized) ||
            note.lowercase().contains(normalized) ||
            tagsJson.lowercase().contains(normalized) ||
            chapterId?.lowercase()?.contains(normalized) == true ||
            book?.title?.lowercase()?.contains(normalized) == true ||
            book?.author?.lowercase()?.contains(normalized) == true
    }

    private fun ReaderAnnotation.sortProgress(): Double? =
        totalProgression ?: progression
}
