package com.enve.app.viewmodel

import com.enve.core.reader.ReadAloudHighlightStyle
import android.graphics.Color
import com.enve.core.reader.highlightColorHex
import androidx.compose.ui.graphics.toArgb
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.readium.MediaOverlayEngine
import com.enve.app.readium.EbookTTSParagraph
import com.enve.app.readium.EbookTTSService
import com.enve.app.readium.EbookTTSState
import com.enve.app.readium.ReadiumManager
import com.enve.app.hearth.HearthPreferencesStore
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
import com.enve.core.reader.EpubCfi
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
import org.readium.r2.shared.publication.services.content.Content
import org.readium.r2.shared.publication.services.content.content
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

data class TocPageCount(val pages: Int, val estimated: Boolean)

private data class TocPageBoundary(
    val position: Double,
    val containingPage: Int,
    val pagesBefore: Int,
    val exactStart: Boolean,
    val exactEnd: Boolean,
)

private data class ReadAlongFragmentSplit(
    val visibleRatio: Double,
    val offScreenRatio: Double,
)

private data class EpubPageMarker(
    val label: String,
    val progression: Double,
)

data class ReaderTTSVoice(val name: String, val label: String)

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
    val tocPageCounts: Map<String, TocPageCount> = emptyMap(),
    val progressPct: Int               = 0,
    val minutesLeftInBook: Int? = null,
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
    val ttsPlayback: EbookTTSState = EbookTTSState(),
    val ttsReady: Boolean = false,
    val ttsVoices: List<ReaderTTSVoice> = emptyList(),
    val ttsVoice: String? = null,
    val showTtsSheet: Boolean = false,
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
    val linkReturnLocator: Locator? = null,
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
    val updatedAt: Long = 0L,
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

