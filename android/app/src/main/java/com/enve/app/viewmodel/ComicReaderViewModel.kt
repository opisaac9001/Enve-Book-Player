package com.enve.app.viewmodel

import android.content.Context
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ComicReadingDirectionOverrideStore
import com.enve.app.data.reader.nextBookInSeries
import com.enve.app.data.reader.isReadForNextInSeries
import com.enve.app.data.reader.ServerPageStreamingService
import com.enve.app.data.reader.StreamedComicSession
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ComicPageLoadingMode
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.ui.screens.ReaderFormat
import com.enve.app.ui.screens.buildPageLocator
import com.enve.app.ui.screens.loadOrExtractComicPages
import com.enve.app.ui.screens.pageIndexFromProgress
import com.enve.app.ui.screens.parseSavedPage
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import java.io.File
import javax.inject.Inject

enum class ComicReadingDirection(val label: String) {
    LEFT_TO_RIGHT("LTR"),
    RIGHT_TO_LEFT("RTL"),
    VERTICAL("Vertical"),
    WEBTOON("Webtoon"),
}

enum class ComicProgressionMode(val label: String) {
    PAGED("Paged"),
    VERTICAL_STRIP("Scroll"),
}

enum class ComicPageFit(val label: String) {
    FIT_SCREEN("Fit"),
    FIT_WIDTH("Width"),
    FIT_HEIGHT("Height"),
    ORIGINAL_SIZE("1:1"),
}

enum class ComicSpreadMode(val label: String) {
    OFF("1 Page"),
    AUTO("Auto Spread"),
    ON("2 Page"),
}

enum class ComicBackgroundTheme(val argb: Int, val label: String) {
    BLACK(0xFF000000.toInt(), "Black"),
    DARK(0xFF1A1A2E.toInt(), "Dark"),
    GRAY(0xFF2D2D2D.toInt(), "Gray"),
    SEPIA(0xFF2C1810.toInt(), "Sepia"),
    WHITE(0xFFF5F5F5.toInt(), "White"),
}

data class ComicReaderSettings(
    val readingDirection: ComicReadingDirection = ComicReadingDirection.LEFT_TO_RIGHT,
    val progressionMode: ComicProgressionMode = ComicProgressionMode.PAGED,
    val pageFit: ComicPageFit = ComicPageFit.FIT_WIDTH,
    val spreadMode: ComicSpreadMode = ComicSpreadMode.AUTO,
    val zoomEnabled: Boolean = true,
    val autoHideChrome: Boolean = true,
    val backgroundArgb: Int = 0xFF000000.toInt(),
    val volumeButtonNavigation: Boolean = false,
    val brightness: Float = -1f,
    val backgroundTheme: ComicBackgroundTheme = ComicBackgroundTheme.BLACK,
)

data class ComicReaderUiState(
    val title: String = "",
    val author: String = "",
    val formatLabel: String = "Comic",
    val settings: ComicReaderSettings = ComicReaderSettings(),
    val isLoading: Boolean = true,
    val loadingText: String = "Preparing comic...",
    val loadingProgress: Int? = null,
    val error: String? = null,
    val pages: List<File> = emptyList(),
    val availablePages: Set<Int> = emptySet(),
    val currentPage: Int = 0,
    val bookmarks: Set<Int> = emptySet(),
    val showSettingsSheet: Boolean = false,
    val nextInSeries: Book? = null,
)

data class ComicReaderArgs(
    val bookId: String,
    val bookSource: BookSource,
    val connectionId: String? = null,
    val title: String,
    val author: String,
    val format: ReaderFormat,
    val locator: String?,
)

