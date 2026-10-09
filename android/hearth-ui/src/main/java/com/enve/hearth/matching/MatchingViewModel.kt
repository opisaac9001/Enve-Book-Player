package com.enve.hearth.matching

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.DuplicateBookCluster
import com.enve.engine.library.LibraryFacade
import com.enve.engine.library.LibraryLinkCandidate
import com.enve.engine.library.LibraryMetadataMatch
import com.enve.engine.matching.BatchMatchingFacade
import com.enve.engine.matching.BatchMatchPolicy
import com.enve.engine.matching.PendingMetadataMatch
import com.enve.engine.matching.DuplicateMatchingFacade
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.Job
import javax.inject.Inject

data class BatchMatchProgress(
    val processed: Int = 0,
    val total: Int = 0,
    val applied: Int = 0,
    val queued: Int = 0,
    val errors: Int = 0,
    val running: Boolean = false,
)

@HiltViewModel
class MatchingViewModel @Inject constructor(
    private val library: LibraryFacade,
    private val batch: BatchMatchingFacade,
    private val duplicates: DuplicateMatchingFacade,
) : ViewModel() {
    fun defaultQuery(book: Book): String = library.defaultMetadataMatchQuery(book)
    val books = library.allBooks.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val locallyMatchedKeys = library.locallyMatchedMetadataKeys.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptySet())
    val links = library.editionLinks.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val pending = batch.pending
    val duplicateClusters = duplicates.clusters.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())
    val groupedDuplicates = duplicates.grouped
    val threshold = batch.threshold
    private val mutableBatchProgress = MutableStateFlow(BatchMatchProgress())
    val batchProgress: StateFlow<BatchMatchProgress> = mutableBatchProgress
    private var batchJob: Job? = null

    private val mutableMatches = MutableStateFlow<List<LibraryMetadataMatch>>(emptyList())
    val matches: StateFlow<List<LibraryMetadataMatch>> = mutableMatches
    private val mutableCandidates = MutableStateFlow<List<LibraryLinkCandidate>>(emptyList())
    val candidates: StateFlow<List<LibraryLinkCandidate>> = mutableCandidates
    private val mutableBusy = MutableStateFlow(false)
    val busy: StateFlow<Boolean> = mutableBusy
    private val mutableSearched = MutableStateFlow(false)
    val searched: StateFlow<Boolean> = mutableSearched
    private val mutableMessage = MutableStateFlow<String?>(null)
    val message: StateFlow<String?> = mutableMessage
    private val mutableMatchedKeys = MutableStateFlow<Set<String>>(emptySet())
    val matchedKeys: StateFlow<Set<String>> = mutableMatchedKeys

    fun searchMetadata(book: Book, query: String) {
        viewModelScope.launch {
            mutableBusy.value = true
            mutableSearched.value = false
            mutableMatches.value = emptyList()
            try {
                mutableMatches.value = library.searchMetadataMatches(book, query)
                    .sortedByDescending(LibraryMetadataMatch::confidence)
                mutableSearched.value = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableMessage.value = e.message ?: "Match search failed"
            } finally {
                mutableBusy.value = false
            }
        }
    }

    fun applyMetadata(book: Book, match: LibraryMetadataMatch) {
        viewModelScope.launch {
            mutableBusy.value = true
            try {
                val updated = library.applyMetadataMatch(book, match)
                if (updated != null) {
                    mutableMatchedKeys.value += book.uniqueKey
                    batch.remove(book.uniqueKey)
                    mutableMatches.value = emptyList()
                    mutableMessage.value = "Metadata matched for ${book.title}"
                } else mutableMessage.value = "Could not apply this match"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableMessage.value = e.message ?: "Could not apply this match"
            } finally {
                mutableBusy.value = false
            }
        }
    }

    fun searchLinks(book: Book, query: String) {
        viewModelScope.launch {
            mutableBusy.value = true
            mutableSearched.value = false
            mutableCandidates.value = emptyList()
            try {
                mutableCandidates.value = library.linkCandidates(book, query)
                mutableSearched.value = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableMessage.value = e.message ?: "Edition search failed"
            } finally {
                mutableBusy.value = false
            }
        }
    }

    fun link(book: Book, counterpart: Book) {
        viewModelScope.launch {
            mutableBusy.value = true
            try {
                mutableMessage.value = if (library.linkEditions(book, counterpart)) "Editions linked" else "Could not link editions"
                mutableCandidates.value = emptyList()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableMessage.value = e.message ?: "Could not link editions"
            } finally {
                mutableBusy.value = false
            }
        }
    }

    fun unlink(book: Book) {
        viewModelScope.launch {
            try {
                mutableMessage.value = if (library.unlinkEditions(book)) "Editions unlinked" else "Could not unlink editions"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableMessage.value = e.message ?: "Could not unlink editions"
            }
        }
    }

    fun clearMessage() { mutableMessage.value = null }

    fun setThreshold(percent: Int) {
        viewModelScope.launch { batch.setThreshold(percent) }
    }

    fun runBatch(books: List<Book>) {
        if (batchJob?.isActive == true) return
        val eligible = books.filter { it.mediaType == AppMediaType.AUDIOBOOK &&
            it.uniqueKey !in mutableMatchedKeys.value &&
            "${it.source.name}:${it.id}" !in locallyMatchedKeys.value &&
            batch.pending.value.none { entry -> entry.bookKey == it.uniqueKey }
        }
        batchJob = viewModelScope.launch {
            var progress = BatchMatchProgress(total = eligible.size, running = true)
            mutableBatchProgress.value = progress
            for (book in eligible) {
                try {
                    val matches = library.searchMetadataMatches(book, library.defaultMetadataMatchQuery(book))
                        .sortedByDescending(LibraryMetadataMatch::confidence)
                    val best = matches.firstOrNull()
                    if (best != null) {
                        if (BatchMatchPolicy.shouldAutoApply(matches, batch.threshold.value)) {
                            if (library.applyMetadataMatch(book, best) != null) {
                                mutableMatchedKeys.value += book.uniqueKey
                                progress = progress.copy(applied = progress.applied + 1)
                            } else progress = progress.copy(errors = progress.errors + 1)
                        } else {
                            batch.queue(PendingMetadataMatch(book.uniqueKey, book.title, best.id, best.sourceName, best.confidence))
                            progress = progress.copy(queued = progress.queued + 1)
                        }
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    progress = progress.copy(errors = progress.errors + 1)
                }
                progress = progress.copy(processed = progress.processed + 1)
                mutableBatchProgress.value = progress
            }
            mutableBatchProgress.value = progress.copy(running = false)
        }
    }

    fun cancelBatch() {
        batchJob?.cancel()
        mutableBatchProgress.value = mutableBatchProgress.value.copy(running = false)
    }

    fun discardPending(bookKey: String) {
        viewModelScope.launch { batch.remove(bookKey) }
    }

    fun clearPending() {
        viewModelScope.launch { batch.clear() }
    }

    fun mergeDuplicate(cluster: DuplicateBookCluster, keepBookKey: String) {
        viewModelScope.launch {
            mutableBusy.value = true
            try {
                val removed = duplicates.merge(cluster, keepBookKey)
                mutableMessage.value = "$removed duplicate ${if (removed == 1) "copy" else "copies"} grouped"
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableMessage.value = e.message ?: "Could not merge duplicates"
            } finally {
                mutableBusy.value = false
            }
        }
    }

    fun unmergeDuplicate(keepBookKey: String) {
        viewModelScope.launch {
            val restored = duplicates.unmerge(keepBookKey)
            mutableMessage.value = "$restored ${if (restored == 1) "copy" else "copies"} separated"
        }
    }
}
