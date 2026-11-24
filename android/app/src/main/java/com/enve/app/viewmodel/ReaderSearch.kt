package com.enve.app.viewmodel

import android.util.Log
import com.enve.app.data.reader.ReaderSearchPreferences
import com.enve.app.data.reader.search.EbookSearchService
import com.enve.app.ui.screens.reader.ReaderEngineNavigator
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.Search
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.services.search.SearchService
import org.readium.r2.shared.publication.services.search.search
import org.readium.r2.shared.util.getOrElse
import java.io.File

private const val TAG = "ReaderSearch"
private const val TYPING_DEBOUNCE_MS = 350L
private const val MIN_TYPED_LENGTH = 2
private const val MAX_QUERY_LENGTH = 200
private const val RESULT_PAGE_SIZE = 100
private const val SEARCHING = "Searching…"

data class ReaderSearchResult(
    val id: String,
    val locator: Locator,
    val title: String,
)

data class ReaderSearchState(
    val query: String = "",
    val results: List<ReaderSearchResult> = emptyList(),
    val loading: Boolean = false,
    val error: String? = null,
    val status: String? = null,
    val wholeWords: Boolean = true,
    val optionsAvailable: Boolean = false,
    val hasMore: Boolean = false,
)

private sealed interface SearchSource {
    class Engine(val navigator: ReaderEngineNavigator) : SearchSource
    class IndexedEpub(val publication: Publication, val epubFile: File) : SearchSource
    class Readium(val publication: Publication) : SearchSource
}

private class SearchMatches(
    val locators: List<Locator>,
    val hasMore: Boolean,
    val status: String = SEARCHING,
)

private fun cappedMatches(locators: List<Locator>, limit: Int) =
    SearchMatches(locators.take(limit), hasMore = locators.size > limit)

internal class ReaderSearch(
    private val scope: CoroutineScope,
    private val ebookSearch: EbookSearchService,
    private val preferences: ReaderSearchPreferences,
    private val publish: (ReaderSearchState) -> Unit,
) {
    private var state = ReaderSearchState()
        set(value) {
            field = value
            publish(value)
        }
    private var source: SearchSource? = null
    private var job: Job? = null
    private var typingJob: Job? = null
    private var limit = RESULT_PAGE_SIZE

    init {
        scope.launch {
            preferences.wholeWords.collect { state = state.copy(wholeWords = it) }
        }
    }

    fun attach(engine: ReaderEngineNavigator) {
        attach(SearchSource.Engine(engine))
    }

    fun attach(publication: Publication, epubFile: File?) {
        attach(if (epubFile != null) SearchSource.IndexedEpub(publication, epubFile) else SearchSource.Readium(publication))
    }

    private fun attach(source: SearchSource) {
        cancel()
        this.source = source
        state = state.copy(optionsAvailable = source is SearchSource.IndexedEpub)
    }

    fun dismiss() {
        cancel()
        clearHighlights()
    }

    fun updateQuery(query: String) {
        dismiss()
        state = state.copy(query = query.take(MAX_QUERY_LENGTH), error = null, results = emptyList(), hasMore = false)
        if (query.trim().length < MIN_TYPED_LENGTH) return
        typingJob = scope.launch {
            delay(TYPING_DEBOUNCE_MS)
            typingJob = null
            run()
        }
    }

    fun updateWholeWords(wholeWords: Boolean) {
        cancel()
        state = state.copy(wholeWords = wholeWords, results = emptyList(), hasMore = false)
        scope.launch { preferences.setWholeWords(wholeWords) }
        if (state.query.isNotBlank()) run()
    }

    fun cancel() {
        typingJob?.cancel()
        typingJob = null
        job?.cancel()
        job = null
        state = state.copy(loading = false, status = null)
    }

    fun loadMore() {
        if (state.loading || !state.hasMore) return
        limit += RESULT_PAGE_SIZE
        start(state.query, keepResults = true)
    }

    fun run(query: String = state.query) {
        limit = RESULT_PAGE_SIZE
        start(query, keepResults = false)
    }

    private fun start(query: String, keepResults: Boolean) {
        val trimmed = query.trim()
        cancel()
        if (trimmed.isEmpty() || trimmed.length > MAX_QUERY_LENGTH) {
            clearHighlights()
            state = state.copy(
                query = query,
                results = emptyList(),
                error = if (trimmed.isEmpty()) null else "Use at most $MAX_QUERY_LENGTH characters.",
                hasMore = false,
            )
            return
        }
        val matches = matches(trimmed)
        if (matches == null) {
            state = state.copy(error = "Search is not ready yet.")
            return
        }
        state = state.copy(
            query = query,
            results = if (keepResults) state.results else emptyList(),
            loading = true,
            error = null,
            status = SEARCHING,
            hasMore = false,
        )
        job = scope.launch {
            try {
                matches.collect { found ->
                    ensureActive()
                    state = state.copy(
                        results = found.locators.mapIndexed { index, locator -> locator.toSearchResult(index) },
                        hasMore = found.hasMore,
                        status = found.status,
                    )
                }
                ensureActive()
                state = state.copy(
                    loading = false,
                    status = if (state.hasMore) "Showing first ${state.results.size} matches" else null,
                    error = if (state.results.isEmpty()) "Nothing found for “$trimmed”." else null,
                )
            } catch (_: TimeoutCancellationException) {
                ensureActive()
                fail("Search timed out. Try a more specific phrase.")
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                ensureActive()
                Log.w(TAG, "EPUB search failed", error)
                fail("Search could not finish. Please try again.")
            }
        }
    }

    private fun matches(query: String): Flow<SearchMatches>? {
        val limit = limit
        return when (val source = source) {
            null -> null
            is SearchSource.Engine -> flow { emit(cappedMatches(source.navigator.search(query, limit + 1), limit)) }
            is SearchSource.IndexedEpub ->
                ebookSearch.search(source.publication, source.epubFile, query, state.wholeWords, limit).map { update ->
                    SearchMatches(
                        locators = update.results,
                        hasMore = update.hasMore,
                        status = if (update.indexing) {
                            "Preparing search index: ${update.indexedSections}/${update.totalSections} sections"
                        } else {
                            SEARCHING
                        },
                    )
                }
            is SearchSource.Readium -> readiumMatches(source.publication, query, limit)
        }
    }

    @OptIn(ExperimentalReadiumApi::class, Search::class)
    private fun readiumMatches(publication: Publication, query: String, limit: Int): Flow<SearchMatches> = flow {
        val iterator = publication.search(
            query,
            SearchService.Options(caseSensitive = false, diacriticSensitive = false),
        ) ?: error("Search is unavailable for this book.")
        try {
            val locators = mutableListOf<Locator>()
            while (locators.size <= limit) {
                val page = iterator.next().getOrElse { error ->
                    throw IllegalStateException(error.message)
                } ?: break
                locators += page.locators
                emit(cappedMatches(locators, limit))
            }
        } finally {
            iterator.close()
        }
    }.flowOn(Dispatchers.IO)

    private fun fail(message: String) {
        state = state.copy(loading = false, status = null, error = message)
    }

    private fun clearHighlights() {
        (source as? SearchSource.Engine)?.navigator?.clearSearch()
    }
}

private fun Locator.toSearchResult(index: Int): ReaderSearchResult {
    val section = title?.takeIf { it.isNotBlank() }
        ?: href.toString().substringAfterLast('/').substringBefore('#').ifBlank { "Result" }
    return ReaderSearchResult(
        id = "${href}#${locations.fragments.joinToString(",")}:$index",
        locator = this,
        title = section,
    )
}