@HiltViewModel
class ComicReaderViewModel @Inject constructor(
    @ApplicationContext private val appContext: Context,
    private val prefs: PreferencesManager,
    private val repository: GrimmoryRepository,
    private val aggregatorRepository: AggregatorRepository,
    private val annotationRepo: com.enve.app.data.repository.AnnotationRepository,
    private val komgaRepository: com.enve.komga.KomgaRepository,
    private val comicOfflineService: com.enve.app.data.offline.ComicOfflineService,
    private val bookCacheDao: BookCacheDao,
    private val pageStreamingService: ServerPageStreamingService,
    private val directionOverrides: ComicReadingDirectionOverrideStore,
) : ViewModel() {

    private var bookDirectionOverride: ComicReadingDirection? = null

    fun addPageBookmark(note: String = "") {
        val page = _state.value.currentPage
        val id = bookId.takeIf { it.isNotBlank() } ?: return
        viewModelScope.launch {
            annotationRepo.create(
                bookId = id,
                kind = com.enve.core.data.model.AnnotationKind.BOOKMARK,
                media = com.enve.core.data.model.AnnotationMedia.CBZ,
                style = com.enve.core.data.model.AnnotationStyle.NONE,
                cbzPage = page,
                note = note,
                selectedText = "Page ${page + 1}",
            )
        }
    }

    private val _state = MutableStateFlow(ComicReaderUiState())
    val state: StateFlow<ComicReaderUiState> = _state.asStateFlow()

    private var initialized = false
    private var bookId: String = ""
    private var bookSource: BookSource = BookSource.GRIMMORY
    private var bookConnectionId: String? = null
    private var format: ReaderFormat = ReaderFormat.CBZ
    private var streamedSession: StreamedComicSession? = null
    private var streamedBook: Book? = null
    private var pageLoadingMode = ComicPageLoadingMode.STREAM
    private var preloadJob: Job? = null
    private val pageJobs = mutableMapOf<Int, Job>()

    init {
        viewModelScope.launch {
            val namesFlow = combine(
                prefs.comicReadingDirection,
                prefs.comicProgressionMode,
                prefs.comicPageFit,
                prefs.comicSpreadMode,
            ) { direction, progression, fit, spread ->
                ComicPreferenceNames(direction, progression, fit, spread)
            }
            val togglesFlow = combine(
                prefs.comicZoomEnabled,
                prefs.comicAutoHideChrome,
                prefs.comicBackgroundArgb,
                prefs.comicVolumeButtonNav,
            ) { zoom, autoHide, backgroundArgb, volumeNav ->
                ComicPreferenceToggles(zoom, autoHide, backgroundArgb, volumeNav)
            }
            val extrasFlow = combine(
                prefs.comicBrightness,
                prefs.comicBackgroundTheme,
            ) { brightness, theme -> Pair(brightness, theme) }

            combine(namesFlow, togglesFlow, extrasFlow) { names, toggles, extras ->
                ComicReaderSettings(
                    readingDirection = enumValueOrDefault(names.readingDirection, ComicReadingDirection.LEFT_TO_RIGHT),
                    progressionMode = enumValueOrDefault(names.progressionMode, ComicProgressionMode.PAGED),
                    pageFit = enumValueOrDefault(names.pageFit, ComicPageFit.FIT_WIDTH),
                    spreadMode = enumValueOrDefault(names.spreadMode, ComicSpreadMode.AUTO),
                    zoomEnabled = toggles.zoomEnabled,
                    autoHideChrome = toggles.autoHideChrome,
                    backgroundArgb = toggles.backgroundArgb,
                    volumeButtonNavigation = toggles.volumeButtonNavigation,
                    brightness = extras.first,
                    backgroundTheme = enumValueOrDefault(extras.second, ComicBackgroundTheme.BLACK),
                )
            }.collect { settings ->
                _state.update {
                    it.copy(
                        settings = settings.copy(
                            readingDirection = bookDirectionOverride ?: settings.readingDirection,
                        ),
                    )
                }
            }
        }
    }

    fun initialize(args: ComicReaderArgs) {
        val sameBook = bookId == args.bookId &&
            bookSource == args.bookSource &&
            bookConnectionId == args.connectionId
        if (initialized && sameBook) return
        endStreamingSession()
        initialized = true
        if (!sameBook) {
            bookDirectionOverride = null
            _state.update { it.copy(nextInSeries = null) }
        }
        bookId = args.bookId
        bookSource = args.bookSource
        bookConnectionId = args.connectionId
        format = args.format.takeIf { it.isComic } ?: ReaderFormat.CBZ
        _state.update {
            it.copy(
                title = args.title,
                author = args.author,
                formatLabel = format.displayName,
                isLoading = true,
                loadingText = "Preparing ${format.displayName}...",
                error = null,
                pages = emptyList(),
                availablePages = emptySet(),
                currentPage = 0,
            )
        }
        viewModelScope.launch { openComic(args.locator) }
        viewModelScope.launch { resolveNextInSeries() }
    }

    private suspend fun resolveNextInSeries() {
        bookCacheDao.nextBookInSeries(bookId, bookConnectionId)?.let { next ->
            _state.update { it.copy(nextInSeries = next) }
            return
        }
        if (bookSource != BookSource.KOMGA) return
        val seriesId = try {
            komgaRepository.getSeriesIdForBook(bookId)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        } ?: return
        val books = try {
            komgaRepository.getSeriesBooks(seriesId).getOrNull()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }.orEmpty()
        val idx = books.indexOfFirst { it.id == bookId }.takeIf { it >= 0 } ?: return
        val next = books.drop(idx + 1).firstOrNull { !it.isReadForNextInSeries() } ?: return
        _state.update { it.copy(nextInSeries = next) }
    }

    fun updateSettings(settings: ComicReaderSettings) {
        val directionChanged = settings.readingDirection != _state.value.settings.readingDirection
        if (directionChanged) bookDirectionOverride = settings.readingDirection
        _state.update { it.copy(settings = settings) }
        viewModelScope.launch {
            if (directionChanged) {
                directionOverrides.save(currentBookKey(), settings.readingDirection.name)
            }
            prefs.saveComicReaderPreferences(
                readingDirection = settings.readingDirection.name.takeIf { directionChanged },
                progressionMode = settings.progressionMode.name,
                pageFit = settings.pageFit.name,
                spreadMode = settings.spreadMode.name,
                zoomEnabled = settings.zoomEnabled,
                autoHideChrome = settings.autoHideChrome,
                backgroundArgb = settings.backgroundTheme.argb,
                volumeButtonNav = settings.volumeButtonNavigation,
                brightness = settings.brightness,
                backgroundTheme = settings.backgroundTheme.name,
            )
        }
    }

    fun showPage(pageIndex: Int) {
        val current = _state.value
        if (current.pages.isEmpty()) return
        val clamped = pageIndex.coerceIn(0, current.pages.lastIndex)
        if (clamped == current.currentPage) return
        _state.update { it.copy(currentPage = clamped) }
        if (pageLoadingMode == ComicPageLoadingMode.STREAM) {
            requestPageWindow(clamped)
        } else {
            requestPages(listOf(clamped))
        }
        syncProgress()
    }

    fun requestPages(pageIndices: List<Int>) {
        val session = streamedSession ?: return
        val allowedPages = if (pageLoadingMode == ComicPageLoadingMode.STREAM) {
            val currentPage = _state.value.currentPage
            (currentPage - 3)..(currentPage + 3)
        } else {
            session.pages.indices
        }
        pageIndices.distinct().filter { it in session.pages.indices && it in allowedPages }.forEach { pageIndex ->
            if (pageIndex in _state.value.availablePages || pageJobs[pageIndex]?.isActive == true) return@forEach
            pageJobs[pageIndex] = viewModelScope.launch {
                try {
                    loadStreamedPage(session, pageIndex)
                } finally {
                    coroutineContext[Job]?.let { job -> pageJobs.remove(pageIndex, job) }
                }
            }
        }
    }

    fun endStreamingSession() {
        preloadJob?.cancel()
        preloadJob = null
        pageJobs.values.forEach(Job::cancel)
        pageJobs.clear()
        val session = streamedSession
        if (session != null && pageLoadingMode == ComicPageLoadingMode.PRELOAD) {
            pageStreamingService.clear(session)
        }
        streamedSession = null
        streamedBook = null
    }

    fun toggleBookmark(pageIndex: Int) {
        val current = _state.value
        val updated = if (pageIndex in current.bookmarks) {
            current.bookmarks - pageIndex
        } else {
            current.bookmarks + pageIndex
        }
        _state.update { it.copy(bookmarks = updated) }
    }

    fun openSettingsSheet() = _state.update { it.copy(showSettingsSheet = true) }
    fun closeSettingsSheet() = _state.update { it.copy(showSettingsSheet = false) }

    fun syncProgress() {
        val current = _state.value
        if (bookId.isBlank() || current.pages.isEmpty()) return
        val totalPages = current.pages.size.coerceAtLeast(1)
        val percentage = (current.currentPage + 1).toFloat() / totalPages.toFloat()
        val locator = buildPageLocator(format, current.currentPage)
        viewModelScope.launch {
            try {
                if (bookConnectionId == null && bookSource == BookSource.GRIMMORY) {
                    repository.syncEbookProgress(bookId, percentage, locator)
                } else {
                    aggregatorRepository.syncEbookProgress(
                        bookId = bookId,
                        source = bookSource,
                        percentage = percentage,
                        locator = locator,
                        page = current.currentPage + 1,
                        pageCount = totalPages,
                        connectionId = bookConnectionId,
                    )
                }
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (_: Exception) {

            }
        }
    }

    private suspend fun resolveInitialPage(argsLocator: String?, lastIndex: Int): Int {

        val fromArgs = parseSavedPage(argsLocator, format).coerceAtLeast(0)
        val cached = runCatching {
            val cached = bookCacheDao.getByIdAndConnection(bookId, bookConnectionId)
                ?: bookCacheDao.getById(bookId)
            cached
        }.getOrNull()
        val fromLocal = cached?.epubLocator
            ?.let { parseSavedPage(it, format).coerceAtLeast(0) }
            ?: 0
        val fromLocalProgress = cached?.let { pageIndexFromProgress(it.epubProgress ?: it.readProgress, lastIndex + 1) } ?: 0
        val serverSnapshot = runCatching {
            val stub = Book(
                id = bookId,
                title = "",
                source = bookSource,
                connectionId = bookConnectionId,
            )
            aggregatorRepository.fetchEbookProgress(stub).getOrNull()
        }.getOrNull()
        val fromServer = serverSnapshot?.locatorJson
            ?.let { parseSavedPage(it, format).coerceAtLeast(0) }
            ?: 0
        val fromServerProgress = pageIndexFromProgress(serverSnapshot?.percentage, lastIndex + 1)
        return maxOf(fromArgs, fromLocal, fromLocalProgress, fromServer, fromServerProgress).coerceIn(0, lastIndex)
    }

    private suspend fun openComic(locator: String?) {
        _state.update { it.copy(isLoading = true, loadingText = "Downloading ${format.displayName}...", error = null) }

        resolveBookReadingDirection()?.let { direction ->
            bookDirectionOverride = direction
            val isStrip = direction == ComicReadingDirection.VERTICAL || direction == ComicReadingDirection.WEBTOON
            _state.update {
                it.copy(
                    settings = it.settings.copy(
                        readingDirection = direction,
                        progressionMode = if (isStrip) ComicProgressionMode.VERTICAL_STRIP else it.settings.progressionMode,
                    ),
                )
            }
            Log.d("ComicReader", "Resolved reading direction for $bookId -> $direction")
        }

        val offlineFile = comicOfflineService.getLocalFile(bookId)
        if (offlineFile != null && offlineFile.exists() && offlineFile.length() > 1024) {
            val pages = try {
                loadOrExtractComicPages(
                    cacheDir = appContext.cacheDir,
                    archive = offlineFile,
                    format = format,
                    onStatus = { status ->
                        _state.update { it.copy(loadingText = status) }
                    },
                )
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update { it.copy(isLoading = false, error = "Could not extract comic pages: ${e.message}") }
                return
            }
            if (pages.isEmpty()) {
                _state.update { it.copy(isLoading = false, error = "No readable image pages were found in this comic archive.") }
                return
            }
            val initialPage = resolveInitialPage(locator, pages.lastIndex)
            _state.update { it.copy(isLoading = false, pages = pages, currentPage = initialPage, loadingProgress = null) }
            _state.update { it.copy(availablePages = pages.indices.toSet()) }
            syncProgress()
            return
        }

        if (bookSource == BookSource.KOMGA) {
            openStreamedKomga(locator)
            return
        }

        val stubBookForDownload = Book(
            id = bookId,
            title = _state.value.title,
            source = bookSource,
            connectionId = bookConnectionId,
            primaryFileType = format.name,
        )
        comicOfflineService.startDownload(stubBookForDownload)

        val archive: File = try {
            val terminal = comicOfflineService.progressByBookId
                .mapNotNull { it[bookId] }
                .onEach { progress ->
                    if (progress.status == com.enve.app.data.offline.ComicDownloadStatus.QUEUED ||
                        progress.status == com.enve.app.data.offline.ComicDownloadStatus.DOWNLOADING
                    ) {
                        _state.update {
                            it.copy(
                                loadingText = "Downloading ${format.displayName}…",
                                loadingProgress = (progress.progress * 100).toInt().coerceIn(0, 100),
                            )
                        }
                    }
                }
                .first { progress ->
                    progress.status == com.enve.app.data.offline.ComicDownloadStatus.COMPLETED ||
                        progress.status == com.enve.app.data.offline.ComicDownloadStatus.FAILED ||
                        progress.status == com.enve.app.data.offline.ComicDownloadStatus.CANCELLED
                }
            if (terminal.status != com.enve.app.data.offline.ComicDownloadStatus.COMPLETED) {
                error(terminal.errorMessage ?: "Download ${terminal.status.name.lowercase()}")
            }
            comicOfflineService.getLocalFile(bookId)
                ?: error("Download finished but file was not found in offline storage")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(isLoading = false, error = "Download failed: ${e.message}") }
            return
        }

        val pages = try {
            loadOrExtractComicPages(
                cacheDir = appContext.cacheDir,
                archive = archive,
                format = format,
                onStatus = { status -> _state.update { it.copy(loadingText = status) } },
            )
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(isLoading = false, error = "Could not extract comic pages: ${e.message}") }
            return
        }

        if (pages.isEmpty()) {
            _state.update { it.copy(isLoading = false, error = "No readable image pages were found in this comic archive.") }
            return
        }

        val initialPage = resolveInitialPage(locator, pages.lastIndex)
        _state.update {
            it.copy(
                isLoading = false,
                pages = pages,
                availablePages = pages.indices.toSet(),
                currentPage = initialPage,
                loadingProgress = null,
            )
        }
        syncProgress()
    }

    private suspend fun openStreamedKomga(locator: String?) {
        _state.update { it.copy(loadingText = "Loading page list…", loadingProgress = null) }
        val book = Book(
            id = bookId,
            title = _state.value.title,
            source = BookSource.KOMGA,
            connectionId = bookConnectionId,
            primaryFileType = format.name,
        )
        val pageCount = aggregatorRepository.getComicPageCount(book).getOrElse { error ->
            _state.update { it.copy(isLoading = false, error = "Could not load comic pages: ${error.message}") }
            return
        }
        val initialPage = resolveInitialPage(locator, pageCount - 1)
        pageLoadingMode = prefs.comicPageLoadingMode.first()
        val session = pageStreamingService.openSession(
            cacheKey = "${bookConnectionId.orEmpty()}-$bookId",
            pageCount = pageCount,
        )
        streamedSession = session
        streamedBook = book

        if (pageLoadingMode == ComicPageLoadingMode.STREAM) {
            pageStreamingService.trimToWindow(session, initialPage)
        }

        try {
            ensureStreamedPage(session, initialPage)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            _state.update { it.copy(isLoading = false, error = "Could not load page ${initialPage + 1}: ${e.message}") }
            return
        }

        _state.update {
            it.copy(
                isLoading = false,
                pages = session.pages,
                availablePages = pageStreamingService.cachedPageIndices(session),
                currentPage = initialPage,
                loadingProgress = null,
            )
        }
        if (pageLoadingMode == ComicPageLoadingMode.STREAM) {
            requestPageWindow(initialPage)
        } else {
            startFullSessionPreload(session)
        }
        syncProgress()
    }

    private fun requestPageWindow(currentPage: Int) {
        val session = streamedSession ?: return
        val keep = ((currentPage - 3)..(currentPage + 3)).filter { it in session.pages.indices }
        pageJobs.filterKeys { it !in keep }.values.forEach(Job::cancel)
        pageJobs.keys.retainAll(keep.toSet())
        viewModelScope.launch {
            val cached = pageStreamingService.trimToWindow(session, currentPage)
            _state.update { it.copy(availablePages = cached) }
            requestPages(listOf(currentPage) + keep)
        }
    }

    private fun startFullSessionPreload(session: StreamedComicSession) {
        preloadJob?.cancel()
        preloadJob = viewModelScope.launch {
            session.pages.indices.chunked(4).forEach { batch ->
                coroutineScope {
                    batch.map { pageIndex ->
                        async {
                            loadStreamedPage(session, pageIndex)
                        }
                    }.awaitAll()
                }
            }
        }
    }

    private suspend fun ensureStreamedPage(session: StreamedComicSession, pageIndex: Int): File {
        val book = streamedBook ?: error("No streamed comic is open")
        val file = pageStreamingService.ensurePage(session, pageIndex) { index, destination ->
            aggregatorRepository.downloadComicPage(book, index, destination).getOrThrow()
        }
        _state.update { it.copy(availablePages = it.availablePages + pageIndex) }
        return file
    }

    private suspend fun loadStreamedPage(session: StreamedComicSession, pageIndex: Int) {
        try {
            ensureStreamedPage(session, pageIndex)
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
        }
    }

    override fun onCleared() {
        endStreamingSession()
        super.onCleared()
    }

    private suspend fun resolveBookReadingDirection(): ComicReadingDirection? {
        val cachedBook = runCatching {
            (bookCacheDao.getByIdAndConnection(bookId, bookConnectionId) ?: bookCacheDao.getById(bookId))?.toBook()
        }.getOrNull()
        val book = cachedBook ?: Book(
            id = bookId,
            title = _state.value.title,
            author = _state.value.author.takeIf { it.isNotBlank() },
            source = bookSource,
            connectionId = bookConnectionId,
            primaryFileType = format.name,
        )

        directionOverrides.direction(book.uniqueKey)
            ?.let(::mapProviderReadingDirection)
            ?.let { return it }

        val providerDirection = aggregatorRepository.getComicReadingDirection(book)
            .getOrNull()
            ?.let(::mapProviderReadingDirection)
        if (providerDirection != null) return providerDirection

        return inferComicReadingDirection(book)
    }

    private fun currentBookKey(): String = comicBookKey(bookId, bookSource, bookConnectionId)
}

