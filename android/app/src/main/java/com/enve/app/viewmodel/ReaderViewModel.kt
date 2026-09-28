package com.enve.app.viewmodel

import android.graphics.Color
import com.enve.core.reader.highlightColorHex
import androidx.compose.ui.graphics.toArgb
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.readium.MediaOverlayEngine
import com.enve.app.readium.ReadAloudCheckpoint
import com.enve.app.readium.ReadAloudCheckpointRepository
import com.enve.app.readium.ReadAloudCheckpointToken
import com.enve.app.readium.ReadAloudLyricsBuilder
import com.enve.app.readium.ReadAloudPlaybackCoordinator
import com.enve.app.readium.ReadAloudPlaybackSession
import com.enve.app.readium.ReaderNarrationStore
import com.enve.app.readium.SmilClip
import com.enve.bookorbit.sync.BookOrbitHistorySessionSync
import com.enve.core.data.local.PreferencesManager
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.AnnotationMedia
import com.enve.core.data.model.AnnotationStyle
import com.enve.app.data.reader.LayoutPreset
import com.enve.app.data.reader.search.EbookSearchService
import com.enve.app.data.reader.ReaderSearchPreferences
import com.enve.core.data.model.ReaderAnnotation
import com.enve.app.data.reader.ReaderColumns
import com.enve.app.data.reader.ReaderFont
import com.enve.app.data.reader.ReaderPreferences
import com.enve.app.data.reader.ReaderTheme
import com.enve.app.data.history.HistorySessionStore
import com.enve.app.data.reader.EpubBridgeCheckpointStore
import com.enve.app.data.reader.ReaderCheckpointLease
import com.enve.app.data.reader.nextBookInSeries
import com.enve.app.data.sync.RemoteProgressWriteKey
import com.enve.app.data.sync.RemoteRewindTracker
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.core.data.provider.ProviderEbookResource
import com.enve.core.data.sync.ProgressConflictPassage
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.runSuspendCatching
import com.enve.core.di.ApplicationScope
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.EpubBridgeRestoreMatcher
import com.enve.core.reader.ReaderCheckpointIdentity
import com.enve.core.reader.ReaderEngineKind
import com.enve.app.ui.screens.reader.ReadiumPortableAnchorScript
import com.enve.app.ui.screens.reader.ReaderEngineLocation
import com.enve.app.ui.screens.reader.ReaderEngineNavigator
import com.enve.app.ui.screens.reader.ReaderEngineTocItem
import com.enve.app.data.repository.AnnotationRepository
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.data.repository.LocatorAnchors
import com.enve.app.data.repository.SyncManager
import com.enve.hearth.design.parseHexColor
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.readium.r2.navigator.DecorableNavigator
import org.readium.r2.navigator.Decoration
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.shared.ExperimentalReadiumApi
import org.readium.r2.shared.Search
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.publication.epub.pageList
import org.readium.r2.shared.publication.services.positionsByReadingOrder
import org.readium.r2.shared.publication.services.search.SearchService
import org.readium.r2.shared.publication.services.search.search
import org.readium.r2.shared.util.getOrElse
import android.util.Log
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.mediatype.MediaType
import java.util.UUID
import javax.inject.Inject
import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlin.math.roundToInt

data class TocEntry(val id: String, val title: String, val href: String, val depth: Int)

private data class ReadAlongFragmentSplit(
    val visibleRatio: Double,
    val offScreenRatio: Double,
)

private data class ReadiumCheckpointCapture(
    val locator: Locator,
    val checkpoint: EpubBridgeCheckpoint,
)

private data class EpubPageMarker(
    val label: String,
    val progression: Double,
)

data class TtsWordHighlight(
    val word: String,
    val locator: Locator,
    val colorHex: String = "#0A84FF",
)

private data class ViewportAnchor(val locator: Locator, val page: String?)

data class ReaderSearchResult(
    val id: String,
    val locator: Locator,
    val title: String,
    val contextBefore: String,
    val matchText: String,
    val contextAfter: String,
    val progressPct: Int,
)

private fun Locator.toSearchResult(index: Int): ReaderSearchResult {
    val section = title?.takeIf { it.isNotBlank() }
        ?: href.toString().substringAfterLast('/').substringBefore('#').ifBlank { "Result" }
    val before = text.before.orEmpty().compactWhitespace().takeLast(90)
    val hit = text.highlight.orEmpty().compactWhitespace()
    val after = text.after.orEmpty().compactWhitespace().take(120)
    val progress = ((locations.totalProgression ?: locations.progression ?: 0.0) * 100.0)
        .roundToInt()
        .coerceIn(0, 100)
    return ReaderSearchResult(
        id = "${href}#${locations.fragments.joinToString(",")}:$index",
        locator = this,
        title = section,
        contextBefore = before,
        matchText = hit,
        contextAfter = after,
        progressPct = progress,
    )
}

private fun String.compactWhitespace(): String =
    replace(Regex("\\s+"), " ").trim()

private fun Locator.toJSONOrNull(): String? =
    try { toJSON().toString() } catch (_: Exception) { null }

internal fun annotationRenderColorHex(
    storedColorHex: String,
    einkActive: Boolean,
    theme: ReaderTheme,
): String {
    if (!einkActive) return highlightColorHex(storedColorHex) ?: storedColorHex
    return when (theme) {
        ReaderTheme.LIGHT, ReaderTheme.SEPIA -> "#000000"
        ReaderTheme.DARK, ReaderTheme.OLED -> "#FFFFFF"
    }
}

data class ReaderUiState(
    val prefs:       ReaderPreferences = ReaderPreferences(),
    val showChrome:  Boolean           = true,
    val annotations: List<ReaderAnnotation> = emptyList(),
    val tocEntries:  List<TocEntry>    = emptyList(),
    val bookmarks:   List<ReaderAnnotation> = emptyList(),
    val layoutPresets: List<LayoutPreset> = emptyList(),
    val totalPages:  Int               = 0,
    val currentPage: Int               = 0,
    val hasPageList: Boolean           = false,
    val currentPageLabel: String?      = null,
    val lastPageLabel: String?         = null,
    val currentSection: String         = "",
    val currentTocEntryId: String?     = null,
    val progressPct: Int               = 0,
    val showAppearanceSheet: Boolean   = false,
    val showTocSheet:        Boolean   = false,
    val showSearchSheet:     Boolean   = false,
    val searchQuery:         String    = "",
    val searchResults:       List<ReaderSearchResult> = emptyList(),
    val searchLoading:       Boolean   = false,
    val searchError:         String?   = null,
    val searchStatus:        String?   = null,
    val searchWholeWords:    Boolean   = true,
    val searchOptionsAvailable: Boolean = false,
    val searchHasMore:       Boolean   = false,
    val showMoreMenu:        Boolean   = false,
    val showAnnotationDialog: Boolean  = false,
    val readAlongSupported:  Boolean   = false,
    val readAlongActive:     Boolean   = false,
    val readAlongPlaying:    Boolean   = false,
    val readAlongClipIndex:  Int       = 0,
    val readAlongClipCount:  Int       = 0,
    val showReadAloudSheet:  Boolean   = false,
    val showReadAloudLyrics: Boolean   = false,
    val readAlongChapterClips: List<ReadAloudClipRow> = emptyList(),
    val pendingSelection:    Locator?  = null,
    val selectionText:       String    = "",
    val isReady:            Boolean           = false,

    val showSelectionPopup: Boolean   = false,
    val showAutoScrollPanel: Boolean  = false,
    val showToolbarCustomizer: Boolean = false,
    val autoScrollActive:   Boolean   = false,
    val ttsWordHighlight:   TtsWordHighlight? = null,
    val ttsSpeaking:        Boolean   = false,
    val sliderDragging:     Boolean   = false,
    val sliderPreviewPage:  Int       = 0,
    val sliderPreviewPageLabel: String? = null,
    val activeDecorationAnnotation: ReaderAnnotation? = null,
    val undoableDelete:    ReaderAnnotation? = null,
    val showAnnotationsSheet: Boolean = false,
    val nextInSeries: Book? = null,
    val pendingProgressConflict: ProgressConflictPrompt? = null,

    val transientMessage: String? = null,

    val readAlongPreparing: Boolean = false,
)

data class ReadAloudClipRow(
    val index: Int,
    val startMs: Long,
    val skippable: Boolean,
    val textHref: String,
    val fragmentId: String?,
    val resourceProgression: Double?,
    val text: String = "",
)

data class CachedReaderProgress(
    val progress: Float,
    val locator: String?,
    val currentTimeSec: Long,
)

data class FoliateOpenPlan(
    val resource: ProviderEbookResource,
    val lease: ReaderCheckpointLease,
    val initialCheckpoint: EpubBridgeCheckpoint?,
    val identity: EpubBridgeCheckpoint,
)

enum class OpenProgressAuthority { AUTOMATIC, LOCAL, REMOTE }

data class OpenRemoteProgress(
    val snapshot: SyncSnapshot?,
    val authority: OpenProgressAuthority,
)

internal fun selectOpenCheckpoint(
    authority: OpenProgressAuthority,
    local: CheckpointCandidate?,
    remote: CheckpointCandidate?,
    launcher: CheckpointCandidate?,
): EpubBridgeCheckpoint? {
    if (authority == OpenProgressAuthority.REMOTE && remote != null) return remote.checkpoint
    return selectCheckpointCandidate(
        listOfNotNull(
            local,
            remote.takeIf { authority != OpenProgressAuthority.LOCAL },
            launcher,
        ),
    )
}

data class ProgressConflictPrompt(
    val localPercentage: Float,
    val localUpdatedAt: Long?,
    val remotePercentage: Float,
    val remoteUpdatedAt: Long?,
    val remoteSource: String,
    val localPassage: ProgressConflictPassage? = null,
    val remotePassage: ProgressConflictPassage? = null,
)

enum class ProgressConflictChoice { LOCAL, REMOTE, LATER }

internal suspend fun sourceOwnedEbookDownloadUrl(
    source: BookSource,
    providerUrl: String?,
    legacyGrimmoryUrl: suspend () -> String,
): String {
    if (providerUrl != null) return providerUrl
    if (source != BookSource.GRIMMORY) {
        error("${source.displayName} did not provide a download URL for this book.")
    }
    return legacyGrimmoryUrl()
}