internal fun isReadAloudOnlyPreferenceChange(old: ReaderPreferences, new: ReaderPreferences): Boolean =
    new == old.copy(
        readAloudSpeed = new.readAloudSpeed,
        readAloudSyncOffsetMs = new.readAloudSyncOffsetMs,
        readAloudAutoTurn = new.readAloudAutoTurn,
        readAloudSkipOnPageTurn = new.readAloudSkipOnPageTurn,
        readAloudHighlight = new.readAloudHighlight,
        readAloudHighlightStyle = new.readAloudHighlightStyle,
        readAloudHighlightHex = new.readAloudHighlightHex,
        readAloudSkipAsides = new.readAloudSkipAsides,
        ttsSpeed = new.ttsSpeed,
    )

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
    database: ReaderDatabase,
    private val readium: ReadiumManager,
    private val hearthPreferences: HearthPreferencesStore,
    private val hardcoverSync: com.enve.app.data.hardcover.HardcoverSyncService,
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

    private val db: ReaderDatabase? = database
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
    internal var readiumUserNavigationGeneration = 0L
        private set
    private var readiumUserInteractionPending = false
        set(value) {
            if (value) {
                readiumUserNavigationGeneration += 1L
                heldReadingPosition.invalidate()
                readiumLayoutGeneration++
                readiumLayouts.clear()
                viewportReanchorJob?.cancel()
            }
            field = value
        }
    private val unleasedReadiumPosition = ReaderPositionBaseline()
    private val heldReadingPosition = HeldReadingPosition()
    private var readiumCaptureJob: Job? = null
    private var readiumScrollEndCaptureJob: Job? = null
    private var readiumScrollCaptureJob: Job? = null
    private var readiumLocatorJob: Job? = null
    private val readingSpeedTracker = com.enve.core.reader.ReadingSpeedTracker()
    private var readiumRestoreJob: Job? = null
    private var viewportAnchor: ViewportAnchor? = null
    private var viewportReanchorJob: Job? = null
    private var readiumLayoutGeneration = 0L
    private val readiumLayouts = mutableSetOf<Long>()
    private val readiumLayoutInProgress get() = readiumLayouts.isNotEmpty()
    private var textSelectionActive = false
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
    private var tocPageCountsJob: Job? = null
    private var foliateTocProgressions: List<Double?> = emptyList()

    private var lastLocator: Locator? = null

    private var _chromeInteraction = MutableStateFlow(0L)
    val chromeInteraction = _chromeInteraction.asStateFlow()

    private var autoScrollJob: Job? = null

    private var einkBoldObserverJob: Job? = null

    private var ttsEngine: android.speech.tts.TextToSpeech? = null
    private var ttsBookFile: java.io.File? = null
    private var ttsPublication: Publication? = null
    private var ttsUnavailableReason = "Text-to-speech is still starting. Try again in a moment."
    private val ttsAudioManager = appContext.getSystemService(android.media.AudioManager::class.java)
    private val ttsAudioFocus: android.media.AudioFocusRequest = android.media.AudioFocusRequest.Builder(android.media.AudioManager.AUDIOFOCUS_GAIN)
        .setAudioAttributes(android.media.AudioAttributes.Builder()
            .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
            .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH).build())
        .setWillPauseWhenDucked(true)
        .setOnAudioFocusChangeListener { change ->
            if (change != android.media.AudioManager.AUDIOFOCUS_GAIN) {
                viewModelScope.launch { ttsPlayback.pause() }
            }
        }.build()
    private val ttsPlayback: EbookTTSService = EbookTTSService(
        scope = viewModelScope,
        speak = { text, id ->
            ttsAudioManager.requestAudioFocus(ttsAudioFocus) == android.media.AudioManager.AUDIOFOCUS_REQUEST_GRANTED &&
                ttsEngine?.speak(text, android.speech.tts.TextToSpeech.QUEUE_FLUSH, null, id) ==
                android.speech.tts.TextToSpeech.SUCCESS
        },
        stopSpeech = {
            ttsEngine?.stop()
            ttsAudioManager.abandonAudioFocusRequest(ttsAudioFocus)
        },
        onNavigate = { locator ->
            engineNavigator?.goToLocator(locator) ?: viewModelScope.launch { navigator?.go(locator, animated = false) }
        },
        onFailure = ::postTransientMessage,
    )
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
        readingSpeedTracker.pause()
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
        viewModelScope.launch {
            ttsPlayback.state.collect { playback ->
                _state.update { it.copy(ttsPlayback = playback) }
            }
        }
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
        readiumEpubFile: java.io.File? = null,
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
        )?.let { checkpoint ->
            if (resource.format.equals("AZW3", ignoreCase = true) && checkpoint.sourceEngine == ReaderEngineKind.READIUM) {
                checkpoint.copy(
                    href = null,
                    epubCfi = null,
                    cssSelector = null,
                    domRange = null,
                    resourceProgression = null,
                    textQuote = null,
                    nativeReadiumLocatorJson = null,
                )
            } else checkpoint
        }?.copy(
            publicationSha256 = publicationSha256,
            providerFileId = resource.providerFileId,
            revision = lease.checkpoint?.revision ?: 0L,
            writerEpoch = lease.writerEpoch,
        )?.let { checkpoint ->
            if (engine == ReaderEngineKind.READIUM && readiumEpubFile != null) {
                withContext(Dispatchers.IO) { EpubCfi.withReadiumAnchor(checkpoint, readiumEpubFile) }
            } else checkpoint
        }
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
            readAloudSpeed        = prefs.readAloudSpeed.first().takeIf { it.isFinite() }?.coerceIn(0.5f, 3.0f) ?: 1.0f,
            readAloudSyncOffsetMs = prefs.readAloudSyncOffsetMs.first(),
            readAloudAutoTurn     = prefs.readAloudAutoTurn.first(),
            readAloudSkipOnPageTurn = prefs.readAloudSkipOnPageTurn.first(),
            readAloudHighlight    = prefs.readAloudHighlight.first(),
            readAloudHighlightStyle = prefs.readAloudHighlightStyle.first(),
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
        val voice = hearthPreferences.readerTtsVoice.first()
        if (voice != null) selectTtsVoice(voice, persist = false)
        ttsEngine?.setSpeechRate(_state.value.prefs.ttsSpeed)
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
        tocPageCountsJob?.cancel()
        foliateTocProgressions = emptyList()
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
                tocPageCounts = emptyMap(),
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
        foliateTocProgressions = toc.map { it.progression }
        refreshFoliateTocPageCounts()
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
        val totalPagesChanged = location.totalPages != _state.value.totalPages
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
        if (totalPagesChanged) refreshFoliateTocPageCounts()
        if (!foliateRestoreConfirmed) return
        if (!location.userInitiated) return
        if (sessionResumedAtMs != null && !_state.value.readAlongActive) {
            recordReadingPace(checkpoint.totalProgression ?: 0.0)
        }
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
        readiumLocatorJob?.cancel()
        readiumCaptureJob?.cancel()
        readiumScrollEndCaptureJob?.cancel()
        readiumScrollEndCaptureJob = null
        setReadiumScrollActive(false)
        heldReadingPosition.retire()
        readingSpeedTracker.pause()
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
        tocPageCountsJob?.cancel()
        _state.update {
            it.copy(
                totalPages = 0,
                currentPage = 0,
                hasPageList = false,
                currentPageLabel = null,
                lastPageLabel = null,
                tocPageCounts = emptyMap(),
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
        if (supportsReadAlong) {
            viewModelScope.launch(Dispatchers.IO) {
                db?.bookCacheDao()?.markReadAlongAvailable("${bookConnectionId ?: bookSource.name}:$bookId")
            }
        }
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
                refreshReadiumTocPageCounts(pub)
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
                followCurrentReadAlongClip()
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
        readiumLocatorJob = viewModelScope.launch {
            var lastBionicHref: String? = null
            nav.currentLocator.collect { locator ->
                if (readiumLayoutInProgress && !_state.value.readAlongActive) return@collect
                lastLocator = locator
                val captureGeneration = heldReadingPosition.observe(locator)
                val userMoved = readiumUserInteractionPending
                readiumCaptureJob?.cancel()
                if (!_state.value.readAlongActive && epubCheckpointLease != null) {
                    readiumCaptureJob = viewModelScope.launch {
                        captureHeldReadingPosition(nav, locator, captureGeneration, userMoved)
                    }
                }
                if (readiumUserInteractionPending && sessionResumedAtMs != null && !_state.value.readAlongActive) {
                    recordReadingPace(locator.locations.totalProgression ?: 0.0)
                }

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
                    if (_state.value.prefs.readAloudSkipOnPageTurn && viewportReanchorJob?.isActive != true) {
                        if (_state.value.readAlongPlaying && !audioIsNavigating) {
                            syncReadAlongToVisiblePage(nav, locator)
                        } else if (!_state.value.readAlongPlaying && !_state.value.readAlongPreparing) {
                            presyncReadAlongToReadingPosition(nav, locator)
                        }
                    }
                }
                val lease = epubCheckpointLease
                if (lease == null) {
                    if (readiumUserInteractionPending) {
                        scheduleSync(locator)
                    } else {
                        unleasedReadiumPosition.confirm(locator.toJSONOrNull())
                    }
                } else if (readiumUserInteractionPending) {
                    readiumRestoreJob?.cancel()
                    readiumRestoreConfirmed = true
                    readiumUserInteractionPending = false
                    readiumCheckpointDirty = true
                    scheduleReadiumCheckpointSync(nav)
                }
            }
        }
    }

    fun pauseReadingPace() = readingSpeedTracker.pause()

    private fun recordReadingPace(progression: Double) {
        readingSpeedTracker.recordPageTurn(progression, positions.size.takeIf { it > 0 } ?: _state.value.totalPages,
            android.os.SystemClock.elapsedRealtime())
        _state.update { it.copy(minutesLeftInBook = readingSpeedTracker.minutesRemaining(progression)) }
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
        val anchoredLocator = Locator.fromJSON(org.json.JSONObject(enrichedLocator)) ?: locator
        return ReadiumCheckpointCapture(anchoredLocator, checkpoint)
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
            refreshReadiumTocPageCounts(pub)
            lastLocator?.let { locator ->
                val current = findCurrentTocEntry(locator)
                _state.update { it.copy(currentTocEntryId = current?.id) }
            }
        }
    }

    private fun refreshReadiumTocPageCounts(pub: Publication) {
        if (publication !== pub || engineNavigator != null) return
        tocPageCountsJob?.cancel()
        val entries = _state.value.tocEntries
        val positions = positions
        val pageMarkers = pageMarkers
        if (entries.isEmpty() || positions.isEmpty()) return
        tocPageCountsJob = viewModelScope.launch {
            val counts = withContext(Dispatchers.Default) { readiumTocPageCounts(pub, entries, positions, pageMarkers) }
            if (publication !== pub || engineNavigator != null ||
                _state.value.tocEntries !== entries || this@ReaderViewModel.positions !== positions
            ) return@launch
            _state.update { it.copy(tocPageCounts = counts) }
        }
    }

    private suspend fun readiumTocPageCounts(
        pub: Publication,
        entries: List<TocEntry>,
        positions: List<Locator>,
        pageMarkers: List<EpubPageMarker>,
    ): Map<String, TocPageCount> {
        val resourceIndex = pub.readingOrder.withIndex().mapNotNull { (index, link) ->
            normalizePublicationHref(link.url().toString())?.let { it to index }
        }.toMap()
        val targets = entries.map { entry ->
            resourceIndex[normalizePublicationHref(entry.href)]?.let { resource ->
                resource to parsePublicationHref(entry.href)?.fragment?.takeIf(String::isNotEmpty)
            }
        }
        val fragmentFractions = HashMap<Pair<Int, String>, Double>()
        targets.mapNotNull { target -> target?.second?.let { target.first to it } }
            .groupBy({ it.first }, { it.second })
            .forEach { (resource, fragments) ->
                val html = readResourceText(pub, pub.readingOrder[resource]) ?: return@forEach
                fragments.distinct().forEach { fragment ->
                    fragmentFraction(html, fragment)?.let { fragmentFractions[resource to fragment] = it }
                }
            }
        val firstPositionOfResource = HashMap<Int, Int>()
        val positionCountOfResource = HashMap<Int, Int>()
        positions.forEachIndexed { index, locator ->
            resourceIndex[normalizePublicationHref(locator.href.toString())]?.let { resource ->
                firstPositionOfResource.putIfAbsent(resource, index)
                positionCountOfResource.merge(resource, 1, Int::plus)
            }
        }
        fun positionOf(resource: Int, fragment: String?): Double? {
            val first = firstPositionOfResource[resource] ?: return null
            val fraction = if (fragment == null) 0.0 else fragmentFractions[resource to fragment] ?: return null
            return first + fraction * positionCountOfResource.getValue(resource)
        }
        val totalPositions = positions.size.toDouble()

        val pageList = pub.pageList
        val pageResources = pageList.mapNotNull { resourceIndex[normalizePublicationHref(it.url().toString())] }
        val pageResourcesOrdered = pageResources.isNotEmpty() &&
            pageResources.size == pageList.size &&
            pageMarkers.size == pageList.size &&
            pageResources.zipWithNext().all { (previous, next) -> next >= previous }
        if (!pageResourcesOrdered) {
            return tocPageCounts(
                entries = entries,
                starts = targets.map { target -> target?.let { (resource, fragment) -> positionOf(resource, fragment) } },
                bookEnd = totalPositions,
            ) { start, end -> estimatedTocPageCount(start, end, totalPositions) }
        }

        var page = 0
        val firstPageOfResource = IntArray(pub.readingOrder.size) { resource ->
            while (page < pageResources.size && pageResources[page] < resource) page++
            page
        }
        fun progressionAt(position: Double): Double? {
            val index = position.toInt().coerceIn(0, positions.lastIndex)
            val base = positions[index].locations.totalProgression ?: return null
            val next = positions.getOrNull(index + 1)?.locations?.totalProgression ?: 1.0
            return (base + (position - index) * (next - base)).takeIf { it.isFinite() }
        }
        fun boundaryOf(resource: Int, fragment: String?): TocPageBoundary? {
            val position = positionOf(resource, fragment) ?: return null
            if (fragment == null) {
                val firstPage = firstPageOfResource[resource]
                val firstPageInResource = firstPage < pageResources.size && pageResources[firstPage] == resource
                val pageAtResourceStart = firstPageInResource && pageList[firstPage].url().fragment == null
                return TocPageBoundary(
                    position = position,
                    containingPage = if (pageAtResourceStart) firstPage else firstPage - 1,
                    pagesBefore = firstPage,
                    exactStart = pageAtResourceStart || !firstPageInResource,
                    exactEnd = true,
                )
            }
            val progression = progressionAt(position) ?: return null
            return TocPageBoundary(
                position = position,
                containingPage = pageMarkers.indexOfLast { it.progression <= progression },
                pagesBefore = pageMarkers.count { it.progression < progression },
                exactStart = false,
                exactEnd = false,
            )
        }
        return tocPageCounts(
            entries = entries,
            starts = targets.map { target -> target?.let { (resource, fragment) -> boundaryOf(resource, fragment) } },
            bookEnd = TocPageBoundary(totalPositions, pageList.lastIndex, pageList.size, exactStart = true, exactEnd = true),
        ) { start, end ->
            val pages = end.pagesBefore - start.containingPage.coerceAtLeast(0)
            TocPageCount(pages, estimated = !start.exactStart || !end.exactEnd)
                .takeIf { end.position > start.position && pages > 0 }
        }
    }

    private fun fragmentFraction(html: String, fragment: String): Double? {
        val attribute = Regex("""\s(?:id|name)\s*=\s*(["'])${Regex.escape(fragment)}\1""").find(html) ?: return null
        val tagStart = html.lastIndexOf('<', attribute.range.first)
        if (tagStart < 0) return null
        return tagStart.toDouble() / html.length
    }

    private fun refreshFoliateTocPageCounts() {
        val total = _state.value.totalPages.toDouble()
        val counts = tocPageCounts(
            entries = _state.value.tocEntries,
            starts = foliateTocProgressions.map { it?.times(total) },
            bookEnd = total,
        ) { start, end -> estimatedTocPageCount(start, end, total) }
        _state.update { it.copy(tocPageCounts = counts) }
    }

    private fun estimatedTocPageCount(start: Double, end: Double, total: Double): TocPageCount? {
        if (!start.isFinite() || !end.isFinite() || start < 0.0 || end > total || end <= start) return null
        val pages = (end - start).roundToInt()
        return TocPageCount(pages, estimated = true).takeIf { pages > 0 }
    }

    private fun <T : Any> tocPageCounts(
        entries: List<TocEntry>,
        starts: List<T?>,
        bookEnd: T,
        count: (start: T, end: T) -> TocPageCount?,
    ): Map<String, TocPageCount> {
        if (starts.size != entries.size) return emptyMap()
        val counts = HashMap<String, TocPageCount>()
        fun close(index: Int, end: T?) {
            val start = starts[index] ?: return
            if (end == null) return
            count(start, end)?.let { counts[entries[index].id] = it }
        }
        val open = ArrayDeque<Int>()
        entries.forEachIndexed { index, entry ->
            while (open.isNotEmpty() && entries[open.last()].depth >= entry.depth) {
                close(open.removeLast(), starts[index])
            }
            open.addLast(index)
        }
        while (open.isNotEmpty()) close(open.removeLast(), bookEnd)
        return counts
    }

    fun navigateTo(entry: TocEntry) {
        readingSpeedTracker.pause()
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
        setReadiumScrollActive(false)
        readingSpeedTracker.pause()
        heldReadingPosition.invalidate()
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
            if (newPrefs.readAloudAutoTurn && !newPrefs.scroll && _state.value.readAlongPlaying &&
                readAlongClipUiJob?.isActive != true
            ) {
                val clip = mediaOverlayEngine?.currentClipSnapshot()
                val nav = navigator
                if (clip != null && nav != null) {
                    readAlongClipUiJob = viewModelScope.launch { scheduleReadAlongPagePreflip(clip, nav) }
                }
            }
        }
        if (newPrefs.readAloudHighlight != oldPrefs.readAloudHighlight ||
            newPrefs.readAloudHighlightStyle != oldPrefs.readAloudHighlightStyle ||
            newPrefs.readAloudHighlightHex != oldPrefs.readAloudHighlightHex
        ) {
            refreshReadAlongHighlight()
        }
        if (!isReadAloudOnlyPreferenceChange(oldPrefs, newPrefs)) {
            val apply = {
                navigator?.submitPreferences(newPrefs.toEpubPreferences(einkBoldText = einkBoldActive, einkActive = einkSingleColumnActive))
                Unit
            }
            if (_state.value.readAlongActive) apply() else preserveReadiumPositionAcross(apply)
            engineNavigator?.applyPreferences(newPrefs)
        }

        savePrefsJob?.cancel()
        savePrefsJob = viewModelScope.launch {
            delay(150)
            persistPreferences(newPrefs)
        }

        if (newPrefs.ttsSpeed != oldPrefs.ttsSpeed) {
            ttsEngine?.setSpeechRate(newPrefs.ttsSpeed)
            ttsPlayback.restart()
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
            readAloudSkipOnPageTurn = readerPrefs.readAloudSkipOnPageTurn,
            readAloudHighlight = readerPrefs.readAloudHighlight,
            readAloudHighlightStyle = readerPrefs.readAloudHighlightStyle,
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
        ttsPlayback.pause()
        ttsEngine = engine
        ttsPlayback.setReady(engine != null)
        if (engine == null) {
            _state.update { it.copy(ttsReady = false) }
            return
        }
        engine.setSpeechRate(_state.value.prefs.ttsSpeed)
        engine.setAudioAttributes(
            android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_MEDIA)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SPEECH)
                .build(),
        )
        engine.setOnUtteranceProgressListener(object : android.speech.tts.UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                viewModelScope.launch { ttsPlayback.onStart(utteranceId) }
            }
            override fun onRangeStart(utteranceId: String?, start: Int, end: Int, frame: Int) {
                viewModelScope.launch { ttsPlayback.onRangeStart(utteranceId, start) }
            }
            override fun onDone(utteranceId: String?) {
                viewModelScope.launch { ttsPlayback.onDone(utteranceId) }
            }
            override fun onError(utteranceId: String?, errorCode: Int) {
                viewModelScope.launch { ttsPlayback.onError(utteranceId) }
            }
            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                viewModelScope.launch { ttsPlayback.onError(utteranceId) }
            }
        })
        val voices = engine.voices.orEmpty()
            .filterNot { android.speech.tts.TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED in it.features.orEmpty() }
            .sortedWith(compareBy({ it.locale.displayName }, { it.name }))
            .groupBy { it.locale }
            .flatMap { (locale, variants) ->
                variants.mapIndexed { index, voice ->
                    val variant = if (variants.size > 1) " · ${index + 1}" else ""
                    val network = if (voice.isNetworkConnectionRequired) " · Online" else ""
                    ReaderTTSVoice(voice.name, "${locale.displayName}$variant$network")
                }
            }
        _state.update { it.copy(ttsReady = true, ttsVoices = voices, ttsVoice = engine.voice?.name) }
        viewModelScope.launch {
            hearthPreferences.readerTtsVoice.first()?.let { selectTtsVoice(it, persist = false) }
        }
    }

    fun setTtsUnavailable(message: String) {
        ttsUnavailableReason = message
        ttsPlayback.pause()
        _state.update { it.copy(ttsReady = false) }
        postTransientMessage(message)
    }

    fun setTtsBookFile(file: java.io.File) {
        ttsBookFile = file
    }

    fun showTtsSheet(show: Boolean) {
        _state.update { it.copy(showTtsSheet = show, showChrome = if (show) true else it.showChrome) }
        keepChromeAlive()
    }

    fun selectTtsVoice(name: String, persist: Boolean = true) {
        val engine = ttsEngine ?: return
        val voice = engine.voices?.firstOrNull { it.name == name } ?: return
        if (engine.setVoice(voice) != android.speech.tts.TextToSpeech.SUCCESS) {
            postTransientMessage("Couldn't use this voice. Try another voice.")
            return
        }
        _state.update { it.copy(ttsVoice = name) }
        if (persist) viewModelScope.launch { hearthPreferences.setReaderTtsVoice(name) }
        ttsPlayback.restart()
    }

    fun toggleTtsPlayback() {
        when {
            ttsPlayback.state.value.playing -> ttsPlayback.pause()
            ttsPlayback.state.value.active -> ttsPlayback.resume()
            else -> startTts()
        }
        keepChromeAlive()
    }

    fun pauseTts() = ttsPlayback.pause()
    fun previousTtsParagraph() { ttsPlayback.previous(); keepChromeAlive() }
    fun nextTtsParagraph() { ttsPlayback.next(); keepChromeAlive() }

    @OptIn(ExperimentalReadiumApi::class)
    fun startTts() {
        if (!_state.value.ttsReady) {
            postTransientMessage(ttsUnavailableReason)
            return
        }
        if (_state.value.readAlongActive) stopReadAlongMode()
        if (audioPlaybackManager.state.value.isPlaying) audioPlaybackManager.togglePlayPause()
        var iterator: Content.Iterator? = null
        val start = engineNavigator?.currentLocator ?: navigator?.currentLocator?.value
        ttsPlayback.start {
            val content = iterator ?: run {
                val pub = publication ?: ttsPublication ?: run {
                    val file = ttsBookFile ?: error("Reader is still loading")
                    val asset = readium.assetRetriever.retrieve(file).getOrElse { error("Cannot read this format") }
                    readium.publicationOpener.open(asset, allowUserInteraction = false)
                        .getOrElse { error("Cannot extract this format") }
                        .also { ttsPublication = it }
                }
                val anchor = if (engineNavigator == null) readiumReadingAnchor() ?: start else start
                pub.content(anchor)?.iterator()?.also { iterator = it } ?: error("No text content")
            }
            withContext(Dispatchers.Default) {
                var paragraph: EbookTTSParagraph? = null
                while (content.hasNext()) {
                    val element = content.next() as? Content.TextElement ?: continue
                    if (element.text.isNotBlank()) {
                        paragraph = EbookTTSParagraph(element.text, element.locator)
                        break
                    }
                }
                paragraph
            }
        }
    }

    fun speakSelection(text: String) {
        if (text.isBlank()) return
        if (!_state.value.ttsReady) {
            postTransientMessage(ttsUnavailableReason)
            return
        }
        if (_state.value.readAlongActive) stopReadAlongMode()
        if (audioPlaybackManager.state.value.isPlaying) audioPlaybackManager.togglePlayPause()
        var pending = true
        ttsPlayback.start {
            if (pending) {
                pending = false
                EbookTTSParagraph(text)
            } else null
        }
    }

    fun stopTts() {
        ttsPlayback.stop()
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
        stopTts()
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
        if (!readAloudPlayback.state.value.hasMediaItem) audioPlaybackManager.stop()
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
        if (!speed.isFinite()) return
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
        return readResourceText(pub, link)
    }

    private suspend fun readResourceText(pub: Publication, link: Link): String? = withContext(Dispatchers.IO) {
        val resource = pub.get(link) ?: return@withContext null
        try {
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
        if (isTextSelectionActive()) return

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
            if (!_state.value.readAlongPlaying || audioIsNavigating || isTextSelectionActive()) return@launch
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
        if (!_state.value.prefs.readAloudAutoTurn || isTextSelectionActive()) return
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

    private fun followCurrentReadAlongClip() {
        val clip = mediaOverlayEngine?.currentClipSnapshot() ?: return
        val nav = navigator ?: return
        readAlongClipUiJob?.cancel()
        readAlongClipUiJob = viewModelScope.launch {
            autoNavigateReadAlongClip(clip, nav, buildReadAlongLocator(clip) ?: return@launch)
            scheduleReadAlongPagePreflip(clip, nav)
        }
    }

    private fun isTextSelectionActive(): Boolean =
        textSelectionActive || _state.value.showSelectionPopup || _state.value.showAnnotationDialog

    fun onTextSelectionStarted() {
        textSelectionActive = true
        readAlongPageFlipJob?.cancel()
        readAlongPageFlipJob = null
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
            style = if (p.readAloudHighlightStyle == ReadAloudHighlightStyle.UNDERLINE) {
                Decoration.Style.Underline(tint = p.primaryTextColor)
            } else {
                Decoration.Style.Highlight(tint = tint, isActive = true)
            },
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
            if (!_state.value.prefs.readAloudSkipOnPageTurn) return@launch
            val currentClip = engine.currentClip()
            val fragId = currentClip?.textFragmentId
            if (currentClip != null && fragId != null &&
                normalizePublicationHref(currentClip.textHref) == normalizePublicationHref(nav.currentLocator.value.href.toString()) &&
                isReadAlongFragmentVisible(fragId, nav)
            ) {
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
                el.scrollIntoView({ behavior: 'auto', block: 'center' });
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

    internal fun beginReadiumLayout(): Long {
        val generation = ++readiumLayoutGeneration
        if (!_state.value.readAlongActive) readiumLayouts.add(generation)
        heldReadingPosition.invalidate()
        readingSpeedTracker.pause()
        return generation
    }

    internal fun endReadiumLayout(generation: Long) {
        readiumLayouts.remove(generation)
    }

    fun preserveReadiumPositionAcross(viewportChange: () -> Unit) {
        val nav = navigator
        if (nav == null || engineNavigator != null || (!readiumRestoreConfirmed && epubCheckpointLease != null)) {
            viewportChange()
            return
        }
        viewportReanchorJob?.cancel()
        val navigationGeneration = readiumUserNavigationGeneration
        val layoutGeneration = beginReadiumLayout()
        viewportReanchorJob = viewModelScope.launch(start = CoroutineStart.UNDISPATCHED) {
            try {
                val narration = narrationViewportAnchor()
                val reused = viewportAnchor?.takeIf { it.page == null || it.page == nav.currentLocator.value.pageKey() }
                val anchor = narration ?: reused?.locator ?: heldReadingPosition.locator() ?: firstVisibleTextLocator(nav)
                if (anchor == null) {
                    viewportAnchor = null
                    viewportChange()
                    return@launch
                }
                viewportAnchor = ViewportAnchor(anchor, page = null)
                viewportChange()
                delay(VIEWPORT_SETTLE_MS)
                if (navigationGeneration != readiumUserNavigationGeneration ||
                    normalizePublicationHref(nav.currentLocator.value.href.toString()) != normalizePublicationHref(anchor.href.toString())
                ) {
                    viewportAnchor = null
                    return@launch
                }
                nav.go(anchor, animated = false)
                delay(VIEWPORT_SETTLE_MS)
                viewportAnchor = ViewportAnchor(anchor, page = nav.currentLocator.value.pageKey())
            } finally {
                endReadiumLayout(layoutGeneration)
            }
        }
    }

    private fun narrationViewportAnchor(): Locator? {
        if (!_state.value.readAlongPlaying || !_state.value.prefs.readAloudAutoTurn) return null
        return mediaOverlayEngine?.currentClipSnapshot()?.let(::buildReadAlongLocator)
    }

    private fun Locator.pageKey(): String = "$href|${locations.progression}"

    private suspend fun firstVisibleTextLocator(nav: EpubNavigatorFragment): Locator? {
        val current = nav.currentLocator.value
        val expectedPath = org.json.JSONObject.quote(current.href.toString())
        val script = """
            (function() {
                if (!decodeURIComponent(window.location.pathname).endsWith(decodeURIComponent($expectedPath))) return null;
                const visible = (r) => r.width > 0 && r.height > 0 && r.right > 0 && r.left < window.innerWidth && r.bottom > 0 && r.top < window.innerHeight;
                const selectorFor = (element) => {
                    const path = [];
                    for (let el = element; el && el !== document.body; el = el.parentElement) {
                        if (el.id) {
                            path.unshift('#' + CSS.escape(el.id));
                            return path.join(' > ');
                        }
                        path.unshift(el.localName + ':nth-child(' + (Array.prototype.indexOf.call(el.parentElement.children, el) + 1) + ')');
                    }
                    path.unshift('body');
                    return path.join(' > ');
                };
                const textAround = (node, start, end) => {
                    const before = document.createRange();
                    before.setStart(document.body, 0);
                    before.setEnd(node, start);
                    const after = document.createRange();
                    after.setStart(node, end);
                    after.setEnd(document.body, document.body.childNodes.length);
                    return { before: before.toString().slice(-64), after: after.toString().slice(0, 64) };
                };
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
                            const end = Math.min(text.length, i + 64);
                            const context = textAround(node, i, end);
                            return {
                                selector: selectorFor(node.parentElement),
                                before: context.before,
                                highlight: text.slice(i, end),
                                after: context.after,
                            };
                        }
                    }
                }
                return null;
            })();
        """.trimIndent()
        val json = nav.evaluateJavascript(script)
            ?.let { runCatching { org.json.JSONObject(it) }.getOrNull() }
            ?: return null
        val selector = json.optString("selector").ifEmpty { null }
        return current.copy(
            locations = current.locations.copy(
                otherLocations = current.locations.otherLocations - "cssSelector" +
                    listOfNotNull(selector?.let { "cssSelector" to it }),
            ),
            text = Locator.Text(
                before = json.optString("before").ifEmpty { null },
                highlight = json.optString("highlight"),
                after = json.optString("after").ifEmpty { null },
            ),
        )
    }

    suspend fun readiumReadingAnchor(): Locator? {
        val nav = navigator ?: return null
        return firstVisibleTextLocator(nav) ?: nav.currentLocator.value
    }

    fun noteInternalLinkJump(returnLocator: Locator) {
        _state.update { it.copy(linkReturnLocator = returnLocator) }
    }

    fun returnFromInternalLink() {
        val locator = _state.value.linkReturnLocator ?: return
        _state.update { it.copy(linkReturnLocator = null) }
        val nav = navigator ?: return
        viewModelScope.launch {
            readiumUserInteractionPending = true
            if (!nav.go(locator, animated = false)) {
                readiumUserInteractionPending = false
                return@launch
            }
            delay(VIEWPORT_SETTLE_MS)
            if (normalizePublicationHref(nav.currentLocator.value.href.toString()) == normalizePublicationHref(locator.href.toString())) {
                nav.go(locator, animated = false)
            }
        }
    }

    fun dismissInternalLinkReturn() {
        _state.update { it.copy(linkReturnLocator = null) }
    }

    fun noteReadiumUserInteraction() {
        if (navigator != null && engineNavigator == null) readiumUserInteractionPending = true
    }

    fun setReadiumScrollActive(active: Boolean) {
        if (!active) {
            readiumScrollCaptureJob?.cancel()
            readiumScrollCaptureJob = null
            return
        }
        if (readiumScrollCaptureJob?.isActive == true || !_state.value.prefs.scroll ||
            _state.value.readAlongActive || readiumLayoutInProgress) return
        val nav = navigator ?: return
        readiumScrollCaptureJob = viewModelScope.launch {
            while (navigator === nav && sessionResumedAtMs != null && !readiumLayoutInProgress) {
                captureHeldReadingPosition(nav, nav.currentLocator.value, heldReadingPosition.generation, userMoved = true)
                delay(120)
            }
        }
    }

    fun finishReadiumScroll() {
        setReadiumScrollActive(false)
        if (!_state.value.prefs.scroll || _state.value.readAlongActive || readiumLayoutInProgress) return
        val nav = navigator ?: return
        val generation = heldReadingPosition.generation
        readiumCaptureJob?.cancel()
        readiumScrollEndCaptureJob?.cancel()
        val finalCapture = applicationScope.launch(Dispatchers.Main.immediate, start = CoroutineStart.UNDISPATCHED) {
            kotlinx.coroutines.withTimeoutOrNull(FINAL_READING_CAPTURE_TIMEOUT_MS) {
                captureHeldReadingPosition(nav, nav.currentLocator.value, generation, userMoved = true)
            }
        }
        readiumCaptureJob = finalCapture
        readiumScrollEndCaptureJob = finalCapture
    }

    private suspend fun captureHeldReadingPosition(
        nav: EpubNavigatorFragment,
        locator: Locator,
        generation: Long,
        userMoved: Boolean,
    ) {
        val capture = captureReadiumCheckpoint(nav, locator) ?: return
        if (navigator !== nav || readiumLayoutInProgress || !heldReadingPosition.hold(capture, generation)) return
        if (userMoved && checkpointFingerprint(capture.checkpoint) != readiumCheckpointFingerprint) {
            readiumRestoreJob?.cancel()
            readiumRestoreConfirmed = true
            readiumCheckpointDirty = true
            scheduleReadiumCheckpointSync(nav)
        }
    }

    fun pageForward() {
        engineNavigator?.let {
            it.goForward()
            return
        }
        viewModelScope.launch {
            navigator?.let {
                readiumUserInteractionPending = true
                if (_state.value.prefs.scroll) {
                    if (!scrollReadiumPage(it, forward = true)) readiumUserInteractionPending = false
                } else if (!it.goForward()) {
                    readiumUserInteractionPending = false
                }
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
                if (_state.value.prefs.scroll) {
                    if (!scrollReadiumPage(it, forward = false)) readiumUserInteractionPending = false
                } else if (!it.goBackward()) {
                    readiumUserInteractionPending = false
                }
            }
        }
    }

    private suspend fun scrollReadiumPage(nav: EpubNavigatorFragment, forward: Boolean): Boolean =
        nav.evaluateJavascript("""
            (function() {
                const before = window.scrollY;
                window.scrollBy({ top: ${if (forward) 1 else -1} * window.innerHeight * 0.9, behavior: 'auto' });
                return window.scrollY !== before;
            })();
        """.trimIndent()) == "true"

    fun seekToProgress(fraction: Float) {
        readingSpeedTracker.pause()
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
        val resumeFollowing = isTextSelectionActive() && _state.value.readAlongPlaying
        textSelectionActive = false
        _state.update {
            it.copy(
                pendingSelection = null,
                selectionText = "",
                showSelectionPopup = false,
            )
        }
        if (resumeFollowing) followCurrentReadAlongClip()
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
            updatedAt = cached.lastReadTime,
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
        readingSpeedTracker.pause()
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

    private val ebookProgressSync = EbookProgressSyncQueue(applicationScope) {
        android.os.SystemClock.elapsedRealtime()
    }
    private val progressPushMutex = Mutex()

    private suspend fun runProgressPush(push: suspend () -> Unit) {
        progressPushMutex.withLock { push() }
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

    suspend fun checkpointForProfileSwitch() {
        progressPushesHeld = true
        cancelScheduledProgressPush()
        syncJob?.join()
        ebookProgressSync.discard()
        savePrefsJob?.cancel()
        savePrefsJob?.join()
        stopAutoScroll()
        stopTts()
        pauseReadingSession()
        if (preferencesLoaded) persistPreferences(_state.value.prefs)
        if (_state.value.readAlongActive) {
            submitCurrentReadAloudCheckpoint()
            readAloudCheckpoints.flush(bookId, bookSource, bookConnectionId)
        } else if (engineNavigator != null) {
            persistFoliateCheckpoint()
        } else {
            awaitStartedReadingCapture(readiumScrollEndCaptureJob)
            heldReadingPosition.invalidate()
            readiumCaptureJob?.cancel()
            readiumScrollEndCaptureJob = null
            navigator?.let { persistCurrentReadiumCheckpoint(it) }
        }
        if (bookId.isNotBlank()) {
            val checkpoint = latestEpubCheckpoint
            val locator = checkpoint?.let(EpubBridgeCheckpointCodec::encode)
                ?: navigator?.currentLocator?.value?.toJSONOrNull()
            val progress = currentReadingProgress().toFloat().coerceIn(0f, 1f)
            val now = System.currentTimeMillis()
            db?.bookCacheDao()?.updateUnifiedProgress(bookId, bookConnectionId, progress, -1L, locator, now)
            if (aggregatorRepository.serverSyncEnabled) db?.pendingProgressPushDao()?.upsert(com.enve.core.data.local.PendingProgressPush(
                bookId = bookId,
                source = bookSource.name,
                connectionKey = bookConnectionId.orEmpty(),
                mediaType = com.enve.core.data.model.AppMediaType.EBOOK.name,
                percentage = progress,
                isFinished = progress >= 1f,
                createdAt = now,
            ))
        }
        takeReadingSession()?.let { history.append(it) }
    }

    fun flushProgress() {
        setReadiumScrollActive(false)
        val finalCapture = readiumScrollEndCaptureJob?.takeIf {
            engineNavigator == null && !_state.value.readAlongActive
        }
        if (finalCapture == null) {
            heldReadingPosition.invalidate()
            readiumCaptureJob?.cancel()
        }
        ebookProgressSync.setReaderActive(false)
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
                    runProgressPush {
                        persistFoliateCheckpoint()
                        ebookProgressSync.flush()
                    }
                }
            } else {
                applicationScope.launch { ebookProgressSync.flush() }
            }
            return
        }
        val nav = navigator ?: return
        cancelScheduledProgressPush()
        applicationScope.launch(Dispatchers.Main.immediate) {
            runProgressPush {
                awaitStartedReadingCapture(finalCapture)
                heldReadingPosition.invalidate()
                readiumCaptureJob?.cancel()
                if (readiumScrollEndCaptureJob === finalCapture) readiumScrollEndCaptureJob = null
                cancelScheduledProgressPush()
                if (
                    readiumRestoreConfirmed &&
                    readiumCheckpointDirty &&
                    epubCheckpointLease != null
                ) {
                    persistCurrentReadiumCheckpoint(nav)
                } else if (epubCheckpointLease == null) {
                    heldReadingPosition.locator()?.let { pushProgress(it) }
                }
                ebookProgressSync.flush()
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
        generation: Long,
    ) {
        val lease = epubCheckpointLease ?: return
        val candidate = checkpoint.copy(revision = latestEpubCheckpoint?.revision ?: checkpoint.revision)
        val committed = epubBridgeCheckpoints.commit(lease, candidate) ?: return
        latestEpubCheckpoint = committed
        readiumCheckpointFingerprint = checkpointFingerprint(committed)
        readiumCheckpointDirty = heldReadingPosition.generation != generation
        pushProgress(
            locator = locator,
            locatorJsonOverride = EpubBridgeCheckpointCodec.encode(committed),
        )
    }

    private suspend fun persistCurrentReadiumCheckpoint(nav: EpubNavigatorFragment) {
        if (!readiumRestoreConfirmed || !readiumCheckpointDirty) return
        if (navigator !== nav) return
        val capture = heldReadingPosition.current() ?: run {
            val locator = heldReadingPosition.locator() ?: return
            val lease = epubCheckpointLease ?: return
            val checkpoint = EpubBridgeCheckpointCodec.fromReadiumLocator(
                locator.toJSONOrNull() ?: return, lease.publicationSha256, lease.providerFileId,
                lease.writerEpoch, latestEpubCheckpoint?.revision ?: 0L, System.currentTimeMillis(),
            ) ?: return
            ReadiumCheckpointCapture(locator, checkpoint)
        }
        val fingerprint = checkpointFingerprint(capture.checkpoint)
        if (fingerprint == readiumCheckpointFingerprint) {
            readiumCheckpointDirty = false
            return
        }
        persistReadiumCheckpoint(capture.locator, capture.checkpoint, heldReadingPosition.generation)
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
        return queueEbookProgress(book, pct, encoded)
    }

    private suspend fun queueEbookProgress(book: Book, pct: Float, locatorJson: String?, legacySync: Boolean = false): Result<Unit> {
        val page = _state.value.currentPage.takeIf { it > 0 }
        val pageCount = _state.value.totalPages.takeIf { it > 0 }
        val interval = if (_state.value.readAlongActive) 0L else hearthPreferences.ebookSyncInterval.first().milliseconds
        var sinksSubmitted = false
        return ebookProgressSync.submit(interval) {
            if (progressPushesHeld) return@submit Result.success(Unit)
            if (!sinksSubmitted) {
                runSuspendCatching { koreaderHub.pushIfConfigured(book, pct, locatorJson) }
                hardcoverSync.submitProgress(book, pct)
                sinksSubmitted = true
            }
            if (progressPushesHeld) return@submit Result.success(Unit)
            if (legacySync) {
                syncManager.pushEbookProgress(bookId = book.id, percentage = pct, cfi = locatorJson)
                Result.success(Unit)
            } else {
                aggregatorRepository.syncEbookProgress(
                    bookId = book.id,
                    source = book.source,
                    percentage = pct,
                    locator = locatorJson,
                    page = page,
                    pageCount = pageCount,
                    connectionId = book.connectionId,
                ).onSuccess {
                    rewindTracker.recordOutboundWrite(
                        key = RemoteProgressWriteKey.of(book),
                        percentage = pct,
                        positionMs = null,
                        locatorJson = locatorJson,
                    )
                }
            }
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

        val isLikelyInitialEmit = pct < 0.005f && lastPushedPct < 0f &&
            epubCheckpointLease == null && !readiumUserInteractionPending
        if (readAlongActive) {
            readAloudCheckpoints.flush(bookId, bookSource, bookConnectionId)
        } else if (!isLikelyInitialEmit) {
            runSuspendCatching {
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

        queueEbookProgress(
            Book(
                id = bookId,
                title = bookTitle.ifBlank { bookId },
                source = bookSource,
                mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
                connectionId = bookConnectionId,
            ),
            pct,
            json,
            legacySync = bookConnectionId == null && bookSource == BookSource.GRIMMORY,
        )
    }

    private fun loadLayoutPresets() {
        viewModelScope.launch {
            db?.layoutPresetDao()?.flowAll()?.collect { presets ->
                _state.update { it.copy(layoutPresets = presets) }
            }
        }
    }

    override fun onCleared() {
        ebookProgressSync.setReaderActive(false)
        applicationScope.launch { ebookProgressSync.flush() }
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
        ttsPlayback.stop()

        val pubToClose = publication
        publication = null
        if (pubToClose != null) {
            applicationScope.launch(Dispatchers.IO) {
                runCatching { pubToClose.close() }
            }
        }
        val ttsPubToClose = ttsPublication
        ttsPublication = null
        if (ttsPubToClose != null && ttsPubToClose !== pubToClose) {
            applicationScope.launch(Dispatchers.IO) { ttsPubToClose.close() }
        }
        closeReadingSession()
    }

    private var sessionStartedAtMs: Long? = null
    private var sessionResumedAtMs: Long? = null
    private var sessionAccumulatedMs: Long = 0
    private var sessionStartProgress: Float? = null

    private fun startReadingSession() {
        if (sessionStartedAtMs != null) return
        readingSpeedTracker.reset()
        val now = System.currentTimeMillis()
        sessionStartedAtMs = now
        sessionResumedAtMs = now
        sessionAccumulatedMs = 0
        sessionStartProgress = null
    }

    fun pauseReadingSession() {
        readingSpeedTracker.pause()
        val resumed = sessionResumedAtMs ?: return
        val now = System.currentTimeMillis()
        if (now > resumed) sessionAccumulatedMs += now - resumed
        sessionResumedAtMs = null
    }

    fun resumeReadingSession() {
        ebookProgressSync.setReaderActive(true)
        if (sessionStartedAtMs == null) return
        if (sessionResumedAtMs != null) return
        sessionResumedAtMs = System.currentTimeMillis()
    }

    private fun takeReadingSession(): HistorySession? {
        val startedAt = sessionStartedAtMs ?: return null
        pauseReadingSession()
        val durationMs = sessionAccumulatedMs
        val endAt = System.currentTimeMillis()
        sessionStartedAtMs = null
        sessionResumedAtMs = null
        sessionAccumulatedMs = 0

        if (durationMs < 5_000L) return null
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
        return HistorySession(
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
    }

    private fun closeReadingSession() {
        val historySession = takeReadingSession() ?: return
        val capturedBookId = historySession.bookId
        val capturedSource = historySession.source
        val capturedConnectionId = historySession.connectionId
        val startedAt = historySession.startTimeMs
        val endAt = historySession.endTimeMs
        val durationMs = historySession.activeDurationSeconds * 1_000L
        val startProgress = historySession.startProgress
        val endProgress = historySession.endProgress
        applicationScope.launch(Dispatchers.IO) {
            history.append(historySession)
            try {
                when (capturedSource) {
                    BookSource.GRIMMORY -> {
                        val fileType = db?.bookCacheDao()?.getById(capturedBookId)?.primaryFileType
                        val block: suspend () -> Unit = {
                            repository.createReadingSession(
                                fileType = fileType,
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