private data class ComicPreferenceNames(
    val readingDirection: String,
    val progressionMode: String,
    val pageFit: String,
    val spreadMode: String,
)

private data class ComicPreferenceToggles(
    val zoomEnabled: Boolean,
    val autoHideChrome: Boolean,
    val backgroundArgb: Int,
    val volumeButtonNavigation: Boolean,
)

private fun <T : Enum<T>> enumValueOrDefault(value: String, default: T): T =
    default.declaringJavaClass.enumConstants?.firstOrNull { it.name == value } ?: default

internal fun mapProviderReadingDirection(raw: String?): ComicReadingDirection? = when (raw?.uppercase()) {
    "LEFT_TO_RIGHT" -> ComicReadingDirection.LEFT_TO_RIGHT
    "RIGHT_TO_LEFT" -> ComicReadingDirection.RIGHT_TO_LEFT
    "VERTICAL" -> ComicReadingDirection.VERTICAL
    "WEBTOON" -> ComicReadingDirection.WEBTOON
    else -> null
}

internal fun comicBookKey(bookId: String, source: BookSource, connectionId: String?): String =
    "${connectionId ?: source.name}:$bookId"

private fun inferComicReadingDirection(book: Book): ComicReadingDirection? {
    val language = book.language?.trim()?.lowercase()
    if (language in setOf("ja", "jp", "jpn", "japanese") || language?.contains("japanese") == true) {
        return ComicReadingDirection.RIGHT_TO_LEFT
    }

    val searchable = buildString {
        append(book.title).append(' ')
        book.subtitle?.let { append(it).append(' ') }
        book.seriesName?.let { append(it).append(' ') }
        book.libraryName?.let { append(it).append(' ') }
        book.categories.forEach { append(it).append(' ') }
    }.lowercase()

    return when {
        searchable.contains("webtoon") || searchable.contains("vertical") -> ComicReadingDirection.WEBTOON
        searchable.contains("manga") ||
            searchable.contains("マンガ") ||
            searchable.contains("漫画") ||
            searchable.contains("japanese") -> ComicReadingDirection.RIGHT_TO_LEFT
        else -> null
    }
}