@HiltViewModel
class ReaderViewModel @Inject constructor(
    @ApplicationContext private val appContext: Context,
    private val prefs: PreferencesManager,
    private val repository: GrimmoryRepository,
    private val bookOrbitHistorySync: BookOrbitHistorySessionSync,
    private val aggregatorRepository: com.enve.app.data.repository.AggregatorRepository,
    private val syncManager: SyncManager,
    private val einkManager: com.enve.app.eink.EinkManager,
    private val annotationRepo: AnnotationRepository,
    private val koreaderHub: com.enve.app.data.sync.KOReaderHubService,
    private val rewindTracker: RemoteRewindTracker,
    private val vocabRepo: com.enve.app.data.repository.VocabRepository,
    private val tagIndex: com.enve.app.data.repository.TagIndexStore,
    private val customFontRepository: com.enve.app.data.repository.CustomFontRepository,
    private val definitionLookup: com.enve.app.data.vocab.DefinitionLookupService,
    private val audioPlaybackManager: com.enve.app.playback.AudioPlaybackManager,
    private val readAloudPlayback: ReadAloudPlaybackCoordinator,
    private val readAloudCheckpoints: ReadAloudCheckpointRepository,
    private val narrationStore: ReaderNarrationStore,
    private val epubBridgeCheckpoints: EpubBridgeCheckpointStore,
    private val history: HistorySessionStore,
    private val ebookSearch: EbookSearchService,
    private val searchPreferences: ReaderSearchPreferences,
    @ApplicationScope private val applicationScope: CoroutineScope,
) : ViewModel() {

    private val einkBoldActive: Boolean
        get() = einkManager.einkActive && einkManager.boldText.value

    private val einkSingleColumnActive: Boolean
        get() = einkManager.einkActive
    companion object {
        private const val TAG = "ReaderViewModel"
        private const val READ_ALONG_DECORATION_GROUP = "readAlong"
        private const val READ_ALONG_DECORATION_ID = "readAlong-active"
        private const val MAX_SEARCH_RESULTS = 100
        private const val PROGRESS_PUSH_DEBOUNCE_MS = 5_000L
        private const val PROGRESS_PUSH_MAX_WAIT_MS = 15_000L
        private const val RESTORED_SENTENCE_WINDOW_MS = 120_000L
        private const val VIEWPORT_SETTLE_MS = 350L
    }

    private val _state = MutableStateFlow(ReaderUiState())
    val state: StateFlow<ReaderUiState> = _state.asStateFlow()

    val knownTags: StateFlow<List<String>> = tagIndex.tagsByUsage
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val customFonts: StateFlow<List<com.enve.app.data.reader.CustomFont>> = customFontRepository.observeFonts()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    private var db: ReaderDatabase? = null
    private var navigator: EpubNavigatorFragment? = null
    private var engineNavigator: ReaderEngineNavigator? = null
    private var epubCheckpointLease: ReaderCheckpointLease? = null
    private var latestEpubCheckpoint: EpubBridgeCheckpoint? = null
    private var foliateExpectedCheckpoint: EpubBridgeCheckpoint? = null
    private var foliateRestoreConfirmed = false
    private val foliateCheckpointSync = FoliateCheckpointSync()
    private var readiumRestoreConfirmed = false
    private var readiumCheckpointDirty = false
    private var readiumCheckpointFingerprint: String? = null
    private var readiumUserInteractionPending = false
    private val unleasedReadiumPosition = ReaderPositionBaseline()
    private var readiumRestoreJob: Job? = null
    private var viewportAnchor: ViewportAnchor? = null
    private var viewportReanchorJob: Job? = null
    private var publication: Publication? = null
    private var bookId: String = ""
    private var bookTitle: String = ""
    private var bookAuthor: String? = null
    private var bookSource: com.enve.core.data.model.BookSource = com.enve.core.data.model.BookSource.GRIMMORY
    private var bookConnectionId: String? = null
    private var syncJob: Job? = null
    private var savePrefsJob: Job? = null
    private var preferencesLoaded = false
    private var mediaOverlayEngine: MediaOverlayEngine? = null
    private var readAloudCheckpointToken: ReadAloudCheckpointToken? = null
    private var readAloudCheckpointRevision: Long = 0L
    private var latestReadAloudLocator: Locator? = null
    private var readAlongClipUiJob: Job? = null
    private var readAlongPageFlipJob: Job? = null
    private var readAloudTimelinePrepared: Boolean = false
    private var restoredReadAloudFragment: String? = null
    private var restoredReadAloudFragmentAtMs: Long = 0L

    private var positions: List<Locator> = emptyList()
    private var pageMarkers: List<EpubPageMarker> = emptyList()

    private var lastLocator: Locator? = null

    private var _chromeInteraction = MutableStateFlow(0L)
    val chromeInteraction = _chromeInteraction.asStateFlow()

    private var autoScrollJob: Job? = null

    private var einkBoldObserverJob: Job? = null

    private var ttsEngine: android.speech.tts.TextToSpeech? = null
    private var ttsUtteranceId: String = "enve_tts"
    private var audioIsNavigating: Boolean = false
    private var readAlongSyncJob: Job? = null
    private var readAlongStartJob: Job? = null
    private var searchJob: Job? = null
    private var searchEpubFile: java.io.File? = null
    private var searchLimit = MAX_SEARCH_RESULTS

    fun postTransientMessage(message: String) {
        _state.update { it.copy(transientMessage = message) }
    }
    fun consumeTransientMessage() {
        _state.update { it.copy(transientMessage = null) }
    }

    fun showSearch(show: Boolean) {
        if (!show) {
            cancelSearch()
            engineNavigator?.clearSearch()
            _state.update { it.copy(showSearchSheet = false, searchLoading = false) }
        } else {
            _state.update { it.copy(showSearchSheet = true, showMoreMenu = false) }
        }
    }

    fun updateSearchQuery(query: String) {
        cancelSearch()
        engineNavigator?.clearSearch()
        _state.update {
            it.copy(searchQuery = query.take(200), searchError = null, searchResults = emptyList(), searchHasMore = false)
        }
    }

    fun updateSearchWholeWords(wholeWords: Boolean) {
        cancelSearch()
        _state.update { it.copy(searchWholeWords = wholeWords, searchResults = emptyList(), searchHasMore = false) }
        viewModelScope.launch { searchPreferences.setWholeWords(wholeWords) }
        if (state.value.searchQuery.isNotBlank()) runSearch()
    }

    fun cancelSearch() {
        searchJob?.cancel()
        searchJob = null
        _state.update { it.copy(searchLoading = false, searchStatus = null) }
    }

    fun loadMoreSearchResults() {
        if (state.value.searchLoading || !state.value.searchHasMore) return
        searchLimit += MAX_SEARCH_RESULTS
        startSearch(state.value.searchQuery, keepResults = true)
    }

    fun runSearch(query: String = state.value.searchQuery) {
        searchLimit = MAX_SEARCH_RESULTS
        startSearch(query, keepResults = false)
    }

    @OptIn(ExperimentalReadiumApi::class, Search::class)
    private fun startSearch(query: String, keepResults: Boolean) {
        val trimmed = query.trim()
        cancelSearch()
        if (trimmed.isEmpty() || trimmed.length > 200) {
            engineNavigator?.clearSearch()
            _state.update {
                it.copy(
                    searchQuery = query,
                    searchResults = emptyList(),
                    searchLoading = false,
                    searchError = if (trimmed.isBlank()) null else "Use at most 200 characters.",
                    searchHasMore = false,
                )
            }
            return
        }
        val alternateEngine = engineNavigator
        val pub = publication
        val epubFile = searchEpubFile
        val wholeWords = state.value.searchWholeWords
        val limit = searchLimit
        if (alternateEngine == null && pub == null) {
            _state.update { it.copy(searchLoading = false, searchError = "Search is not ready yet.") }
            return
        }
        _state.update {
            it.copy(
                searchQuery = query,
                searchResults = if (keepResults) it.searchResults else emptyList(),
                searchLoading = true,
                searchError = null,
                searchStatus = "Searching…",
                searchHasMore = false,
            )
        }
        searchJob = viewModelScope.launch {
            try {
                if (alternateEngine != null) {
                    val locators = alternateEngine.search(trimmed, limit + 1)
                    ensureActive()
                    _state.update {
                        it.copy(
                            searchResults = locators.take(limit).mapIndexed { index, locator -> locator.toSearchResult(index) },
                            searchHasMore = locators.size > limit,
                        )
                    }
                } else if (epubFile != null) {
                    ebookSearch.search(pub!!, epubFile, trimmed, wholeWords, limit).collect { update ->
                        ensureActive()
                        _state.update {
                            it.copy(
                                searchResults = update.results.mapIndexed { index, locator -> locator.toSearchResult(index) },
                                searchHasMore = update.hasMore,
                                searchStatus = if (update.indexing) {
                                    "Preparing search index: ${update.indexedSections}/${update.totalSections} sections"
                                } else "Searching…",
                            )
                        }
                    }
                } else {
                    withContext(Dispatchers.IO) {
                        val iterator = pub!!.search(
                            trimmed,
                            SearchService.Options(caseSensitive = false, diacriticSensitive = false),
                        ) ?: error("Search is unavailable for this book.")
                        try {
                            val collected = mutableListOf<ReaderSearchResult>()
                            while (collected.size <= limit) {
                                ensureActive()
                                val page = iterator.next().getOrElse { error ->
                                    throw IllegalStateException(error.message)
                                } ?: break
                                ensureActive()
                                for (locator in page.locators) {
                                    collected += locator.toSearchResult(collected.size)
                                    if (collected.size > limit) break
                                }
                                _state.update {
                                    it.copy(searchResults = collected.take(limit), searchHasMore = collected.size > limit)
                                }
                            }
                        } finally {
                            iterator.close()
                        }
                    }
                }
                ensureActive()
                _state.update {
                    it.copy(
                        searchLoading = false,
                        searchStatus = if (it.searchHasMore) "Showing first ${it.searchResults.size} matches" else null,
                        searchError = if (it.searchResults.isEmpty()) "Nothing found for “$trimmed”." else null,
                    )
                }
            } catch (_: TimeoutCancellationException) {
                ensureActive()
                _state.update {
                    it.copy(searchLoading = false, searchStatus = null, searchError = "Search timed out. Try a more specific phrase.")
                }
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                ensureActive()
                Log.w(TAG, "EPUB search failed", error)
                _state.update {
                    it.copy(
                        searchLoading = false,
                        searchStatus = null,
                        searchError = "Search could not finish. Please try again.",
                    )
                }
            }
        }
    }

    fun seekToSearchResult(result: ReaderSearchResult) {
        cancelSearch()
        _state.update { it.copy(showSearchSheet = false, showChrome = false) }
        viewModelScope.launch {
            delay(1_000)
            engineNavigator?.goToLocator(result.locator) ?: navigator?.let { nav ->
                readiumUserInteractionPending = true
                val sameResource = EpubBridgeRestoreMatcher.hrefMatches(
                    expected = result.locator.href.toString(),
                    actual = nav.currentLocator.value.href.toString(),
                )
                if (sameResource || nav.go(result.locator, animated = false)) {
                    val restored = kotlinx.coroutines.withTimeoutOrNull(10_000L) {
                        nav.currentLocator.first { locator ->
                            EpubBridgeRestoreMatcher.hrefMatches(
                                expected = result.locator.href.toString(),
                                actual = locator.href.toString(),
                            )
                        }
                        val response = nav.evaluateJavascript(
                            ReadiumPortableAnchorScript.restore(
                                result.locator.toJSON().toString(),
                                searchResult = true,
                            ),
                        )
                        response?.toBooleanStrictOrNull()
                            ?: decodeJavaScriptStringResult(response)?.toBooleanStrictOrNull()
                            ?: false
                    }
                    if (restored != true && !nav.go(result.locator, animated = false)) {
                        readiumUserInteractionPending = false
                    }
                } else {
                    readiumUserInteractionPending = false
                }
            }
            engineNavigator?.clearSearch()
        }
    }

    fun init(
        bookId: String,
        source: com.enve.core.data.model.BookSource = com.enve.core.data.model.BookSource.GRIMMORY,
        connectionId: String? = null,
        title: String = "",
        author: String? = null,
    ) {
        bookTitle = title
        bookAuthor = author
        if (this.bookId == bookId) return
        this.bookId = bookId
        this.bookSource = source
        this.bookConnectionId = connectionId
        db = ReaderDatabase.getInstance(appContext)
        viewModelScope.launch {
            searchPreferences.wholeWords.collect { wholeWords ->
                _state.update { it.copy(searchWholeWords = wholeWords) }
            }
        }
        startReadingSession()
        val startedAt = sessionStartedAtMs
        viewModelScope.launch {
            val initialProgress = cachedReaderProgress()?.progress ?: currentReadingProgress().toFloat()
            if (sessionStartedAtMs == startedAt) {
                sessionStartProgress = initialProgress
            }
            loadPreferences()
            loadAnnotations()
            loadLayoutPresets()
            resolveNextInSeries()
            _state.update { it.copy(isReady = true) }
        }
    }

    private suspend fun resolveNextInSeries() {
        val next = db?.bookCacheDao()?.nextBookInSeries(bookId, bookConnectionId)
        _state.update { it.copy(nextInSeries = next) }
    }

    suspend fun getEbookDownloadUrl(readaloud: Boolean = false): String {
        val providerUrl = if (readaloud) {
            aggregatorRepository.getReadaloudDownloadUrl(bookId, bookSource, bookConnectionId)
        } else {
            aggregatorRepository.getEbookDownloadUrl(bookId, bookSource, bookConnectionId)
        }
        return sourceOwnedEbookDownloadUrl(bookSource, providerUrl) {
            repository.getEbookDownloadUrl(bookId)
        }
    }

    suspend fun getEbookResource(): ProviderEbookResource? =
        aggregatorRepository.getEbookResource(bookId, bookSource, bookConnectionId)
            ?: if (bookSource == BookSource.GRIMMORY) {
                runCatching { repository.getEbookResource(bookId) }.getOrNull()
            } else {
                null
            }

    suspend fun prepareEpubEngineOpen(
        engine: ReaderEngineKind,
        resource: ProviderEbookResource,
        publicationSha256: String,
        launcherLocator: String?,
        launcherProgress: Float,
        launcherUpdatedAt: Long,
        remote: OpenRemoteProgress,
    ): FoliateOpenPlan {
        val bookKey = ReaderCheckpointIdentity.key(
            source = bookSource,
            connectionId = bookConnectionId,
            bookId = bookId,
            providerFileId = resource.providerFileId,
            publicationSha256 = publicationSha256,
        )
        val lease = epubBridgeCheckpoints.beginSession(
            bookKey = bookKey,
            publicationSha256 = publicationSha256,
            providerFileId = resource.providerFileId,
            engine = engine,
        )
        val now = System.currentTimeMillis()
        val remoteCandidate = remote.snapshot?.let { snapshot ->
            checkpointFromProviderSnapshot(
                locator = snapshot.locatorJson,
                epubCfi = snapshot.epubCfi,
                href = snapshot.href,
                progression = snapshot.percentage,
                publicationSha256 = publicationSha256,
                providerFileId = resource.providerFileId,
                writerEpoch = lease.writerEpoch,
                observedAt = snapshot.updatedAt ?: 0L,
                engine = engine,
            )?.let { CheckpointCandidate(it, snapshot.updatedAt ?: 0L) }
        }
        val launcherCandidate = checkpointFromProviderSnapshot(
            locator = launcherLocator,
            epubCfi = null,
            href = EpubBridgeCheckpointCodec.href(launcherLocator),
            progression = launcherProgress,
            publicationSha256 = publicationSha256,
            providerFileId = resource.providerFileId,
            writerEpoch = lease.writerEpoch,
            observedAt = launcherUpdatedAt.takeIf { it > 0L } ?: 0L,
            engine = engine,
        )?.let { CheckpointCandidate(it, it.observedAt) }
        val selected = selectOpenCheckpoint(
            authority = remote.authority,
            local = lease.checkpoint?.let { CheckpointCandidate(it, it.observedAt, local = true) },
            remote = remoteCandidate,
            launcher = launcherCandidate,
        )?.copy(
            publicationSha256 = publicationSha256,
            providerFileId = resource.providerFileId,
            revision = lease.checkpoint?.revision ?: 0L,
            writerEpoch = lease.writerEpoch,
        )
        val identity = EpubBridgeCheckpoint(
            publicationSha256 = publicationSha256,
            providerFileId = resource.providerFileId,
            revision = lease.checkpoint?.revision ?: 0L,
            writerEpoch = lease.writerEpoch,
            observedAt = selected?.observedAt ?: now,
            sourceEngine = engine,
        )
        epubCheckpointLease = lease
        latestEpubCheckpoint = selected
        restoredReadAloudFragment = selected?.let(::narratedFragmentId)
        restoredReadAloudFragmentAtMs = android.os.SystemClock.elapsedRealtime()
        foliateRestoreConfirmed = false
        foliateCheckpointSync.reset()
        readiumRestoreConfirmed = false
        readiumCheckpointDirty = false
        readiumCheckpointFingerprint = null
        readiumUserInteractionPending = false
        readiumRestoreJob?.cancel()
        readiumRestoreJob = null
        return FoliateOpenPlan(
            resource = resource,
            lease = lease,
            initialCheckpoint = selected,
            identity = identity,
        )
    }

    private fun checkpointFromProviderSnapshot(
        locator: String?,
        epubCfi: String?,
        href: String?,
        progression: Float,
        publicationSha256: String,
        providerFileId: String?,
        writerEpoch: Long,
        observedAt: Long,
        engine: ReaderEngineKind,
    ): EpubBridgeCheckpoint? {
        EpubBridgeCheckpointCodec.decode(locator)?.let {
            val rebound = it.forPublication(publicationSha256, providerFileId).copy(
                writerEpoch = writerEpoch,
                observedAt = observedAt,
            )
            return rebound.takeIf { checkpoint ->
                checkpoint.hasPreciseAnchor ||
                    !checkpoint.href.isNullOrBlank() ||
                    checkpoint.resourceProgression != null ||
                    checkpoint.totalProgression != null
            }
        }
        val exactCfi = epubCfi
            ?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi)
        val exactHref = href?.takeIf { it.isNotBlank() } ?: EpubBridgeCheckpointCodec.href(locator)
        if (exactCfi != null) {
            return EpubBridgeCheckpoint(
                publicationSha256 = publicationSha256,
                providerFileId = providerFileId,
                writerEpoch = writerEpoch,
                observedAt = observedAt,
                sourceEngine = ReaderEngineKind.FOLIATE,
                href = exactHref,
                epubCfi = exactCfi,
                totalProgression = progression.toDouble().coerceIn(0.0, 1.0),
            )
        }
        locator
            ?.takeIf { it.trimStart().startsWith("{") }
            ?.let {
                EpubBridgeCheckpointCodec.fromReadiumLocator(
                    locatorJson = it,
                    publicationSha256 = publicationSha256,
                    providerFileId = providerFileId,
                    writerEpoch = writerEpoch,
                    revision = 0L,
                    observedAt = observedAt,
                )
            }
            ?.let { return it }
        if (exactHref == null && progression <= 0f) return null
        return EpubBridgeCheckpoint(
            publicationSha256 = publicationSha256,
            providerFileId = providerFileId,
            writerEpoch = writerEpoch,
            observedAt = observedAt,
            sourceEngine = engine,
            href = exactHref,
            totalProgression = progression.toDouble().coerceIn(0.0, 1.0),
        )
    }

    private suspend fun loadPreferences() {
        val theme = when (prefs.readerTheme.first()) {
            "LIGHT" -> ReaderTheme.LIGHT
            "SEPIA" -> ReaderTheme.SEPIA
            "OLED"  -> ReaderTheme.OLED
            else    -> ReaderTheme.DARK
        }
        val wordSpacing = prefs.readerWordSpacing.first()
        val letterSpacing = prefs.readerLetterSpacing.first()
        val paragraphSpacing = prefs.readerParagraphSpacing.first()
        val paragraphIndent = prefs.readerParagraphIndent.first()
        val publisherStyles = prefs.readerPublisherStyles.first()

        val font = when (prefs.readerFontFamily.first()) {
            "SANS"     -> ReaderFont.SANS
            "DYSLEXIC" -> ReaderFont.DYSLEXIC
            "MONO"     -> ReaderFont.MONO
            "LITERATA" -> ReaderFont.LITERATA
            "ATKINSON" -> ReaderFont.ATKINSON
            "LEXEND"   -> ReaderFont.LEXEND
            "IA_WRITER" -> ReaderFont.IA_WRITER
            else       -> ReaderFont.SERIF
        }
        val customFontName = prefs.readerCustomFontName.first().takeIf { it.isNotBlank() }
        val cols = when (prefs.readerColumnCount.first()) {
            "ONE" -> ReaderColumns.ONE
            "TWO" -> ReaderColumns.TWO
            else  -> ReaderColumns.AUTO
        }
        val toolbarBtnStr = prefs.readerToolbarButtons.first()
        val toolbarButtons = if (toolbarBtnStr.isNotBlank()) {
            toolbarBtnStr.split(",").mapNotNull { name ->
                try { com.enve.app.data.reader.ReaderToolbarButton.valueOf(name) } catch (_: Exception) { null }
            }.toSet()
        } else com.enve.app.data.reader.ReaderToolbarButton.DEFAULT_SET

        val progressDisplay = runCatching {
            com.enve.app.data.reader.ReaderProgressDisplay.valueOf(prefs.readerProgressDisplay.first())
        }.getOrDefault(com.enve.app.data.reader.ReaderProgressDisplay.NONE)

        _state.update { it.copy(prefs = ReaderPreferences(
            theme            = theme,
            font             = font,
            customFontName   = customFontName,
            fontSize         = prefs.readerFontSize.first(),
            lineHeight       = prefs.readerLineHeight.first(),
            pageMargins      = prefs.readerPageMargins.first(),
            verticalMargins  = prefs.readerVerticalPageMargins.first(),
            wordSpacing      = wordSpacing,
            letterSpacing    = letterSpacing,
            fontWeight       = prefs.readerFontWeight.first(),
            paragraphSpacing = paragraphSpacing,
            paragraphIndent  = paragraphIndent,
            scroll           = prefs.readerScroll.first(),
            publisherStyles  = publisherStyles,
            justified        = prefs.readerJustified.first(),
            columns          = cols,
            volumeButtonNavigation = prefs.readerVolumeButtonNav.first(),
            autoScrollSpeed  = prefs.readerAutoScrollSpeed.first(),
            toolbarButtons   = toolbarButtons,
            ttsEnabled       = prefs.readerTtsEnabled.first(),
            ttsSpeed         = prefs.readerTtsSpeed.first(),
            readAloudSpeed        = prefs.readAloudSpeed.first(),
            readAloudSyncOffsetMs = prefs.readAloudSyncOffsetMs.first(),
            readAloudAutoTurn     = prefs.readAloudAutoTurn.first(),
            readAloudHighlight    = prefs.readAloudHighlight.first(),
            readAloudHighlightHex = prefs.readAloudHighlightHex.first(),
            readAloudSkipAsides   = prefs.readAloudSkipAsides.first(),
            screenBrightness = prefs.readerScreenBrightness.first(),
            showClock        = prefs.readerShowClock.first(),
            showBattery      = prefs.readerShowBattery.first(),
            progressDisplay  = progressDisplay,
            tapZoneWidth     = prefs.readerTapZoneWidth.first(),
            edgeBrightnessSwipe = prefs.readerEdgeBrightnessSwipe.first(),
            bionicReading    = prefs.readerBionicReading.first(),
        ))}
        preferencesLoaded = true
        mediaOverlayEngine?.let { applyReadAloudSettings(it, _state.value.prefs) }
    }

    private fun loadAnnotations() {
        viewModelScope.launch {
            annotationRepo.byBook(bookId).collect { list ->
                val annotations = list.filter { AnnotationKind.parse(it.kind) != AnnotationKind.BOOKMARK }
                val bookmarks   = list.filter { AnnotationKind.parse(it.kind) == AnnotationKind.BOOKMARK }
                _state.update { it.copy(annotations = annotations, bookmarks = bookmarks) }
                applyDecorations()
            }
        }
    }

    fun annotationForDecoration(id: String): ReaderAnnotation? =
        _state.value.annotations.firstOrNull { it.id == id }
            ?: _state.value.bookmarks.firstOrNull { it.id == id }

    fun attachEngineNavigator(
        engine: ReaderEngineNavigator,
        plan: FoliateOpenPlan,
    ) {
        cancelSearch()
        searchEpubFile = null
        _state.update { it.copy(searchOptionsAvailable = false) }
        readiumRestoreJob?.cancel()
        readiumRestoreJob = null
        readiumUserInteractionPending = false
        navigator = null
        engineNavigator?.takeIf { it !== engine }?.close()
        engineNavigator = engine
        engine.onAnnotationResolution = { resolution ->
            if (engineNavigator === engine) {
                val unresolved = resolution.count { !it.value }
                if (unresolved > 0) {
                    _state.update { it.copy(transientMessage = "$unresolved saved highlight(s) need location repair. They will be retried when the book opens.") }
                }
            }
        }
        epubCheckpointLease = plan.lease
        latestEpubCheckpoint = plan.initialCheckpoint
        foliateExpectedCheckpoint = plan.initialCheckpoint
        foliateRestoreConfirmed = false
        foliateCheckpointSync.reset()
        positions = emptyList()
        pageMarkers = emptyList()
        lastLocator = null
        submitCurrentReadAloudCheckpoint()
        mediaOverlayEngine?.release()
        mediaOverlayEngine = null
        _state.update {
            it.copy(
                readAlongSupported = false,
                readAlongActive = false,
                readAlongPlaying = false,
                readAlongPreparing = false,
                hasPageList = false,
                currentPageLabel = null,
                lastPageLabel = null,
            )
        }
        engine.applyPreferences(_state.value.prefs)
        applyDecorations()
    }

    fun onFoliateReady(
        toc: List<ReaderEngineTocItem>,
        actualCheckpoint: EpubBridgeCheckpoint?,
        restoreMethod: String,
    ): Boolean {
        val entries = toc.mapIndexed { index, item ->
            TocEntry(
                id = "$index:${item.depth}:${item.href}",
                title = item.title,
                href = item.href,
                depth = item.depth,
            )
        }
        val expected = foliateExpectedCheckpoint
        val bootstrappedCheckpoint = if (expected != null && actualCheckpoint != null &&
            EpubBridgeRestoreMatcher.canBootstrapFoliateCfi(
                expected,
                actualCheckpoint,
                restoreMethod,
            )
        ) {
            epubCheckpointLease?.let { lease ->
                actualCheckpoint.copy(
                    publicationSha256 = lease.publicationSha256,
                    providerFileId = lease.providerFileId,
                    revision = latestEpubCheckpoint?.revision ?: lease.checkpoint?.revision ?: 0L,
                    writerEpoch = lease.writerEpoch,
                    observedAt = expected.observedAt,
                    sourceEngine = ReaderEngineKind.FOLIATE,
                )
            }
        } else {
            null
        }
        val confirmed = when {
            expected == null -> true
            EpubBridgeRestoreMatcher.restoredWithFoliateCfi(expected, restoreMethod) ->
                true
            expected.hasPortableAnchor &&
                EpubBridgeRestoreMatcher.restoredWithPortableAnchor(expected, restoreMethod) ->
                true
            bootstrappedCheckpoint != null -> true
            actualCheckpoint != null ->
                EpubBridgeRestoreMatcher.matches(expected, actualCheckpoint)
            else -> false
        }
        if (!confirmed) {
            Log.w(
                TAG,
                "Foliate restore mismatch method=$restoreMethod " +
                    "expectedHref=${expected?.href} expectedTotal=${expected?.totalProgression} " +
                    "expectedResource=${expected?.resourceProgression} expectedPortable=${expected?.hasPortableAnchor} " +
                    "actualHref=${actualCheckpoint?.href} actualTotal=${actualCheckpoint?.totalProgression} " +
                    "actualResource=${actualCheckpoint?.resourceProgression} actualPortable=${actualCheckpoint?.hasPortableAnchor}",
            )
            return false
        }
        foliateRestoreConfirmed = true
        foliateExpectedCheckpoint = null
        if (bootstrappedCheckpoint != null) {
            latestEpubCheckpoint = bootstrappedCheckpoint
            foliateCheckpointSync.submit(bootstrappedCheckpoint)
            scheduleFoliateSync()
        }
        _state.update { it.copy(tocEntries = entries) }
        engineNavigator?.applyPreferences(_state.value.prefs)
        applyDecorations()
        return true
    }

    fun onFoliateLocation(location: ReaderEngineLocation) {
        val lease = epubCheckpointLease ?: return
        val checkpoint = location.checkpoint.copy(
            publicationSha256 = lease.publicationSha256,
            providerFileId = lease.providerFileId,
            revision = latestEpubCheckpoint?.revision ?: lease.checkpoint?.revision ?: 0L,
            writerEpoch = lease.writerEpoch,
            observedAt = System.currentTimeMillis(),
            sourceEngine = ReaderEngineKind.FOLIATE,
        )
        latestEpubCheckpoint = checkpoint
        lastLocator = location.locator
        val currentToc = findCurrentTocEntry(location.locator)
        _state.update {
            it.copy(
                progressPct = ((checkpoint.totalProgression ?: 0.0) * 100.0)
                    .roundToInt()
                    .coerceIn(0, 100),
                currentPage = location.currentPage,
                totalPages = location.totalPages,
                hasPageList = false,
                currentPageLabel = null,
                lastPageLabel = null,
                currentSection = location.sectionTitle.ifBlank {
                    currentToc?.title.orEmpty()
                },
                currentTocEntryId = currentToc?.id,
            )
        }
        if (!foliateRestoreConfirmed) return
        if (!location.userInitiated) return
        foliateCheckpointSync.submit(checkpoint)
        scheduleFoliateSync()
    }

    fun onFoliateSelectionChanged() {
        val selection = engineNavigator?.currentSelection
        if (selection == null) {
            clearSelectionState()
            return
        }
        val text = selection.text.highlight.orEmpty()
        _state.update {
            it.copy(
                pendingSelection = selection,
                selectionText = text,
                showSelectionPopup = true,
                showChrome = false,
            )
        }
    }

    fun attachNavigator(nav: EpubNavigatorFragment, pub: Publication, epubFile: java.io.File? = null) {
        cancelSearch()
        searchEpubFile = epubFile
        _state.update { it.copy(searchOptionsAvailable = epubFile != null) }
        readiumRestoreJob?.cancel()
        readiumRestoreJob = null
        readiumUserInteractionPending = false
        unleasedReadiumPosition.reset()
        foliateExpectedCheckpoint = null
        engineNavigator?.close()
        engineNavigator = null
        navigator   = nav
        positions = emptyList()
        pageMarkers = emptyList()
        _state.update {
            it.copy(
                totalPages = 0,
                currentPage = 0,
                hasPageList = false,
                currentPageLabel = null,
                lastPageLabel = null,
            )
        }

        val previous = publication
        if (previous != null && previous !== pub) {
            viewModelScope.launch(Dispatchers.IO) {
                runCatching { previous.close() }
            }
        }
        publication = pub

        submitCurrentReadAloudCheckpoint()
        mediaOverlayEngine?.release()
        val checkpointToken = readAloudCheckpoints.beginSession(bookId, bookSource, bookConnectionId)
        readAloudCheckpointToken = checkpointToken
        readAloudCheckpointRevision = 0L
        latestReadAloudLocator = null
        readAloudTimelinePrepared = false
        val engine = buildMediaOverlayEngine(pub, epubFile, checkpointToken)
        mediaOverlayEngine = engine
        val supportsReadAlong = engine.detectsSmil()
        Log.i(TAG, "ReadAlong detection: $supportsReadAlong for bookId=$bookId")
        _state.update {
            it.copy(
                readAlongSupported = supportsReadAlong,
                readAlongActive = false,
                readAlongPlaying = false,
                readAlongClipIndex = 0,
                readAlongClipCount = 0,
            )
        }
        clearReadAlongHighlight()
        buildToc(pub)

        applyDecorations()

        einkBoldObserverJob?.cancel()
        einkBoldObserverJob = viewModelScope.launch {
            einkManager.boldText
                .drop(1)
                .collect {
                    navigator?.submitPreferences(_state.value.prefs.toEpubPreferences(einkBoldText = einkBoldActive, einkActive = einkSingleColumnActive))
                }
        }
        startLocatorObserver(nav)

        viewModelScope.launch {
            try {
                val byOrder = pub.positionsByReadingOrder()
                positions = byOrder.flatten()
                pageMarkers = resolvePageMarkers(pub.pageList, positions)
                val totalPages = pageMarkers.size.takeIf { it > 0 } ?: positions.size
                _state.update {
                    it.copy(
                        totalPages = totalPages,
                        hasPageList = pageMarkers.isNotEmpty(),
                        lastPageLabel = pageMarkers.lastOrNull()?.label,
                    )
                }
                lastLocator?.let { loc ->
                    val totalProg = loc.locations.totalProgression ?: 0.0
                    val page = currentPositionIndex(totalProg)
                    _state.update {
                        it.copy(
                            currentPage = page,
                            currentPageLabel = pageMarkers.getOrNull(page - 1)?.label,
                        )
                    }
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {}
        }
    }

    private fun buildMediaOverlayEngine(
        pub: Publication,
        epubFile: java.io.File?,
        checkpointToken: ReadAloudCheckpointToken,
    ): MediaOverlayEngine = MediaOverlayEngine(
        context = appContext,
        publication = pub,
        parentScope = viewModelScope,
        sourceFile = epubFile,
        playback = readAloudPlayback,
        playbackSession = ReadAloudPlaybackSession(
            id = checkpointToken.sessionId,
            bookKey = checkpointToken.bookKey,
            title = bookTitle,
            author = bookAuthor,
        ),
    ).apply {
        onClipChanged = { clip, _ -> onReadAlongClipChanged(checkpointToken, clip) }
        onPlaybackChanged = { isPlaying, playWhenReady ->
            _state.update { current ->
                current.copy(
                    readAlongPlaying = isPlaying,
                    readAlongPreparing = !isPlaying && playWhenReady && current.readAlongActive,
                )
            }
            if (isPlaying) {
                val clip = currentClipSnapshot()
                val nav = navigator
                if (clip != null && nav != null) {
                    readAlongClipUiJob?.cancel()
                    readAlongClipUiJob = viewModelScope.launch {
                        autoNavigateReadAlongClip(clip, nav, buildReadAlongLocator(clip) ?: return@launch)
                        scheduleReadAlongPagePreflip(clip, nav)
                    }
                }
            } else {
                readAlongPageFlipJob?.cancel()
                readAlongPageFlipJob = null
            }
            if (!isPlaying && !playWhenReady) submitCurrentReadAloudCheckpoint()
        }
        onPlaybackCompleted = {
            submitCurrentReadAloudCheckpoint()
            handleReadAlongStopped(clearHighlight = true)
            latestReadAloudLocator?.let { locator ->
                applicationScope.launch(Dispatchers.Main.immediate) {
                    readAloudCheckpoints.flush(bookId, bookSource, bookConnectionId)
                    pushProgress(locator)
                }
            }
        }
        onPlaybackSessionLost = {
            submitCurrentReadAloudCheckpoint()
            handleReadAlongStopped(clearHighlight = true)
        }
        onPlaybackFailed = { message ->
            Log.w(TAG, message)
            postTransientMessage(message)
            handleReadAlongStopped(clearHighlight = true)
        }
        onPlaybackInfo = { message ->
            postTransientMessage(message)
        }
        applyReadAloudSettings(this, _state.value.prefs)

    }

    private fun applyReadAloudSettings(engine: MediaOverlayEngine, p: ReaderPreferences) {
        engine.setPlaybackSpeed(p.readAloudSpeed)
        engine.syncOffsetMs = p.readAloudSyncOffsetMs.toLong()
        engine.skipSkippableClips = p.readAloudSkipAsides
    }

    private fun startLocatorObserver(nav: EpubNavigatorFragment) {
        if (epubCheckpointLease != null) {
            readiumRestoreJob?.cancel()
            readiumRestoreJob = viewModelScope.launch {
                confirmReadiumRestore(nav)
            }
        }
        viewModelScope.launch {
            var lastBionicHref: String? = null
            nav.currentLocator.collect { locator ->
                lastLocator = locator

                val href = locator.href.toString()
                if (href != lastBionicHref) {
                    lastBionicHref = href
                    if (_state.value.prefs.bionicReading) {
                        applyBionicReading(nav, enabled = true)
                    }
                }
                val totalProg = locator.locations.totalProgression ?: 0.0
                val pct = (totalProg * 100).toInt()

                val page = if (pageMarkers.isNotEmpty() || positions.isNotEmpty()) {
                    currentPositionIndex(totalProg)
                } else {
                    _state.value.currentPage.takeIf { it > 0 } ?: 1
                }

                val tocEntry = findCurrentTocEntry(locator)

                val section = locator.title?.takeIf { it.isNotBlank() }
                    ?: tocEntry?.title.orEmpty()

                _state.update {
                    it.copy(
                        progressPct    = pct,
                        currentPage    = page,
                        currentPageLabel = pageMarkers.getOrNull(page - 1)?.label,
                        currentSection = section,
                        currentTocEntryId = tocEntry?.id,
                    )
                }
                if (_state.value.readAlongActive) {
                    if (!audioIsNavigating) {
                        readAlongPageFlipJob?.cancel()
                        readAlongPageFlipJob = null
                    }
                    if (_state.value.readAlongPlaying && !audioIsNavigating) {
                        syncReadAlongToVisiblePage(nav, locator)
                    } else if (!_state.value.readAlongPlaying && !_state.value.readAlongPreparing) {
                        presyncReadAlongToReadingPosition(nav, locator)
                    }
                }
                val lease = epubCheckpointLease
                if (lease == null) {
                    if (readiumUserInteractionPending) {
                        scheduleSync(locator)
                    } else {
                        unleasedReadiumPosition.confirm(locator.toJSONOrNull())
                    }
                } else if (readiumRestoreConfirmed && readiumUserInteractionPending) {
                    readiumUserInteractionPending = false
                    readiumCheckpointDirty = true
                    scheduleReadiumCheckpointSync(nav)
                }
            }
        }
    }

    private fun currentPositionIndex(totalProgression: Double): Int = when {
        pageMarkers.isNotEmpty() ->
            pageMarkers.indexOfLast { it.progression <= totalProgression + 0.000_001 }
                .plus(1)
                .coerceAtLeast(1)
        positions.isNotEmpty() ->
            positions.indexOfLast { (it.locations.totalProgression ?: 0.0) <= totalProgression }
                .plus(1)
                .coerceAtLeast(1)
        else -> 1
    }

    private fun resolvePageMarkers(
        pageList: List<Link>,
        positions: List<Locator>,
    ): List<EpubPageMarker> {
        if (pageList.isEmpty()) return emptyList()
        val positionsByHref = positions.groupBy { it.href.toString().substringBefore('#') }
        val pagesByHref = pageList.groupBy { it.href.toString().substringBefore('#') }
        val pageOffsetByHref = mutableMapOf<String, Int>()

        return pageList.mapIndexed { index, link ->
            val href = link.href.toString().substringBefore('#')
            val resourcePositions = positionsByHref[href].orEmpty()
            val resourcePageCount = pagesByHref[href].orEmpty().size
            val resourcePageIndex = pageOffsetByHref.getOrDefault(href, 0)
            pageOffsetByHref[href] = resourcePageIndex + 1

            val position = if (resourcePositions.isNotEmpty() && resourcePageCount > 0) {
                val positionIndex = (resourcePageIndex * resourcePositions.size / resourcePageCount)
                    .coerceIn(0, resourcePositions.lastIndex)
                resourcePositions[positionIndex]
            } else {
                val positionIndex = if (positions.isEmpty()) 0 else
                    (index * positions.size / pageList.size).coerceIn(0, positions.lastIndex)
                positions.getOrNull(positionIndex)
            }
            val rawLabel = link.title?.trim().orEmpty()
            val label = rawLabel
                .removePrefix("Page ")
                .removePrefix("page ")
                .ifBlank { (index + 1).toString() }
            EpubPageMarker(
                label = label,
                progression = position?.locations?.totalProgression
                    ?: index.toDouble() / pageList.size.coerceAtLeast(1).toDouble(),
            )
        }
    }

    private suspend fun confirmReadiumRestore(nav: EpubNavigatorFragment) {
        val lease = epubCheckpointLease ?: return
        val expected = latestEpubCheckpoint
        val initialLocator = if (expected?.href.isNullOrBlank()) {
            nav.currentLocator.value
        } else {
            kotlinx.coroutines.withTimeoutOrNull(10_000L) {
                nav.currentLocator.first { locator ->
                    EpubBridgeRestoreMatcher.hrefMatches(
                        expected = expected.href,
                        actual = locator.href.toString(),
                    )
                }
            } ?: return
        }
        val javaScriptReady = kotlinx.coroutines.withTimeoutOrNull(5_000L) {
            var ready = false
            while (!ready) {
                val result = nav.evaluateJavascript("(function(){ return 'ready'; })();")
                ready = decodeJavaScriptStringResult(result) == "ready"
                if (!ready) delay(100)
            }
            true
        } == true
        if (!javaScriptReady) return

        if (expected == null) {
            val capture = captureReadiumCheckpoint(nav, initialLocator)
            if (capture != null) {
                latestEpubCheckpoint = capture.checkpoint
                readiumCheckpointFingerprint = checkpointFingerprint(capture.checkpoint)
            }
            readiumRestoreConfirmed = true
            return
        }

        val restoredPortableAnchor = if (expected.hasPortableAnchor) {
            val locatorJson = EpubBridgeCheckpointCodec.toReadiumLocatorJson(expected) ?: return
            val restoredResult = nav.evaluateJavascript(
                ReadiumPortableAnchorScript.restore(locatorJson),
            )
            val restored = restoredResult?.toBooleanStrictOrNull()
                ?: decodeJavaScriptStringResult(restoredResult)?.toBooleanStrictOrNull()
                ?: false
            if (!restored) return
            delay(300)
            true
        } else {
            false
        }

        repeat(5) { attempt ->
            val capture = captureReadiumCheckpoint(nav)
            val captureMatches = capture != null && if (restoredPortableAnchor) {
                EpubBridgeRestoreMatcher.matchesPortableRestoreCapture(
                    expected,
                    capture.checkpoint,
                )
            } else {
                EpubBridgeRestoreMatcher.matches(expected, capture.checkpoint)
            }
            if (capture != null && captureMatches) {
                latestEpubCheckpoint = capture.checkpoint
                readiumCheckpointFingerprint = checkpointFingerprint(capture.checkpoint)
                viewportAnchor = EpubBridgeCheckpointCodec.toReadiumLocatorJson(expected)
                    ?.let { runCatching { Locator.fromJSON(org.json.JSONObject(it)) }.getOrNull() }
                    ?.let { ViewportAnchor(it, page = nav.currentLocator.value.pageKey()) }
                readiumRestoreConfirmed = true
                return
            }
            if (attempt < 4) delay(250)
        }
        Log.w(TAG, "Readium restore did not resolve to the selected EPUB checkpoint")
    }

    private suspend fun captureReadiumCheckpoint(
        nav: EpubNavigatorFragment,
        locator: Locator = nav.currentLocator.value,
    ): ReadiumCheckpointCapture? {
        val lease = epubCheckpointLease ?: return null
        val locatorJson = runCatching { locator.toJSON().toString() }.getOrNull() ?: return null
        val visibleAnchor = decodeJavaScriptStringResult(
            nav.evaluateJavascript(ReadiumPortableAnchorScript.capture),
        )?.let(EpubBridgeCheckpointCodec::decodeVisibleAnchor)
        val enrichedLocator = visibleAnchor
            ?.let { EpubBridgeCheckpointCodec.withVisibleAnchor(locatorJson, it) }
            ?: locatorJson
        val checkpoint = EpubBridgeCheckpointCodec.fromReadiumLocator(
            locatorJson = enrichedLocator,
            publicationSha256 = lease.publicationSha256,
            providerFileId = lease.providerFileId,
            writerEpoch = lease.writerEpoch,
            revision = latestEpubCheckpoint?.revision ?: lease.checkpoint?.revision ?: 0L,
            observedAt = System.currentTimeMillis(),
        ) ?: return null
        return ReadiumCheckpointCapture(locator, checkpoint)
    }

    private fun checkpointFingerprint(checkpoint: EpubBridgeCheckpoint): String =
        checkpoint.copy(
            revision = 0L,
            observedAt = 0L,
        ).let(EpubBridgeCheckpointCodec::encode)

    private fun findCurrentTocEntry(locator: Locator): TocEntry? {
        val locatorHref = normalizePublicationHref(locator.href.toString()) ?: return null
        val candidates = _state.value.tocEntries.filter { entry ->
            val entryHref = normalizePublicationHref(entry.href)
            entryHref == locatorHref || entryHref?.endsWith(locatorHref) == true || locatorHref.endsWith(entryHref.orEmpty())
        }
        if (candidates.isEmpty()) return null

        val locatorFragments = locator.locations.fragments.toSet()
        return candidates.firstOrNull { entry ->
            entry.href.substringAfter('#', missingDelimiterValue = "") in locatorFragments
        } ?: candidates.firstOrNull { it.title == locator.title } ?: candidates.first()
    }

    private fun buildToc(pub: Publication) {
        viewModelScope.launch {
            val entries = buildList {
                fun append(links: List<org.readium.r2.shared.publication.Link>, depth: Int) {
                    links.forEach { link ->
                        val href = link.url().toString()
                        val title = link.title?.trim().takeUnless { it.isNullOrEmpty() }
                            ?: href.substringBefore('#').substringAfterLast('/').ifBlank { "Untitled" }
                        add(TocEntry(id = "${size}:$depth:$href", title = title, href = href, depth = depth))
                        append(link.children, depth + 1)
                    }
                }
                append(pub.tableOfContents, 0)
            }
            _state.update { it.copy(tocEntries = entries) }
            lastLocator?.let { locator ->
                val current = findCurrentTocEntry(locator)
                _state.update { it.copy(currentTocEntryId = current?.id) }
            }
        }
    }

    fun navigateTo(entry: TocEntry) {
        engineNavigator?.let {
            it.goToHref(entry.href)
            return
        }
        viewModelScope.launch {
            val pub  = publication ?: return@launch
            val nav  = navigator  ?: return@launch
            fun find(links: List<org.readium.r2.shared.publication.Link>): org.readium.r2.shared.publication.Link? {
                links.forEach { link ->
                    if (link.url().toString() == entry.href) return link
                    find(link.children)?.let { return it }
                }
                return null
            }
            val link = find(pub.tableOfContents)
                ?: pub.readingOrder.firstOrNull { it.url().toString() == entry.href }
                ?: return@launch
            readiumUserInteractionPending = true
            if (!nav.go(link)) readiumUserInteractionPending = false
        }
    }

    fun applyPreferences() {
        engineNavigator?.let {
            it.applyPreferences(_state.value.prefs)
            return
        }
        navigator?.submitPreferences(
            _state.value.prefs.toEpubPreferences(
                einkBoldText = einkBoldActive,
                einkActive = einkSingleColumnActive,
            ),
        )
    }

    fun updatePreferences(newPrefs: ReaderPreferences) {
        val oldPrefs = _state.value.prefs
        _state.update { it.copy(prefs = newPrefs) }
        if (newPrefs.publisherStyles != oldPrefs.publisherStyles) {
            prefs.saveReaderPublisherStyles(newPrefs.publisherStyles)
        }
        if (newPrefs.readAloudSpeed != oldPrefs.readAloudSpeed ||
            newPrefs.readAloudSyncOffsetMs != oldPrefs.readAloudSyncOffsetMs ||
            newPrefs.readAloudSkipAsides != oldPrefs.readAloudSkipAsides
        ) {
            mediaOverlayEngine?.let { applyReadAloudSettings(it, newPrefs) }
        }
        if (newPrefs.readAloudAutoTurn != oldPrefs.readAloudAutoTurn ||
            newPrefs.readAloudSpeed != oldPrefs.readAloudSpeed ||
            newPrefs.scroll != oldPrefs.scroll
        ) {
            readAlongPageFlipJob?.cancel()
            readAlongPageFlipJob = null
            if (newPrefs.readAloudAutoTurn && !newPrefs.scroll && _state.value.readAlongPlaying) {
                val clip = mediaOverlayEngine?.currentClipSnapshot()
                val nav = navigator
                if (clip != null && nav != null) {
                    readAlongClipUiJob?.cancel()
                    readAlongClipUiJob = viewModelScope.launch { scheduleReadAlongPagePreflip(clip, nav) }
                }
            }
        }
        if (newPrefs.readAloudHighlight != oldPrefs.readAloudHighlight ||
            newPrefs.readAloudHighlightHex != oldPrefs.readAloudHighlightHex
        ) {
            refreshReadAlongHighlight()
        }
        navigator?.submitPreferences(newPrefs.toEpubPreferences(einkBoldText = einkBoldActive, einkActive = einkSingleColumnActive))
        engineNavigator?.applyPreferences(newPrefs)

        savePrefsJob?.cancel()
        savePrefsJob = viewModelScope.launch {
            delay(150)
            persistPreferences(newPrefs)
        }

        if (newPrefs.bionicReading != oldPrefs.bionicReading) {
            navigator?.let { applyBionicReading(it, enabled = newPrefs.bionicReading) }
        }
    }

    fun flushPreferences() {
        if (!preferencesLoaded) return
        savePrefsJob?.cancel()
        savePrefsJob = viewModelScope.launch {
            persistPreferences(_state.value.prefs)
        }
    }

    private suspend fun persistPreferences(readerPrefs: ReaderPreferences) {
        prefs.saveReaderPreferences(
            theme = readerPrefs.theme.name,
            fontFamily = readerPrefs.font.name,
            customFontName = readerPrefs.customFontName.orEmpty(),
            fontSize = readerPrefs.fontSize,
            lineHeight = readerPrefs.lineHeight,
            pageMargins = readerPrefs.pageMargins,
            verticalPageMargins = readerPrefs.verticalMargins,
            wordSpacing = readerPrefs.wordSpacing,
            letterSpacing = readerPrefs.letterSpacing,
            fontWeight = readerPrefs.fontWeight,
            paragraphSpacing = readerPrefs.paragraphSpacing,
            paragraphIndent = readerPrefs.paragraphIndent,
            scroll = readerPrefs.scroll,
            publisherStyles = readerPrefs.publisherStyles,
            justified = readerPrefs.justified,
            columnCount = readerPrefs.columns.name,
            volumeButtonNav = readerPrefs.volumeButtonNavigation,
            autoScrollSpeed = readerPrefs.autoScrollSpeed,
            toolbarButtons = readerPrefs.toolbarButtons.joinToString(",") { it.name },
            ttsEnabled = readerPrefs.ttsEnabled,
            ttsSpeed = readerPrefs.ttsSpeed,
            readAloudSpeed = readerPrefs.readAloudSpeed,
            readAloudSyncOffsetMs = readerPrefs.readAloudSyncOffsetMs,
            readAloudAutoTurn = readerPrefs.readAloudAutoTurn,
            readAloudHighlight = readerPrefs.readAloudHighlight,
            readAloudHighlightHex = readerPrefs.readAloudHighlightHex,
            readAloudSkipAsides = readerPrefs.readAloudSkipAsides,
            screenBrightness = readerPrefs.screenBrightness,
            showClock = readerPrefs.showClock,
            showBattery = readerPrefs.showBattery,
            progressDisplay = readerPrefs.progressDisplay.name,
            tapZoneWidth = readerPrefs.tapZoneWidth,
            edgeBrightnessSwipe = readerPrefs.edgeBrightnessSwipe,
            bionicReading = readerPrefs.bionicReading,
        )
    }

    private fun applyBionicReading(nav: org.readium.r2.navigator.epub.EpubNavigatorFragment, enabled: Boolean) {
        viewModelScope.launch {
            try {
                nav.evaluateJavascript(com.enve.app.data.reader.ReaderBionicScript.makeScript(enabled))
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {  }
        }
    }

    fun toggleChrome() {
        _state.update { it.copy(showChrome = !it.showChrome) }
        if (_state.value.showChrome) keepChromeAlive()
    }
    fun hideChrome()   = _state.update { it.copy(showChrome = false) }

    fun keepChromeAlive() { _chromeInteraction.value = System.currentTimeMillis() }
    fun showAppearance(show: Boolean) = _state.update { it.copy(showAppearanceSheet = show, showChrome = if (show) true else it.showChrome) }
    fun showMoreMenu(show: Boolean) = _state.update { it.copy(showMoreMenu = show, showChrome = if (show) true else it.showChrome) }
    fun showToc(show: Boolean)        = _state.update { it.copy(showTocSheet = show, showChrome = if (show) true else it.showChrome) }
    fun showAnnotationDialog(show: Boolean) = _state.update { it.copy(showAnnotationDialog = show) }
    fun showAnnotationsSheet(show: Boolean) = _state.update { it.copy(showAnnotationsSheet = show, showChrome = if (show) true else it.showChrome) }

    fun showSelectionPopup() {
        viewModelScope.launch {
            val engineSelection = engineNavigator?.currentSelection
            val readiumSelection = navigator
                ?.let { it as? org.readium.r2.navigator.SelectableNavigator }
                ?.currentSelection()
                ?.locator
            val locator = engineSelection ?: readiumSelection?.let { enrichReadiumSelectionLocator(it) }
            if (locator != null) {
                val text = locator.text.highlight ?: ""
                _state.update {
                    it.copy(
                        pendingSelection = locator,
                        selectionText = text,
                        showSelectionPopup = true,
                        showChrome = false,
                    )
                }
            } else {
                clearSelectionState()
            }
        }
    }

    private suspend fun enrichReadiumSelectionLocator(locator: Locator): Locator {
        val nav = navigator ?: return locator
        val locatorJson = runCatching { locator.toJSON().toString() }.getOrNull() ?: return locator
        val raw = decodeJavaScriptStringResult(
            nav.evaluateJavascript(ReadiumPortableAnchorScript.selection),
        ) ?: return locator
        val anchor = EpubBridgeCheckpointCodec.decodeVisibleAnchor(raw) ?: return locator
        val enriched = EpubBridgeCheckpointCodec.withVisibleAnchor(
            locatorJson,
            anchor,
            epubCfi = readiumSelectionCfi(raw, locator),
        ) ?: return locator
        return runCatching { Locator.fromJSON(org.json.JSONObject(enriched)) }
            .getOrNull()
            ?: locator
    }

    private fun readiumSelectionCfi(rawAnchorJson: String, locator: Locator): String? {
        val root = runCatching { org.json.JSONObject(rawAnchorJson) }.getOrNull() ?: return null
        fun field(name: String): String? =
            if (root.isNull(name)) null else root.optString(name).takeIf { it.isNotBlank() }
        val parent = field("cfiParent") ?: return null
        val start = field("cfiStart") ?: return null
        val end = field("cfiEnd") ?: return null
        val index = publication?.readingOrder
            ?.indexOfFirst { it.url().toString() == locator.href.toString() }
            ?.takeIf { it >= 0 }
            ?: return null
        return "epubcfi(/6/${2 * (index + 1)}!$parent,$start,$end)"
    }

    fun hideSelectionPopup() {
        _state.update { it.copy(showSelectionPopup = false) }
    }

    fun showAutoScrollPanel(show: Boolean) {
        _state.update { it.copy(showAutoScrollPanel = show, showChrome = if (show) true else it.showChrome) }
        if (!show) stopAutoScroll()
    }

    fun stopAutoScroll() {
        autoScrollJob?.cancel()
        autoScrollJob = null
        _state.update { it.copy(autoScrollActive = false) }
    }

    fun showToolbarCustomizer(show: Boolean) {
        _state.update { it.copy(showToolbarCustomizer = show, showChrome = if (show) true else it.showChrome) }
    }

    fun setTtsEngine(engine: android.speech.tts.TextToSpeech?) {
        ttsEngine = engine
        if (engine == null) clearTtsHighlight()
    }

    fun speakSelection(text: String) {
        val engine = ttsEngine ?: return
        if (text.isBlank()) return
        val utteranceId = ttsUtteranceId
        val result = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.LOLLIPOP) {
            engine.speak(text, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        } else {
            @Suppress("DEPRECATION")
            engine.speak(text, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null)
        }
        if (result == android.speech.tts.TextToSpeech.SUCCESS) {
            _state.update { it.copy(ttsSpeaking = true) }
        } else {
            clearTtsHighlight()
            postTransientMessage("Couldn't speak that selection.")
        }
    }

    fun stopTts() {
        ttsEngine?.stop()
        clearTtsHighlight()
    }

    fun clearTtsHighlight() {
        _state.update { it.copy(ttsWordHighlight = null, ttsSpeaking = false) }
    }

    fun toggleReadAlongPlayback() {
        if (!_state.value.readAlongActive) {
            startReadAlongMode()
            return
        }

        val engine = mediaOverlayEngine
        if (engine == null) {
            postTransientMessage("Read-along is unavailable for this book.")
            return
        }
        if (_state.value.readAlongPreparing) return
        if (_state.value.readAlongPlaying) {
            submitCurrentReadAloudCheckpoint()
            readAlongPageFlipJob?.cancel()
            readAlongPageFlipJob = null
            engine.pause()
        } else {
            _state.update { it.copy(readAlongPreparing = true) }
            engine.resume()
        }
    }

    fun toggleReadAlongMode() {
        if (!_state.value.readAlongSupported) {
            postTransientMessage("This book doesn't have read-aloud audio.")
            return
        }
        if (_state.value.readAlongActive) {
            stopReadAlongMode()
            return
        }

        startReadAlongMode()
    }

    private fun startReadAlongMode() {
        val engine = mediaOverlayEngine
        if (engine == null) {
            postTransientMessage("Read-along isn't ready yet.")
            return
        }

        val locator = lastLocator ?: navigator?.currentLocator?.value
        val targetHref = locator?.href?.toString()
            ?: publication?.readingOrder?.firstOrNull()?.url()?.toString()
            ?: run {
                postTransientMessage("Couldn't find a starting point for read aloud.")
                return
            }
        val targetProgression = locator?.locations?.progression ?: locator?.locations?.totalProgression

        readAlongStartJob?.cancel()
        beginReadAlongRequest(engine)
        val restoredFragment = restoredReadAloudFragment?.takeIf {
            android.os.SystemClock.elapsedRealtime() - restoredReadAloudFragmentAtMs < RESTORED_SENTENCE_WINDOW_MS
        }
        restoredReadAloudFragment = null

        postTransientMessage("Preparing read aloud…")
        readAlongStartJob = viewModelScope.launch {
            val startMs = android.os.SystemClock.elapsedRealtime()
            fun phase(name: String) {
                Log.i(TAG, "readAloudStart phase=$name ms=${android.os.SystemClock.elapsedRealtime() - startMs}")
            }
            val nav = navigator
            prepareStorytellerReadAloudTimeline(engine)
            phase("findVisibleClip:begin")
            val visibleClip = nav?.let {
                restoredVisibleReadAlongClip(it, restoredFragment, targetHref)
                    ?: firstVisibleReadAlongClip(it, targetHref, targetProgression)
            } ?: engine.firstClipForHref(targetHref, targetProgression)
            phase("findVisibleClip:end")
            if (visibleClip != null) {
                engine.play(
                    textHref = visibleClip.textHref,
                    fragmentId = visibleClip.textFragmentId,
                    resourceProgression = visibleClip.resourceProgression,
                )
            } else {
                engine.play(targetHref, locator?.locations?.fragments?.firstOrNull(), targetProgression)
            }
            phase("engine.play:returned")
        }
    }

    private fun beginReadAlongRequest(engine: MediaOverlayEngine) {
        _state.update {
            it.copy(
                readAlongActive = true,
                readAlongPreparing = true,
                showChrome = true,
            )
        }
        engine.beginPlaybackPreparation()
        audioPlaybackManager.stop()
        readAloudPlayback.connect()
    }

    private suspend fun prepareStorytellerReadAloudTimeline(engine: MediaOverlayEngine) {
        if (readAloudTimelinePrepared || bookSource != BookSource.STORYTELLER) return
        val tracks = loadStorytellerReadAloudAudioTracks()
        if (tracks.isNotEmpty()) {
            engine.setAudioTimeline(tracks)
            readAloudTimelinePrepared = true
        }
    }

    suspend fun loadStorytellerReadAloudAudioTracks(): List<com.enve.core.data.model.AudioTrack> {
        if (bookSource != BookSource.STORYTELLER) return emptyList()
        val book = Book(
            id = bookId,
            title = bookTitle.ifBlank { bookId },
            author = bookAuthor,
            source = BookSource.STORYTELLER,
            mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
            connectionId = bookConnectionId,
            hasAudio = true,
            hasEbook = true,
            readAlongAvailable = true,
        )
        return aggregatorRepository.getAudioTracks(book).getOrNull().orEmpty()
    }

    private fun stopReadAlongMode() {
        readAlongStartJob?.cancel()
        readAlongStartJob = null
        submitCurrentReadAloudCheckpoint()
        mediaOverlayEngine?.stop(clearPlaybackQueue = true)
        handleReadAlongStopped(clearHighlight = true)
    }

    fun onReaderBackgrounded() {
        submitCurrentReadAloudCheckpoint()
    }

    fun onReaderForegrounded() {
        if (_state.value.readAlongActive) {
            mediaOverlayEngine?.reconcilePlaybackPosition()
        }
    }

    fun setReadAlongSpeed(speed: Float) {
        updatePreferences(_state.value.prefs.copy(readAloudSpeed = speed.coerceIn(0.5f, 3.0f)))
    }

    fun showReadAloudSheet(show: Boolean) {
        _state.update { it.copy(showReadAloudSheet = show, showChrome = if (show) true else it.showChrome) }
        if (show) loadReadAlongChapterClips()
    }

    private fun loadReadAlongChapterClips() {
        val engine = mediaOverlayEngine ?: return
        viewModelScope.launch {
            val preferredHref = engine.currentClip()?.textHref
                ?: navigator?.currentLocator?.value?.href?.toString()
            val clips = engine.chapterClips(preferredHref)
            val chapterHref = clips.firstOrNull()?.textHref ?: preferredHref
            val textByFragment = chapterHref
                ?.let { href -> chapterHtml(href)?.let { html -> href to html } }
                ?.let { (href, html) ->
                    ReadAloudLyricsBuilder.lines(clips, html, href).associate { it.id to it.text }
                }
                .orEmpty()
            val rows = clips.mapIndexed { i, c ->
                ReadAloudClipRow(
                    index = i,
                    startMs = c.clipBeginMs,
                    skippable = c.skippable,
                    textHref = c.textHref,
                    fragmentId = c.textFragmentId,
                    resourceProgression = c.resourceProgression,
                    text = c.textFragmentId?.let { textByFragment[it] }.orEmpty(),
                )
            }
            _state.update { it.copy(readAlongChapterClips = rows) }
        }
    }

    private suspend fun chapterHtml(href: String): String? {
        val pub = publication ?: return null
        val wanted = href.substringBefore('#').substringAfterLast('/')
        val link = pub.readingOrder.firstOrNull {
            it.url().toString().substringBefore('#').substringAfterLast('/') == wanted
        } ?: return null
        val resource = pub.get(link) ?: return null
        return try {
            resource.read().getOrNull()?.toString(Charsets.UTF_8)
        } finally {
            resource.close()
        }
    }

    fun showReadAloudLyrics(show: Boolean) {
        _state.update { it.copy(showReadAloudLyrics = show, showChrome = if (show) true else it.showChrome) }
        if (show) loadReadAlongChapterClips()
    }

    fun jumpToReadAlongClip(row: ReadAloudClipRow) {
        if (_state.value.readAlongPreparing) return
        val engine = mediaOverlayEngine ?: return
        readAlongStartJob?.cancel()
        beginReadAlongRequest(engine)
        readAlongStartJob = viewModelScope.launch {
            prepareStorytellerReadAloudTimeline(engine)
            if (!_state.value.readAlongActive) return@launch
            engine.play(
                textHref = row.textHref,
                fragmentId = row.fragmentId,
                resourceProgression = row.resourceProgression,
            )
        }
    }

    fun skipReadAlongForward() {
        if (!_state.value.readAlongSupported || _state.value.readAlongPreparing) return
        _state.update { it.copy(showChrome = true) }
        mediaOverlayEngine?.skipForward()
    }

    fun skipReadAlongBackward() {
        if (!_state.value.readAlongSupported || _state.value.readAlongPreparing) return
        _state.update { it.copy(showChrome = true) }
        mediaOverlayEngine?.skipBackward()
    }

    fun handleReadAlongDoubleTap(viewX: Float, viewY: Float) {
        val engine = mediaOverlayEngine ?: return
        val nav = navigator ?: return
        if (!_state.value.readAlongSupported || _state.value.readAlongPreparing) return

        readAlongStartJob?.cancel()
        readAlongStartJob = viewModelScope.launch {
            val script = """
                (function() {
                    var el = document.elementFromPoint($viewX, $viewY);
                    while (el && !el.id && el.parentElement) {
                        el = el.parentElement;
                    }
                    return (el && el.id) ? el.id : null;
                })();
            """.trimIndent()

            val rawResult = nav.evaluateJavascript(script)
            val fragmentId = decodeJavaScriptStringResult(rawResult) ?: return@launch
            val preferredHref = nav.currentLocator.value.href.toString()
            val clip = engine.bestClipForFragment(fragmentId, preferredHref) ?: return@launch
            if (_state.value.readAlongPreparing) return@launch

            beginReadAlongRequest(engine)
            prepareStorytellerReadAloudTimeline(engine)
            if (!_state.value.readAlongActive) return@launch
            engine.play(
                textHref = clip.textHref,
                fragmentId = clip.textFragmentId,
                resourceProgression = clip.resourceProgression,
            )
        }
    }

    private fun onReadAlongClipChanged(token: ReadAloudCheckpointToken, clip: SmilClip) {
        if (token != readAloudCheckpointToken) return
        val engine = mediaOverlayEngine ?: return
        _state.update {
            it.copy(
                readAlongClipIndex = (engine.currentClipIndex ?: 0).coerceAtLeast(0),
                readAlongClipCount = engine.clipCount,
            )
        }
        val locator = buildReadAlongLocator(clip) ?: return
        submitReadAloudCheckpoint(token, locator)
        scheduleSync(locator)
        applyReadAlongHighlight(locator)
        val nav = navigator ?: return
        readAlongClipUiJob?.cancel()
        readAlongClipUiJob = viewModelScope.launch {
            if (token != readAloudCheckpointToken) return@launch
            autoNavigateReadAlongClip(clip, nav, locator)
            scheduleReadAlongPagePreflip(clip, nav)
        }
    }

    private suspend fun scheduleReadAlongPagePreflip(clip: SmilClip, nav: EpubNavigatorFragment) {
        readAlongPageFlipJob?.cancel()
        readAlongPageFlipJob = null
        if (!_state.value.prefs.readAloudAutoTurn || _state.value.prefs.scroll || !_state.value.readAlongPlaying) return

        val fragmentId = clip.textFragmentId ?: return
        val split = readAlongFragmentSplit(fragmentId, nav) ?: return
        val engine = mediaOverlayEngine ?: return
        val delayMs = if (split.offScreenRatio >= 0.9) {
            0L
        } else {
            engine.currentPageFlipDelayMs(split.visibleRatio) ?: return
        }
        val expectedClip = clip
        readAlongPageFlipJob = viewModelScope.launch {
            if (delayMs > 0L) delay(delayMs)
            if (!_state.value.readAlongPlaying || audioIsNavigating) return@launch
            if (mediaOverlayEngine?.currentClipSnapshot() != expectedClip) return@launch
            audioIsNavigating = true
            try {
                nav.goForward(animated = true)
            } finally {
                readAlongSyncJob?.cancel()
                readAlongSyncJob = viewModelScope.launch {
                    delay(800)
                    audioIsNavigating = false
                }
            }
        }
    }

    private suspend fun autoNavigateReadAlongClip(
        clip: SmilClip,
        nav: EpubNavigatorFragment,
        locator: Locator,
    ) {
        if (!_state.value.prefs.readAloudAutoTurn) return
        val fragmentId = clip.textFragmentId ?: return
        val currentHref = normalizePublicationHref(nav.currentLocator.value.href.toString())
        val clipHref = normalizePublicationHref(clip.textHref)

        if (clipHref == currentHref && isReadAlongFragmentVisible(fragmentId, nav)) {
            return
        }

        audioIsNavigating = true
        try {
            if (clipHref == currentHref && _state.value.prefs.scroll) {
                scrollReadAlongFragmentIntoView(fragmentId, nav)
            } else {
                nav.go(locator)
            }
        } finally {
            readAlongSyncJob?.cancel()
            readAlongSyncJob = viewModelScope.launch {
                delay(800)
                audioIsNavigating = false
            }
        }
    }

    private fun buildReadAlongLocator(clip: SmilClip): Locator? {
        val pub = publication ?: return null
        val href = parsePublicationHref(clip.textHref) ?: return null
        val manifestLink = pub.linkWithHref(href)
        val baseLocator = manifestLink
            ?.let(pub::locatorFromLink)
            ?: Locator(
                href = href,
                mediaType = manifestLink?.mediaType ?: MediaType.XHTML,
            )

        val fragmentId = clip.textFragmentId
        val fragments = fragmentId?.let(::listOf) ?: emptyList()
        val totalProgression = mediaOverlayEngine?.readingProgression(clip)
            ?: lastLocator?.locations?.totalProgression
            ?: baseLocator.locations.totalProgression
        return baseLocator.copyWithLocations(
            fragments = fragments,
            progression = clip.resourceProgression ?: baseLocator.locations.progression,
            totalProgression = totalProgression,
        )
    }

    private fun applyReadAlongHighlight(locator: Locator) {
        val nav = navigator as? DecorableNavigator ?: return
        val p = _state.value.prefs
        if (!p.readAloudHighlight) {
            clearReadAlongHighlight()
            return
        }
        val tint = parseHexColor(p.readAloudHighlightHex)?.toArgb() ?: 0xFFFFF59D.toInt()
        val decoration = Decoration(
            id = READ_ALONG_DECORATION_ID,
            locator = locator,
            style = Decoration.Style.Highlight(
                tint = tint,
                isActive = true,
            ),
        )
        viewModelScope.launch {
            nav.applyDecorations(listOf(decoration), READ_ALONG_DECORATION_GROUP)
        }
    }

    private fun submitCurrentReadAloudCheckpoint() {
        val engine = mediaOverlayEngine ?: return
        val token = readAloudCheckpointToken ?: return
        val clip = engine.currentClipSnapshot() ?: return
        val locator = buildReadAlongLocator(clip) ?: return
        submitReadAloudCheckpoint(token, locator)
    }

    private fun submitReadAloudCheckpoint(token: ReadAloudCheckpointToken, locator: Locator) {
        if (token != readAloudCheckpointToken) return
        val engine = mediaOverlayEngine ?: return
        val progress = (locator.locations.totalProgression ?: currentReadingProgress()).toFloat().coerceIn(0f, 1f)
        latestReadAloudLocator = locator
        val audioPositionMs = engine.currentAbsoluteAudioPositionMs() ?: return
        narrationStore.recordNarration(bookId, audioPositionMs / 1000.0)
        val json = runCatching { locator.toJSON().toString() }.getOrNull()
            ?: return
        readAloudCheckpointRevision += 1L
        readAloudCheckpoints.submit(
            token = token,
            revision = readAloudCheckpointRevision,
            checkpoint = ReadAloudCheckpoint(
                bookId = bookId,
                connectionId = bookConnectionId,
                progress = progress,
                currentTimeSec = (audioPositionMs / 1000L).coerceAtLeast(0L),
                locatorJson = json,
                updatedAtMs = System.currentTimeMillis(),
            ),
        )
    }

    private fun refreshReadAlongHighlight() {
        val engine = mediaOverlayEngine ?: return
        if (!_state.value.readAlongActive) return
        viewModelScope.launch {
            val clip = engine.currentClip() ?: return@launch
            val locator = buildReadAlongLocator(clip) ?: return@launch
            applyReadAlongHighlight(locator)
        }
    }

    private fun clearReadAlongHighlight() {
        val nav = navigator as? DecorableNavigator ?: return
        viewModelScope.launch {
            nav.applyDecorations(emptyList(), READ_ALONG_DECORATION_GROUP)
        }
    }

    private fun handleReadAlongStopped(clearHighlight: Boolean) {
        cancelScheduledProgressPush()
        syncJob = null
        narrationStore.clearNarration(bookId)
        readAlongSyncJob?.cancel()
        readAlongStartJob?.cancel()
        readAlongStartJob = null
        readAlongClipUiJob?.cancel()
        readAlongPageFlipJob?.cancel()
        readAlongPageFlipJob = null
        audioIsNavigating = false
        _state.update {
            it.copy(
                readAlongActive = false,
                readAlongPlaying = false,
                readAlongPreparing = false,
                readAlongClipIndex = 0,
                readAlongClipCount = 0,
            )
        }
        if (clearHighlight) {
            clearReadAlongHighlight()
        }
    }

    private fun presyncReadAlongToReadingPosition(nav: EpubNavigatorFragment, locator: Locator) {
        val engine = mediaOverlayEngine ?: return
        readAlongSyncJob?.cancel()
        readAlongSyncJob = viewModelScope.launch {
            val targetHref = locator.href.toString()
            val targetProgression = locator.locations.progression ?: locator.locations.totalProgression
            val visibleClip = firstVisibleReadAlongClip(nav, targetHref, targetProgression)
                ?: engine.firstClipForHref(targetHref, targetProgression)
            visibleClip?.let {
                engine.syncToLocation(
                    textHref = it.textHref,
                    fragmentId = it.textFragmentId,
                    resourceProgression = it.resourceProgression,
                )
            }
        }
    }

    private fun syncReadAlongToVisiblePage(nav: EpubNavigatorFragment, locator: Locator) {
        val engine = mediaOverlayEngine ?: return
        readAlongSyncJob?.cancel()
        readAlongSyncJob = viewModelScope.launch {
            delay(300)
            val currentClip = engine.currentClip()
            val fragId = currentClip?.textFragmentId
            if (fragId != null && isReadAlongFragmentVisible(fragId, nav)) {
                return@launch
            }

            val targetHref = locator.href.toString()
            val targetProgression = locator.locations.progression ?: locator.locations.totalProgression
            val visibleClip = firstVisibleReadAlongClip(nav, targetHref, targetProgression)
                ?: engine.firstClipForHref(targetHref, targetProgression)
                ?: return@launch

            engine.play(
                textHref = visibleClip.textHref,
                fragmentId = visibleClip.textFragmentId,
                resourceProgression = visibleClip.resourceProgression,
            )
        }
    }

    private fun narratedFragmentId(checkpoint: EpubBridgeCheckpoint): String? =
        checkpoint.cssSelector
            ?.takeIf { it.length > 1 && it.startsWith("#") && it.drop(1).none { c -> c in " >.:[" } }
            ?.drop(1)
            ?: checkpoint.nativeReadiumLocatorJson
                ?.let { runCatching { Locator.fromJSON(org.json.JSONObject(it)) }.getOrNull() }
                ?.locations
                ?.fragments
                ?.firstOrNull { it.isNotBlank() && !it.startsWith("epubcfi(") && '=' !in it }

    private suspend fun restoredVisibleReadAlongClip(
        nav: EpubNavigatorFragment,
        fragmentId: String?,
        preferredHref: String,
    ): SmilClip? {
        if (fragmentId == null || !isReadAlongFragmentVisible(fragmentId, nav)) return null
        return mediaOverlayEngine?.bestClipForFragment(fragmentId, preferredHref)
    }

    private suspend fun firstVisibleReadAlongClip(
        nav: EpubNavigatorFragment,
        preferredHref: String,
        resourceProgression: Double?,
    ): SmilClip? {
        val engine = mediaOverlayEngine ?: return null
        for (fullyVisible in listOf(true, false)) {
            val visibleIds = visibleReadAlongFragmentIds(nav, fullyVisible) ?: continue
            engine.firstVisibleClip(visibleIds, preferredHref)?.let { return it }
        }
        return engine.firstClipForHref(preferredHref, resourceProgression)
    }

    private suspend fun visibleReadAlongFragmentIds(nav: EpubNavigatorFragment, fullyVisible: Boolean): List<String>? {
        val script = """
            (function() {
                const fullyVisible = $fullyVisible;
                const elements = Array.from(document.querySelectorAll('[id]'));
                return elements.filter((el) => {
                    const rect = el.getBoundingClientRect();
                    if (rect.width <= 0 && rect.height <= 0) return false;
                    if (fullyVisible) {
                        return rect.top >= 0 && rect.bottom <= window.innerHeight && rect.left >= 0 && rect.right <= window.innerWidth;
                    }
                    return rect.bottom > 0 && rect.top < window.innerHeight && rect.right > 0 && rect.left < window.innerWidth;
                }).sort((a, b) => {
                    const ar = a.getBoundingClientRect();
                    const br = b.getBoundingClientRect();
                    if (Math.abs(ar.top - br.top) > 1) return ar.top - br.top;
                    return ar.left - br.left;
                }).map((el) => el.id).slice(0, 64);
            })();
        """.trimIndent()

        val result = nav.evaluateJavascript(script) ?: return null
        val json = runCatching { org.json.JSONArray(result) }.getOrNull() ?: return null
        return (0 until json.length()).map(json::optString).filter { it.isNotBlank() }.ifEmpty { null }
    }

    private suspend fun isReadAlongFragmentVisible(fragmentId: String, nav: EpubNavigatorFragment): Boolean {
        val safeId = fragmentId.replace("\\", "\\\\").replace("'", "\\'")
        val script = """
            (function() {
                const el = document.getElementById('$safeId');
                if (!el) return false;
                const rect = el.getBoundingClientRect();
                return rect.bottom > 0 && rect.top < window.innerHeight && rect.right > 0 && rect.left < window.innerWidth && (rect.width > 0 || rect.height > 0);
            })();
        """.trimIndent()
        return nav.evaluateJavascript(script)?.toBooleanStrictOrNull() ?: false
    }

    private suspend fun readAlongFragmentSplit(
        fragmentId: String,
        nav: EpubNavigatorFragment,
    ): ReadAlongFragmentSplit? {
        val safeId = org.json.JSONObject.quote(fragmentId)
        val script = """
            (function() {
                const el = document.getElementById($safeId);
                if (!el) return null;
                const writingMode = window.getComputedStyle(document.body).writingMode || '';
                if (writingMode.startsWith('vertical')) return null;
                const rects = Array.from(el.getClientRects()).filter((r) => r.width > 0 && r.height > 0);
                if (!rects.length) return null;
                const viewport = { left: 0, right: window.innerWidth, top: 0, bottom: window.innerHeight };
                const rtl = window.getComputedStyle(document.documentElement).direction === 'rtl';
                let totalArea = 0;
                let visibleArea = 0;
                let forwardArea = 0;
                let backwardArea = 0;
                for (const rect of rects) {
                    const area = rect.width * rect.height;
                    totalArea += area;
                    const overlapWidth = Math.max(0, Math.min(rect.right, viewport.right) - Math.max(rect.left, viewport.left));
                    const overlapHeight = Math.max(0, Math.min(rect.bottom, viewport.bottom) - Math.max(rect.top, viewport.top));
                    visibleArea += overlapWidth * overlapHeight;
                    if (overlapHeight <= 0) continue;
                    const forwardWidth = rtl
                        ? Math.max(0, Math.min(rect.width, viewport.left - rect.left))
                        : Math.max(0, Math.min(rect.width, rect.right - viewport.right));
                    const backwardWidth = rtl
                        ? Math.max(0, Math.min(rect.width, rect.right - viewport.right))
                        : Math.max(0, Math.min(rect.width, viewport.left - rect.left));
                    forwardArea += forwardWidth * overlapHeight;
                    backwardArea += backwardWidth * overlapHeight;
                }
                if (!totalArea || !visibleArea) return null;
                const visibleRatio = visibleArea / totalArea;
                if (visibleRatio >= 0.98) return null;
                const forwardRatio = forwardArea / totalArea;
                const backwardRatio = backwardArea / totalArea;
                const progressionRatio = rtl ? backwardRatio : forwardRatio;
                const oppositeRatio = rtl ? forwardRatio : backwardRatio;
                if (progressionRatio < 0.1 || progressionRatio <= oppositeRatio) return null;
                return JSON.stringify({ visibleRatio: visibleRatio, offScreenRatio: progressionRatio });
            })();
        """.trimIndent()
        val decoded = decodeJavaScriptStringResult(nav.evaluateJavascript(script)) ?: return null
        val json = runCatching { org.json.JSONObject(decoded) }.getOrNull() ?: return null
        return ReadAlongFragmentSplit(
            visibleRatio = json.optDouble("visibleRatio", 1.0).coerceIn(0.0, 1.0),
            offScreenRatio = json.optDouble("offScreenRatio", 0.0).coerceIn(0.0, 1.0),
        )
    }

    private suspend fun scrollReadAlongFragmentIntoView(fragmentId: String, nav: EpubNavigatorFragment) {
        val safeId = fragmentId.replace("\\", "\\\\").replace("'", "\\'")
        val script = """
            (function() {
                const el = document.getElementById('$safeId');
                if (!el) return false;
                el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                return true;
            })();
        """.trimIndent()
        nav.evaluateJavascript(script)
    }

    private fun parsePublicationHref(href: String?): Url? {
        if (href.isNullOrBlank()) return null
        return Url(href) ?: Url.fromDecodedPath(href)
    }

    private fun decodeJavaScriptStringResult(result: String?): String? {
        if (result.isNullOrBlank() || result == "null") return null
        return runCatching {
            org.json.JSONArray("[$result]").optString(0)
        }.getOrNull()?.takeIf { it.isNotBlank() }
    }

    private fun normalizePublicationHref(href: String?): String? =
        parsePublicationHref(href)?.normalize()?.removeFragment()?.toString()

    fun preserveReadiumPositionAcross(viewportChange: () -> Unit) {
        val nav = navigator
        if (nav == null || engineNavigator != null || !readiumRestoreConfirmed || _state.value.readAlongPlaying) {
            viewportChange()
            return
        }
        viewportReanchorJob?.cancel()
        viewportReanchorJob = viewModelScope.launch {
            val reused = viewportAnchor?.takeIf { it.page == null || it.page == nav.currentLocator.value.pageKey() }
            val anchor = reused?.locator ?: firstVisibleTextLocator(nav)
            if (anchor == null) {
                viewportAnchor = null
                viewportChange()
                return@launch
            }
            viewportAnchor = ViewportAnchor(anchor, page = null)
            viewportChange()
            delay(VIEWPORT_SETTLE_MS)
            if (nav.currentLocator.value.href != anchor.href) {
                viewportAnchor = null
                return@launch
            }
            nav.go(anchor, animated = false)
            delay(VIEWPORT_SETTLE_MS)
            viewportAnchor = ViewportAnchor(anchor, page = nav.currentLocator.value.pageKey())
        }
    }

    private fun Locator.pageKey(): String = "$href|${locations.progression}"

    private suspend fun firstVisibleTextLocator(nav: EpubNavigatorFragment): Locator? {
        val current = nav.currentLocator.value
        val expectedPath = org.json.JSONObject.quote(current.href.toString())
        val script = """
            (function() {
                if (!decodeURIComponent(window.location.pathname).endsWith(decodeURIComponent($expectedPath))) return null;
                const visible = (r) => r.width > 0 && r.height > 0 && r.right > 0 && r.left < window.innerWidth && r.bottom > 0 && r.top < window.innerHeight;
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                const range = document.createRange();
                for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                    const text = node.textContent;
                    if (!text.trim()) continue;
                    range.selectNodeContents(node);
                    if (!Array.from(range.getClientRects()).some(visible)) continue;
                    for (let i = 0; i < text.length; i++) {
                        if (!text[i].trim()) continue;
                        range.setStart(node, i);
                        range.setEnd(node, i + 1);
                        if (Array.from(range.getClientRects()).some(visible)) {
                            return { before: text.slice(Math.max(0, i - 64), i), highlight: text.slice(i, i + 64) };
                        }
                    }
                }
                return null;
            })();
        """.trimIndent()
        val json = nav.evaluateJavascript(script)
            ?.let { runCatching { org.json.JSONObject(it) }.getOrNull() }
            ?: return null
        return current.copy(
            locations = current.locations.copy(otherLocations = emptyMap()),
            text = Locator.Text(
                before = json.optString("before").ifEmpty { null },
                highlight = json.optString("highlight"),
            ),
        )
    }

    fun noteReadiumUserInteraction() {
        if (navigator != null && engineNavigator == null) readiumUserInteractionPending = true
    }

    fun pageForward() {
        engineNavigator?.let {
            it.goForward()
            return
        }
        viewModelScope.launch {
            navigator?.let {
                readiumUserInteractionPending = true
                if (!it.goForward()) readiumUserInteractionPending = false
            }
        }
    }

    fun pageBackward() {
        engineNavigator?.let {
            it.goBackward()
            return
        }
        viewModelScope.launch {
            navigator?.let {
                readiumUserInteractionPending = true
                if (!it.goBackward()) readiumUserInteractionPending = false
            }
        }
    }

    fun seekToProgress(fraction: Float) {
        val f = fraction.coerceIn(0f, 1f)
        engineNavigator?.let {
            it.goToProgress(f)
            return
        }
        viewModelScope.launch {
            if (positions.isNotEmpty()) {
                val idx = (f * positions.size).toInt().coerceIn(0, positions.size - 1)
                navigator?.let {
                    readiumUserInteractionPending = true
                    if (!it.go(positions[idx])) readiumUserInteractionPending = false
                }
            } else {

                val pub = publication ?: return@launch
                val order = pub.readingOrder
                if (order.isEmpty()) return@launch
                val linkIdx = (f * order.size).toInt().coerceIn(0, order.size - 1)
                navigator?.let {
                    readiumUserInteractionPending = true
                    if (!it.go(order[linkIdx])) readiumUserInteractionPending = false
                }
            }
        }
    }

    fun clearSelection() {
        engineNavigator?.clearSelection()
        navigator?.clearSelection()
        clearSelectionState()
    }

    private fun clearSelectionState() {
        _state.update {
            it.copy(
                pendingSelection = null,
                selectionText = "",
                showSelectionPopup = false,
            )
        }
    }

    fun addAnnotation(
        locator: Locator,
        style: AnnotationStyle,
        colorHex: String,
        note: String,
        selectedText: String,
    ) {
        viewModelScope.launch {
            val kind = if (selectedText.isBlank() && note.isNotBlank()) AnnotationKind.NOTE
                       else AnnotationKind.HIGHLIGHT
            annotationRepo.create(
                bookId = bookId,
                kind = kind,
                media = AnnotationMedia.EPUB,
                style = style,
                colorHex = colorHex,
                locatorJson = locator.toJSON().toString(),
                selectedText = selectedText,
                note = note,
                chapterId = state.value.currentSection.takeIf { it.isNotBlank() },
                anchors = LocatorAnchors.fromReadium(locator),
                providerSource = bookSource.name.lowercase(),
            )
            clearSelection()
        }
    }

    fun saveToVocab() {
        val locator = state.value.pendingSelection ?: return
        val word = state.value.selectionText.trim()
        if (word.isBlank()) return
        viewModelScope.launch {
            val before = locator.text.before.orEmpty()
            val after = locator.text.after.orEmpty()
            val sentence = com.enve.core.data.vocab.SentenceExtractor
                .enclosingSentence(before, word, after)
            val position = locator.locations.totalProgression
                ?: locator.locations.progression
                ?: 0.0
            val entry = vocabRepo.create(
                bookStableId = bookId,
                word = word,
                sentence = sentence,
                sentenceBefore = before,
                sentenceAfter = after,
                locator = locator.toJSON().toString(),
                position = position,
                chapterTitle = state.value.currentSection.takeIf { it.isNotBlank() },
                sourceLanguage = null,
                definitionSnapshot = null,
            )
            clearSelection()

            launch {
                try {
                    val definition = definitionLookup.definition(word)
                    if (!definition.isNullOrBlank()) {
                        vocabRepo.updateDefinition(entry.id, definition)
                    }
                } catch (e: kotlinx.coroutines.CancellationException) {
                    throw e
                } catch (_: Exception) {

                }
            }
        }
    }

    fun updateAnnotation(a: ReaderAnnotation, style: AnnotationStyle, colorHex: String, note: String) {
        viewModelScope.launch {
            annotationRepo.update(a, style = style, colorHex = colorHex, note = note)
        }
    }

    fun updateAnnotation(
        a: ReaderAnnotation,
        style: AnnotationStyle,
        colorHex: String,
        note: String,
        tags: List<String>,
    ) {
        viewModelScope.launch {
            annotationRepo.update(a, style = style, colorHex = colorHex, note = note, tags = tags)
        }
    }

    fun deleteAnnotation(a: ReaderAnnotation) {
        viewModelScope.launch { annotationRepo.delete(a.id) }
        _state.update { it.copy(undoableDelete = a) }
    }

    fun showDecorationPopover(annotationId: String) {
        val a = _state.value.annotations.firstOrNull { it.id == annotationId }
            ?: _state.value.bookmarks.firstOrNull { it.id == annotationId }
            ?: return
        _state.update { it.copy(activeDecorationAnnotation = a, showChrome = true) }
    }

    fun hideDecorationPopover() {
        _state.update { it.copy(activeDecorationAnnotation = null) }
    }

    fun addBookmark(note: String = ""): Boolean {
        val locator = engineNavigator?.currentLocator
            ?: navigator?.currentLocator?.value
            ?: return false
        viewModelScope.launch {
            annotationRepo.create(
                bookId = bookId,
                kind = AnnotationKind.BOOKMARK,
                media = AnnotationMedia.EPUB,
                style = AnnotationStyle.NONE,
                locatorJson = locator.toJSON().toString(),
                selectedText = state.value.currentSection,
                note = note,
                chapterId = state.value.currentSection.takeIf { it.isNotBlank() },
                anchors = LocatorAnchors.fromReadium(locator),
                providerSource = bookSource.name.lowercase(),
            )
        }
        return true
    }

    fun addStandaloneNote() {
        val locator = engineNavigator?.currentLocator
            ?: navigator?.currentLocator?.value
            ?: return
        viewModelScope.launch {
            val row = annotationRepo.create(
                bookId = bookId,
                kind = AnnotationKind.NOTE,
                media = AnnotationMedia.EPUB,
                style = AnnotationStyle.NONE,
                locatorJson = locator.toJSON().toString(),
                selectedText = "",
                note = "",
                chapterId = state.value.currentSection.takeIf { it.isNotBlank() },
                anchors = LocatorAnchors.fromReadium(locator),
                providerSource = bookSource.name.lowercase(),
            )
            _state.update { it.copy(activeDecorationAnnotation = row, showChrome = true) }
        }
    }

    suspend fun cachedReaderProgress(): CachedReaderProgress? {
        val dao = db?.bookCacheDao() ?: return null
        val cached = dao.getByIdAndConnection(bookId, bookConnectionId) ?: return null
        val progress = cached.epubProgress ?: cached.readProgress
        return CachedReaderProgress(
            progress = progress,
            locator = cached.epubLocator,
            currentTimeSec = cached.currentTime,
        )
    }

    fun currentReadingProgress(): Double {
        val locatorProgress = lastLocator?.locations?.totalProgression
            ?: engineNavigator?.currentLocator?.locations?.totalProgression
            ?: navigator?.currentLocator?.value?.locations?.totalProgression
        return locatorProgress
            ?: (_state.value.progressPct.toDouble() / 100.0)
    }

    fun seekToAnnotation(a: ReaderAnnotation) {
        engineNavigator?.let { engine ->
            viewModelScope.launch {
                val saved = a.locatorJson
                    ?.let { runCatching { Locator.fromJSON(org.json.JSONObject(it)) }.getOrNull() }
                val href = saved?.href?.toString()
                    ?: a.locatorJson?.let { EpubBridgeCheckpointCodec.href(it) }
                    ?.takeIf { it.isNotBlank() }
                val cfi = a.cfi
                    ?.let { if (it.startsWith("epubcfi(")) it else "epubcfi($it)" }
                if (href != null && cfi != null) {
                    val locator = Locator(
                        href = Url(href) ?: return@launch,
                        mediaType = MediaType.XHTML,
                        locations = Locator.Locations(
                            progression = a.progression,
                            totalProgression = a.totalProgression,
                            otherLocations = buildMap {
                                put("cfi", cfi)
                                a.cssSelector?.let { put("cssSelector", it) }
                            },
                        ),
                    )
                    engine.goToLocator(locator)
                } else if (cfi != null) {
                    engine.goToCfi(cfi)
                } else if (saved != null) {
                    engine.goToLocator(saved)
                }
            }
            return
        }
        val nav = navigator ?: return
        viewModelScope.launch {
            readiumUserInteractionPending = true

            a.locatorJson?.takeIf { it.isNotBlank() }?.let { json ->
                runCatching { Locator.fromJSON(org.json.JSONObject(json)) }
                    .getOrNull()?.let { if (nav.go(it)) return@launch }
            }

            val href = a.locatorJson?.let { json ->
                runCatching { org.json.JSONObject(json).optString("href") }
                    .getOrNull()
                    ?.takeIf { it.isNotBlank() }
                    ?.let { Url(it) }
            }

            if (href != null && !a.cfi.isNullOrBlank()) {
                runCatching {
                    Locator(
                        href = href,
                        mediaType = MediaType.XHTML,
                        locations = Locator.Locations(
                            fragments = listOf("epubcfi(${a.cfi})"),
                            progression = a.progression,
                            totalProgression = a.totalProgression,
                        ),
                    )
                }.getOrNull()?.let { loc ->
                    if (nav.go(loc)) { Log.d(TAG, "seek: CFI fallback hit for ${a.id}"); return@launch }
                }
            }

            if (href != null && (a.cssSelector != null || a.progression != null)) {
                runCatching {
                    Locator(
                        href = href,
                        mediaType = MediaType.XHTML,
                        locations = Locator.Locations(
                            progression = a.progression,
                            totalProgression = a.totalProgression,
                            otherLocations = a.cssSelector?.let { mapOf("cssSelector" to it) } ?: emptyMap(),
                        ),
                    )
                }.getOrNull()?.let { loc ->
                    if (nav.go(loc)) { Log.d(TAG, "seek: CSS+progression fallback hit for ${a.id}"); return@launch }
                }
            }
            readiumUserInteractionPending = false
            Log.w(TAG, "seekToAnnotation: all fallbacks failed for ${a.id}")
        }
    }

    private fun applyDecorations() {
        val einkActive = einkManager.einkActive
        val theme = _state.value.prefs.theme
        engineNavigator?.let {
            val annotations = if (!einkActive) {
                _state.value.annotations
            } else {
                _state.value.annotations.map { annotation ->
                    annotation.copy(
                        colorHex = annotationRenderColorHex(annotation.colorHex, einkActive, theme),
                    )
                }
            }
            it.applyAnnotations(annotations)
            return
        }
        val nav = navigator as? DecorableNavigator ?: return
        val decorations = _state.value.annotations.mapNotNull { a ->
            val locJson = a.locatorJson ?: return@mapNotNull null

            if (AnnotationKind.parse(a.kind) != AnnotationKind.HIGHLIGHT) return@mapNotNull null
            val locator = try { Locator.fromJSON(org.json.JSONObject(locJson)) }
                          catch (_: Exception) { null } ?: return@mapNotNull null
            val tint = parseHexColor(annotationRenderColorHex(a.colorHex, einkActive, theme))?.toArgb() ?: Color.YELLOW
            val style: Decoration.Style = when (AnnotationStyle.parse(a.style)) {
                AnnotationStyle.HIGHLIGHT     -> Decoration.Style.Highlight(tint = tint, isActive = false)
                AnnotationStyle.UNDERLINE     -> Decoration.Style.Underline(tint = tint, isActive = false)
                AnnotationStyle.STRIKETHROUGH -> com.enve.app.readium.StrikethroughStyle(tint = tint)
                AnnotationStyle.SQUIGGLY      -> com.enve.app.readium.SquigglyStyle(tint = tint)
                AnnotationStyle.NONE          -> return@mapNotNull null
            }
            Decoration(id = a.id, locator = locator, style = style)
        }
        viewModelScope.launch {
            nav.applyDecorations(decorations, "annotations")
        }
    }

    private var pendingConflictResolver: kotlinx.coroutines.CompletableDeferred<ProgressConflictChoice>? = null

    suspend fun awaitProgressConflictChoice(prompt: ProgressConflictPrompt): ProgressConflictChoice {
        val deferred = kotlinx.coroutines.CompletableDeferred<ProgressConflictChoice>()
        pendingConflictResolver = deferred
        _state.update { it.copy(pendingProgressConflict = prompt) }
        return try {
            deferred.await()
        } finally {
            pendingConflictResolver = null
            _state.update { it.copy(pendingProgressConflict = null) }
        }
    }

    fun resolveProgressConflict(choice: ProgressConflictChoice) {
        pendingConflictResolver?.complete(choice)
    }

    private val progressPushMutex = Mutex()

    private suspend fun runProgressPush(push: suspend () -> Unit) {
        progressPushMutex.withLock { withContext(NonCancellable) { push() } }
    }

    private val progressPushWindow = ProgressPushWindow(PROGRESS_PUSH_DEBOUNCE_MS, PROGRESS_PUSH_MAX_WAIT_MS)

    private fun scheduleProgressPush(push: suspend () -> Unit) {
        val waitMs = progressPushWindow.delayMs(android.os.SystemClock.elapsedRealtime())
        syncJob?.cancel()
        syncJob = viewModelScope.launch {
            delay(waitMs)
            progressPushWindow.reset()
            runProgressPush(push)
        }
    }

    private fun cancelScheduledProgressPush() {
        syncJob?.cancel()
        progressPushWindow.reset()
    }

    private fun scheduleSync(locator: Locator) = scheduleProgressPush { pushProgress(locator) }

    private fun scheduleFoliateSync() = scheduleProgressPush { persistFoliateCheckpoint() }

    private fun scheduleReadiumCheckpointSync(nav: EpubNavigatorFragment) =
        scheduleProgressPush { persistCurrentReadiumCheckpoint(nav) }

    fun flushProgress() {
        if (_state.value.readAlongActive) {
            submitCurrentReadAloudCheckpoint()
            val locator = latestReadAloudLocator ?: return
            applicationScope.launch(Dispatchers.Main.immediate) {
                readAloudCheckpoints.flush(bookId, bookSource, bookConnectionId)
                runProgressPush { pushProgress(locator) }
            }
            return
        }
        if (engineNavigator != null) {
            if (foliateRestoreConfirmed && foliateCheckpointSync.hasPending) {
                cancelScheduledProgressPush()
                syncJob = viewModelScope.launch(start = CoroutineStart.UNDISPATCHED) {
                    runProgressPush { persistFoliateCheckpoint() }
                }
            }
            return
        }
        val nav = navigator ?: return
        cancelScheduledProgressPush()
        applicationScope.launch(Dispatchers.Main.immediate) {
            runProgressPush {
                if (
                    readiumRestoreConfirmed &&
                    readiumCheckpointDirty &&
                    epubCheckpointLease != null
                ) {
                    persistCurrentReadiumCheckpoint(nav)
                } else if (epubCheckpointLease == null) {
                    pushProgress(nav.currentLocator.value)
                }
            }
        }
    }

    private var lastPushedPct: Float = -1f
    private var lastPushedLocatorJson: String? = null

    private suspend fun persistFoliateCheckpoint() {
        if (!foliateRestoreConfirmed || !foliateCheckpointSync.hasPending) return
        val lease = epubCheckpointLease ?: return
        foliateCheckpointSync.flush(
            commit = { epubBridgeCheckpoints.commit(lease, it) },
            onCommitted = { checkpoint, committed ->
                latestEpubCheckpoint = if (latestEpubCheckpoint === checkpoint) committed
                else latestEpubCheckpoint?.copy(revision = committed.revision)
            },
            push = ::pushCanonicalProgress,
        )
    }

    private suspend fun persistReadiumCheckpoint(
        locator: Locator,
        checkpoint: EpubBridgeCheckpoint,
    ) {
        val lease = epubCheckpointLease ?: return
        val committed = epubBridgeCheckpoints.commit(lease, checkpoint) ?: return
        latestEpubCheckpoint = committed
        readiumCheckpointFingerprint = checkpointFingerprint(committed)
        readiumCheckpointDirty = false
        pushProgress(
            locator = locator,
            locatorJsonOverride = EpubBridgeCheckpointCodec.encode(committed),
        )
    }

    private suspend fun persistCurrentReadiumCheckpoint(nav: EpubNavigatorFragment) {
        if (!readiumRestoreConfirmed || !readiumCheckpointDirty) return
        val capture = captureReadiumCheckpoint(nav) ?: return
        val fingerprint = checkpointFingerprint(capture.checkpoint)
        if (fingerprint == readiumCheckpointFingerprint) {
            readiumCheckpointDirty = false
            return
        }
        persistReadiumCheckpoint(capture.locator, capture.checkpoint)
    }

    private var progressPushesHeld = false

    fun holdProgressPushes() {
        progressPushesHeld = true
    }

    private suspend fun pushCanonicalProgress(checkpoint: EpubBridgeCheckpoint): Result<Unit> {
        val pct = checkpoint.totalProgression?.toFloat()?.coerceIn(0f, 1f)
            ?: return Result.failure(IllegalArgumentException("Missing reading progress"))
        if (progressPushesHeld) return Result.success(Unit)
        val encoded = EpubBridgeCheckpointCodec.encode(checkpoint)
        val book = Book(
            id = bookId,
            title = bookTitle.ifBlank { bookId },
            source = bookSource,
            mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
            connectionId = bookConnectionId,
        )
        applicationScope.launch {
            runSuspendCatching { koreaderHub.pushIfConfigured(book, pct, encoded) }
        }
        return aggregatorRepository.syncEbookProgress(
            bookId = bookId,
            source = bookSource,
            percentage = pct,
            locator = encoded,
            page = _state.value.currentPage.takeIf { it > 0 },
            pageCount = _state.value.totalPages.takeIf { it > 0 },
            connectionId = bookConnectionId,
        ).onSuccess {
            rewindTracker.recordOutboundWrite(
                key = RemoteProgressWriteKey.of(book),
                percentage = pct,
                positionMs = null,
                locatorJson = encoded,
            )
        }
    }

    private suspend fun pushProgress(
        locator: Locator,
        locatorJsonOverride: String? = null,
    ) {
        val readAlongActive = _state.value.readAlongActive
        val effectiveLocator = if (readAlongActive) latestReadAloudLocator ?: return else locator
        val pct = if (readAlongActive) {
            effectiveLocator.locations.totalProgression?.toFloat() ?: return
        } else {
            effectiveLocator.locations.totalProgression?.toFloat() ?: 0f
        }
        val json = locatorJsonOverride ?: effectiveLocator.toJSONOrNull()
        val tracksUnleasedPosition = !readAlongActive && epubCheckpointLease == null
        if (tracksUnleasedPosition && unleasedReadiumPosition.isUnchanged(json)) return

        val isLikelyInitialEmit = pct < 0.005f && lastPushedPct < 0f
        if (readAlongActive) {
            readAloudCheckpoints.flush(bookId, bookSource, bookConnectionId)
        } else if (!isLikelyInitialEmit) {
            runCatching {
                db?.bookCacheDao()?.updateUnifiedProgress(
                    bookId = bookId,
                    connectionId = bookConnectionId,
                    progress = pct,
                    currentTimeSec = -1L,
                    locatorJson = json,
                    nowMs = System.currentTimeMillis(),
                )
            }
            if (tracksUnleasedPosition) unleasedReadiumPosition.confirm(json)
        }

        if (pct < 0.005f || progressPushesHeld) return
        val narratedSentenceMoved = readAlongActive && json != lastPushedLocatorJson
        if (kotlin.math.abs(pct - lastPushedPct) < 0.001f && !narratedSentenceMoved) return
        lastPushedPct = pct
        lastPushedLocatorJson = json

        applicationScope.launch {
            try {
                val book = com.enve.core.data.model.Book(
                    id = bookId,
                    title = bookId,
                    source = bookSource,
                    mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
                    connectionId = bookConnectionId,
                )
                koreaderHub.pushIfConfigured(book, pct, json)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }

        if (bookConnectionId != null || bookSource != BookSource.GRIMMORY) {
            aggregatorRepository.syncEbookProgress(
                bookId = bookId,
                source = bookSource,
                percentage = pct,
                locator = json,
                page = _state.value.currentPage.takeIf { it > 0 },
                pageCount = _state.value.totalPages.takeIf { it > 0 },
                connectionId = bookConnectionId,
            ).onSuccess {
                rewindTracker.recordOutboundWrite(
                    key = RemoteProgressWriteKey.of(Book(
                        id = bookId,
                        title = bookTitle.ifBlank { bookId },
                        source = bookSource,
                        mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
                        connectionId = bookConnectionId,
                    )),
                    percentage = pct,
                    positionMs = null,
                    locatorJson = json,
                )
            }
            return
        }

        try {
            syncManager.pushEbookProgress(
                bookId = bookId,
                percentage = pct,
                cfi = json,
            )
        } catch (_: Exception) {
            try {
                repository.syncEbookProgress(bookId, pct, json)
            } catch (_: Exception) {}
        }
    }

    private fun loadLayoutPresets() {
        viewModelScope.launch {
            db?.layoutPresetDao()?.flowAll()?.collect { presets ->
                _state.update { it.copy(layoutPresets = presets) }
            }
        }
    }

    override fun onCleared() {
        submitCurrentReadAloudCheckpoint()
        narrationStore.clearNarration(bookId)
        super.onCleared()
        savePrefsJob?.cancel()
        syncJob?.cancel()
        readiumRestoreJob?.cancel()
        autoScrollJob?.cancel()
        readAlongSyncJob?.cancel()
        readAlongStartJob?.cancel()
        readAlongClipUiJob?.cancel()
        engineNavigator?.close()
        engineNavigator = null
        mediaOverlayEngine?.release()
        ttsEngine?.stop()
        ttsEngine?.shutdown()

        val pubToClose = publication
        publication = null
        if (pubToClose != null) {
            applicationScope.launch(Dispatchers.IO) {
                runCatching { pubToClose.close() }
            }
        }
        closeReadingSession()
    }

    private var sessionStartedAtMs: Long? = null
    private var sessionResumedAtMs: Long? = null
    private var sessionAccumulatedMs: Long = 0
    private var sessionStartProgress: Float? = null

    private fun startReadingSession() {
        if (sessionStartedAtMs != null) return
        val now = System.currentTimeMillis()
        sessionStartedAtMs = now
        sessionResumedAtMs = now
        sessionAccumulatedMs = 0
        sessionStartProgress = null
    }

    fun pauseReadingSession() {
        val resumed = sessionResumedAtMs ?: return
        val now = System.currentTimeMillis()
        if (now > resumed) sessionAccumulatedMs += now - resumed
        sessionResumedAtMs = null
    }

    fun resumeReadingSession() {
        if (sessionStartedAtMs == null) return
        if (sessionResumedAtMs != null) return
        sessionResumedAtMs = System.currentTimeMillis()
    }

    private fun closeReadingSession() {
        val startedAt = sessionStartedAtMs ?: return
        pauseReadingSession()
        val durationMs = sessionAccumulatedMs
        val endAt = System.currentTimeMillis()
        sessionStartedAtMs = null
        sessionResumedAtMs = null
        sessionAccumulatedMs = 0

        if (durationMs < 5_000L) return
        val capturedBookId = bookId
        val capturedSource = bookSource
        val capturedConnectionId = bookConnectionId
        val startProgress = sessionStartProgress
        val endProgress = currentReadingProgress().toFloat()
        val totalPages = _state.value.totalPages
        val pagesRead = startProgress?.let { start ->
            val delta = endProgress - start
            if (totalPages > 0 && delta > 0f) {
                (delta * totalPages).roundToInt().coerceAtLeast(1)
            } else {
                null
            }
        }
        sessionStartProgress = null
        applicationScope.launch(Dispatchers.IO) {
            val historySession = HistorySession(
                id = UUID.randomUUID().toString(),
                bookId = capturedBookId,
                bookKey = "${capturedConnectionId ?: capturedSource.name}:$capturedBookId",
                connectionId = capturedConnectionId,
                source = capturedSource,
                mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
                startTimeMs = startedAt,
                endTimeMs = endAt,
                activeDurationSeconds = durationMs / 1_000L,
                startProgress = startProgress,
                endProgress = endProgress,
                pagesRead = pagesRead,
            )
            history.append(historySession)
            try {
                when (capturedSource) {
                    BookSource.GRIMMORY -> {
                        val block: suspend () -> Unit = {
                            repository.createReadingSession(
                                bookId = capturedBookId,
                                startTime = java.time.Instant.ofEpochMilli(startedAt),
                                endTime = java.time.Instant.ofEpochMilli(endAt),
                                durationMs = durationMs,
                                mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
                                startProgress = startProgress,
                                endProgress = endProgress,
                                endLocation = _state.value.currentPage.takeIf { it > 0 }?.toString(),
                            ).getOrThrow()
                        }
                        if (capturedConnectionId == null) {
                            block()
                        } else {
                            withContext(
                                com.enve.core.data.remote.ConnectionScope.asContextElement(capturedConnectionId),
                            ) { block() }
                        }
                    }
                    BookSource.BOOKORBIT -> {
                        val block: suspend () -> Unit = {
                            bookOrbitHistorySync.submit(
                                book = Book(
                                    id = capturedBookId,
                                    title = bookTitle,
                                    source = capturedSource,
                                    mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
                                    connectionId = capturedConnectionId,
                                ),
                                session = historySession,
                            )
                        }
                        if (capturedConnectionId == null) {
                            block()
                        } else {
                            withContext(
                                com.enve.core.data.remote.ConnectionScope.asContextElement(capturedConnectionId),
                            ) { block() }
                        }
                    }
                    else -> Unit
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }
}
