package com.enve.hearth.detail

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.AnnotationStyle
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.ReaderAnnotation
import com.enve.engine.annotations.AnnotationsFacade
import com.enve.engine.bookorbit.BookOrbitFacade
import com.enve.engine.bookorbit.BookOrbitRelated
import com.enve.engine.library.LibraryFacade
import com.enve.engine.servertools.ServerToolsFacade
import com.enve.engine.library.LibraryDownloadState
import com.enve.engine.library.LibraryDownloadStatus
import com.enve.engine.library.LibraryLinkCandidate
import com.enve.engine.library.LibraryMetadataEdit
import com.enve.engine.library.LibraryMetadataMatch
import com.enve.engine.library.BookOrbitCollectionMembership
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HearthDetailViewModel @Inject constructor(
    private val library: LibraryFacade,
    private val annotationsFacade: AnnotationsFacade,
    private val bookOrbit: BookOrbitFacade,
    private val serverTools: ServerToolsFacade,
) : ViewModel() {
    private val _book = MutableStateFlow<Book?>(null)
    val book: StateFlow<Book?> = _book

    private val _detail = MutableStateFlow<Book?>(null)
    private val _linkedAudiobook = MutableStateFlow<Book?>(null)
    val linkedAudiobook: StateFlow<Book?> = _linkedAudiobook
    private val _linkedEbook = MutableStateFlow<Book?>(null)
    val linkedEbook: StateFlow<Book?> = _linkedEbook
    private val _inSeries = MutableStateFlow<List<Book>>(emptyList())
    val inSeries: StateFlow<List<Book>> = _inSeries
    private val _chapters = MutableStateFlow<List<Chapter>>(emptyList())
    val chapters: StateFlow<List<Chapter>> = _chapters
    private val _chaptersLoading = MutableStateFlow(false)
    val chaptersLoading: StateFlow<Boolean> = _chaptersLoading
    private val _chaptersFailed = MutableStateFlow(false)
    val chaptersFailed: StateFlow<Boolean> = _chaptersFailed
    private val _notice = MutableStateFlow<String?>(null)
    val notice: StateFlow<String?> = _notice
    private val _metadataEditSupported = MutableStateFlow(false)
    val metadataEditSupported: StateFlow<Boolean> = _metadataEditSupported
    private val _personalRatingSupported = MutableStateFlow(false)
    val personalRatingSupported: StateFlow<Boolean> = _personalRatingSupported
    private val _personalRatingUpdating = MutableStateFlow(false)
    val personalRatingUpdating: StateFlow<Boolean> = _personalRatingUpdating
    private val _metadataQuery = MutableStateFlow("")
    val metadataQuery: StateFlow<String> = _metadataQuery
    private val _metadataMatches = MutableStateFlow<List<LibraryMetadataMatch>>(emptyList())
    val metadataMatches: StateFlow<List<LibraryMetadataMatch>> = _metadataMatches
    private val _metadataSearching = MutableStateFlow(false)
    val metadataSearching: StateFlow<Boolean> = _metadataSearching
    private val _linkCandidateQuery = MutableStateFlow("")
    val linkCandidateQuery: StateFlow<String> = _linkCandidateQuery
    private val _linkCandidates = MutableStateFlow<List<LibraryLinkCandidate>>(emptyList())
    val linkCandidates: StateFlow<List<LibraryLinkCandidate>> = _linkCandidates
    private val _linkCandidatesLoading = MutableStateFlow(false)
    val linkCandidatesLoading: StateFlow<Boolean> = _linkCandidatesLoading
    private val _downloadState = MutableStateFlow(LibraryDownloadState())
    val downloadState: StateFlow<LibraryDownloadState> = _downloadState
    private val _annotations = MutableStateFlow<List<ReaderAnnotation>>(emptyList())
    val annotations: StateFlow<List<ReaderAnnotation>> = _annotations
    private val _knownTags = MutableStateFlow<List<String>>(emptyList())
    val knownTags: StateFlow<List<String>> = _knownTags
    private val _bookOrbitCollections = MutableStateFlow<List<BookOrbitCollectionMembership>>(emptyList())
    val bookOrbitCollections: StateFlow<List<BookOrbitCollectionMembership>> = _bookOrbitCollections
    private val _bookOrbitRelated = MutableStateFlow<BookOrbitRelated?>(null)
    val bookOrbitRelated: StateFlow<BookOrbitRelated?> = _bookOrbitRelated
    private val _relatedBooks = MutableStateFlow<List<Book>>(emptyList())
    val relatedBooks: StateFlow<List<Book>> = _relatedBooks

    private var loadedKey: String? = null
    private var watchJob: Job? = null
    private var downloadJob: Job? = null
    private var chaptersJob: Job? = null
    private var annotationsJob: Job? = null
    private var tagsJob: Job? = null
    private var linkCandidatesJob: Job? = null

    fun load(initial: Book) {
        if (loadedKey == initial.uniqueKey) return
        loadedKey = initial.uniqueKey
        _book.value = initial
        _linkedAudiobook.value = null
        _linkedEbook.value = null
        _linkCandidateQuery.value = ""
        _linkCandidates.value = emptyList()
        _linkCandidatesLoading.value = false
        _inSeries.value = emptyList()
        chaptersJob?.cancel()
        linkCandidatesJob?.cancel()
        _chapters.value = emptyList()
        _chaptersFailed.value = false
        _chaptersLoading.value = false
        _metadataEditSupported.value = false
        _personalRatingSupported.value = library.supportsPersonalRating(initial)
        _personalRatingUpdating.value = false
        _metadataQuery.value = ""
        _metadataMatches.value = emptyList()
        _metadataSearching.value = false
        _downloadState.value = LibraryDownloadState()
        _annotations.value = emptyList()
        _detail.value = null
        _bookOrbitCollections.value = emptyList()
        _bookOrbitRelated.value = null
        _relatedBooks.value = emptyList()

        watchJob?.cancel()
        watchJob = viewModelScope.launch {
            library.bookByKeyFlow(initial.uniqueKey).filterNotNull().collect { cached ->
                _book.value = mergeDetail(cached, _detail.value)
            }
        }

        viewModelScope.launch {
            val detail = runCatching { library.bookDetail(initial) }.getOrNull() ?: return@launch
            _detail.value = detail
            _book.value = _book.value?.let { mergeDetail(it, detail) }
        }
        refreshLinkedEditions(initial)
        downloadJob?.cancel()
        downloadJob = viewModelScope.launch {
            library.downloadState(initial.id).collect { _downloadState.value = it }
        }
        annotationsJob?.cancel()
        annotationsJob = viewModelScope.launch {
            annotationsFacade.annotationsForBook(initial.id).collect { _annotations.value = it }
        }
        if (tagsJob == null) {
            tagsJob = viewModelScope.launch {
                annotationsFacade.knownTags.collect { _knownTags.value = it }
            }
        }
        viewModelScope.launch {
            annotationsFacade.refresh(initial)
        }
        viewModelScope.launch {
            val series = initial.seriesName
            _inSeries.value = if (!series.isNullOrBlank()) {
                library.booksInSeries(series).filter { it.uniqueKey != initial.uniqueKey }
            } else emptyList()
        }
        if (initial.mediaType == AppMediaType.AUDIOBOOK || initial.hasAudio) {
            fetchChapters(initial)
        }
        viewModelScope.launch {
            _metadataEditSupported.value = library.supportsMetadataEdit(initial)
        }
        if (initial.source == BookSource.BOOKORBIT) {
            viewModelScope.launch {
                _bookOrbitCollections.value = library.bookOrbitCollectionsForBook(initial)
            }
            viewModelScope.launch {
                val related = try {
                    bookOrbit.related(initial)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    null
                }
                if (loadedKey == initial.uniqueKey) {
                    _bookOrbitRelated.value = related?.takeUnless(BookOrbitRelated::isEmpty)
                }
            }
        }
        if (initial.source == BookSource.GRIMMORY || initial.source == BookSource.SILO) {
            viewModelScope.launch {
                val related = try {
                    serverTools.relatedBooks(initial, RELATED_BOOK_LIMIT)
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    emptyList()
                }
                if (loadedKey == initial.uniqueKey) {
                    _relatedBooks.value = related
                }
            }
        }
    }

    fun openBookOrbitBook(bookId: Int, onOpened: (Book) -> Unit) {
        val connectionId = _book.value?.connectionId ?: return
        viewModelScope.launch {
            val book = try {
                bookOrbit.openBook(connectionId, bookId)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
            if (book == null) {
                _notice.value = "Couldn't open that book from BookOrbit."
            } else {
                onOpened(book)
            }
        }
    }

    fun setBookOrbitCollectionMembership(collectionKey: String, containsBook: Boolean) {
        val book = _book.value ?: return
        val membership = _bookOrbitCollections.value.firstOrNull { it.collection.key == collectionKey } ?: return
        viewModelScope.launch {
            val success = if (containsBook) {
                library.addBookToBookOrbitCollection(membership.collection, book)
            } else {
                library.removeBookFromBookOrbitCollection(membership.collection, book)
            }
            if (success) {
                _bookOrbitCollections.value = _bookOrbitCollections.value.map {
                    if (it.collection.key == collectionKey) it.copy(containsBook = containsBook) else it
                }
            } else {
                _notice.value = "Couldn't update the BookOrbit collection. An administrator account is required."
            }
        }
    }

    fun retryChapters() {
        _book.value?.let(::fetchChapters)
    }

    fun canSeparateChapter(chapter: Chapter): Boolean {
        val book = _book.value ?: return false
        return chapter in _chapters.value &&
            _chapters.value.size > 1 &&
            (book.source == BookSource.LOCAL || book.source == BookSource.SMB)
    }

    fun separateChapter(chapter: Chapter, onSeparated: () -> Unit) {
        val book = _book.value ?: return
        if (!canSeparateChapter(chapter)) return
        viewModelScope.launch {
            if (library.separateAudiobookChapter(book, chapter)) {
                onSeparated()
            } else {
                _notice.value = "Couldn't separate \"${chapter.title}\" into its own book."
            }
        }
    }

    fun fetchChaptersFromMenu() {
        val b = _book.value ?: return
        fetchChapters(b, forceEmbedded = true)
        _notice.value = "Fetching chapters for \"${b.title}\"."
    }

    private fun fetchChapters(book: Book, forceEmbedded: Boolean = false) {
        chaptersJob?.cancel()
        chaptersJob = viewModelScope.launch {
            _chaptersLoading.value = true
            val result = library.chapters(book, forceEmbedded = forceEmbedded)

            if (loadedKey != book.uniqueKey) return@launch
            _chapters.value = result.orEmpty()
            _chaptersFailed.value = result == null
            _chaptersLoading.value = false
        }
    }

    fun toggleFinished() {
        val b = _book.value ?: return
        val target = !b.isFinished
        _book.value = b.copy(isFinished = target)
        viewModelScope.launch {
            if (!library.setFinished(b, target)) {

                if (loadedKey == b.uniqueKey) {
                    _book.value = library.book(b.id) ?: b
                    _notice.value = "Couldn't update \"${b.title}\" on the server."
                }
            }
        }
    }

    fun setPersonalRating(rating: Int) {
        val current = _book.value ?: return
        if (!_personalRatingSupported.value || _personalRatingUpdating.value) return
        val normalized = rating.coerceIn(1, 5)
        val previous = current.personalRating
        _book.value = current.copy(personalRating = normalized.toFloat())
        _personalRatingUpdating.value = true
        viewModelScope.launch {
            val success = library.setPersonalRating(current, normalized)
            if (!success && loadedKey == current.uniqueKey) {
                _book.value = _book.value?.copy(personalRating = previous)
                _notice.value = "Couldn't save the rating to ${current.source.displayName}."
            } else if (success && loadedKey == current.uniqueKey) {
                _notice.value = "Rating saved to ${current.source.displayName}."
            }
            _personalRatingUpdating.value = false
        }
    }

    fun dismissNotice() {
        _notice.value = null
    }

    fun toggleDownload() {
        val b = _book.value ?: return
        val state = _downloadState.value
        if (b.isDownloaded || state.status == LibraryDownloadStatus.COMPLETED) return
        viewModelScope.launch {
            try {
                if (state.isActive) {
                    library.removeDownload(b)
                    _notice.value = "Cancelled download for \"${b.title}\"."
                } else {
                    library.download(b)
                    _notice.value = "Download started for \"${b.title}\"."
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _notice.value = "Couldn't update the download for \"${b.title}\"."
            }
        }
    }

    fun removeDownload() {
        val b = _book.value ?: return
        viewModelScope.launch {
            try {
                library.removeDownload(b)
                _notice.value = "Removed download for \"${b.title}\"."
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _notice.value = "Couldn't remove the download for \"${b.title}\"."
            }
        }
    }

    fun hide() {
        val b = _book.value ?: return
        viewModelScope.launch { library.setHidden(b.id, true) }
    }

    fun resetProgress() {
        val b = _book.value ?: return
        _book.value = b.copy(currentTime = 0, readProgress = 0f, epubProgress = 0f)
        viewModelScope.launch { library.resetProgress(b) }
    }

    fun saveMetadata(edit: LibraryMetadataEdit) {
        val b = _book.value ?: return
        if (edit.title.isBlank()) {
            _notice.value = "Title can't be empty."
            return
        }
        viewModelScope.launch {
            val updated = library.updateMetadata(b, edit)
            if (updated != null) {
                if (loadedKey == b.uniqueKey) _book.value = updated
                _notice.value = "Updated metadata for \"${updated.title}\"."
            } else {
                _notice.value = "Metadata editing isn't available for \"${b.title}\"."
            }
        }
    }

    fun metadataEditUnavailable() {
        val b = _book.value ?: return
        _notice.value = "Metadata editing isn't available for ${b.source.displayName} books."
    }

    fun startMetadataMatch() {
        val b = _book.value ?: return
        val query = library.defaultMetadataMatchQuery(b)
        _metadataQuery.value = query
        searchMetadata(query)
    }

    fun searchMetadata(query: String) {
        val b = _book.value ?: return
        _metadataQuery.value = query
        viewModelScope.launch {
            _metadataSearching.value = true
            runCatching { library.searchMetadataMatches(b, query) }
                .onSuccess { matches ->
                    _metadataMatches.value = matches
                    if (matches.isEmpty()) _notice.value = "No metadata matches found."
                }
                .onFailure {
                    _metadataMatches.value = emptyList()
                    _notice.value = "Couldn't search metadata matches."
                }
            _metadataSearching.value = false
        }
    }

    fun applyMetadataMatch(match: LibraryMetadataMatch) {
        val b = _book.value ?: return
        viewModelScope.launch {
            val updated = library.applyMetadataMatch(b, match)
            if (updated != null) {
                if (loadedKey == b.uniqueKey) _book.value = updated
                _notice.value = "Applied metadata match for \"${updated.title}\"."
            } else {
                _notice.value = "Couldn't apply that metadata match."
            }
        }
    }

    fun prepareEditionLinking() {
        val b = _book.value ?: return
        if (!supportsEditionLinking(b)) {
            _notice.value = "Linking is only available for ebooks and audiobooks."
            return
        }
        _linkCandidateQuery.value = ""
        refreshLinkedEditions(b)
        loadLinkCandidates(b, query = "")
    }

    fun updateLinkCandidateQuery(query: String) {
        val b = _book.value ?: return
        _linkCandidateQuery.value = query
        if (!supportsEditionLinking(b)) return
        loadLinkCandidates(b, query)
    }

    fun linkEditionTo(candidate: LibraryLinkCandidate) {
        val b = _book.value ?: return
        viewModelScope.launch {
            if (library.linkEditions(b, candidate.book)) {
                refreshLinkedEditions(b)
                loadLinkCandidates(b, _linkCandidateQuery.value)
                _notice.value = "Linked \"${b.title}\" with \"${candidate.book.title}\"."
            } else {
                _notice.value = "Couldn't link those editions."
            }
        }
    }

    fun unlinkEdition() {
        val b = _book.value ?: return
        viewModelScope.launch {
            if (library.unlinkEditions(b)) {
                refreshLinkedEditions(b)
                loadLinkCandidates(b, _linkCandidateQuery.value)
                _notice.value = "Removed the linked edition for \"${b.title}\"."
            } else {
                _notice.value = "Couldn't remove that edition link."
            }
        }
    }

    fun deleteFromLibrary(onDeleted: () -> Unit) {
        val b = _book.value ?: return
        viewModelScope.launch {
            if (library.deleteFromLibrary(b)) {
                _notice.value = "Deleted \"${b.title}\" from the library."
                onDeleted()
            } else {
                _notice.value = "Delete is only available for local files. Use Hide from library for server books."
            }
        }
    }

    fun tagsFor(annotation: ReaderAnnotation): List<String> =
        annotationsFacade.tagsFor(annotation)

    fun saveAnnotation(
        annotation: ReaderAnnotation,
        style: AnnotationStyle?,
        colorHex: String?,
        note: String,
        tags: List<String>,
    ) {
        val b = _book.value ?: return
        viewModelScope.launch {
            try {
                annotationsFacade.update(
                    book = b,
                    annotation = annotation,
                    style = style,
                    colorHex = colorHex,
                    note = note,
                    tags = tags,
                )
                _notice.value = "Saved annotation."
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                _notice.value = "Couldn't save that annotation."
            }
        }
    }

    fun deleteAnnotation(annotation: ReaderAnnotation) {
        val b = _book.value ?: return
        viewModelScope.launch {
            try {
                annotationsFacade.delete(b, annotation)
                _notice.value = "Deleted annotation."
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                _notice.value = "Couldn't delete that annotation."
            }
        }
    }

    private fun mergeDetail(base: Book, detail: Book?): Book {
        if (detail == null) return base
        return base.copy(
            description = base.description?.takeIf { it.isNotBlank() } ?: detail.description,
            categories = base.categories.ifEmpty { detail.categories },
            publisher = base.publisher ?: detail.publisher,
            publishedDate = base.publishedDate ?: detail.publishedDate,
            narrator = base.narrator?.takeIf { it.isNotBlank() } ?: detail.narrator,
            seriesName = base.seriesName ?: detail.seriesName,
            seriesNumber = base.seriesNumber ?: detail.seriesNumber,
            pageCount = base.pageCount ?: detail.pageCount,
            language = base.language ?: detail.language,
            personalRating = base.personalRating ?: detail.personalRating,
        )
    }

    private fun refreshLinkedEditions(book: Book) {
        viewModelScope.launch {
            val linkedAudiobook = library.linkedAudiobook(book)
            val linkedEbook = library.linkedEbook(book)
            if (loadedKey == book.uniqueKey) {
                _linkedAudiobook.value = linkedAudiobook
                _linkedEbook.value = linkedEbook
            }
        }
    }

    private fun loadLinkCandidates(book: Book, query: String) {
        linkCandidatesJob?.cancel()
        linkCandidatesJob = viewModelScope.launch {
            _linkCandidatesLoading.value = true
            try {
                val candidates = library.linkCandidates(book, query)
                if (loadedKey == book.uniqueKey) _linkCandidates.value = candidates
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                if (loadedKey == book.uniqueKey) {
                    _linkCandidates.value = emptyList()
                    _notice.value = "Couldn't load edition link candidates."
                }
            } finally {
                if (loadedKey == book.uniqueKey) _linkCandidatesLoading.value = false
            }
        }
    }

    private fun supportsEditionLinking(book: Book): Boolean =
        book.mediaType == AppMediaType.EBOOK || book.mediaType == AppMediaType.AUDIOBOOK

    private companion object {
        const val RELATED_BOOK_LIMIT = 12
    }
}
