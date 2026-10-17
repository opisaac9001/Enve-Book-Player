package com.enve.app.viewmodel

import android.content.Context
import android.graphics.BitmapFactory
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
import com.enve.app.ui.screens.readComicArchiveDirection
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject

enum class ComicReadingDirection(val label: String) {
    LEFT_TO_RIGHT("LTR"),
    RIGHT_TO_LEFT("RTL"),
    VERTICAL("Vertical"),
    WEBTOON("Webtoon");

    val isStrip: Boolean
        get() = this == VERTICAL || this == WEBTOON
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
    val directionOverride: ComicReadingDirection? = null,
    val defaultSettings: ComicReaderSettings = ComicReaderSettings(),
    val isLoading: Boolean = true,
    val loadingText: String = "Preparing comic...",
    val loadingProgress: Int? = null,
    val error: String? = null,
    val pages: List<File> = emptyList(),
    val availablePages: Set<Int> = emptySet(),
    val widePages: Set<Int> = emptySet(),
    val currentPage: Int = 0,
    val bookmarks: Set<Int> = emptySet(),
    val showSettingsSheet: Boolean = false,
    val nextInSeries: Book? = null,
    val tapZoneWidth: Float = 0.20f,
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
    private val storageLocations: com.enve.core.data.local.ProfileStorageLocations,
    private val database: com.enve.app.data.local.ReaderDatabase,
) : ViewModel() {

    private var preferenceSettings = ComicReaderSettings()
    private var directionOverride: ComicReadingDirection? = null
    private var autoDirection: ComicReadingDirection? = null
    private var archiveDirection: ComicReadingDirection? = null
    private var pageEntries: List<List<Int>> = emptyList()
    private var movedSinceOpen = false

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
    private var measureJob: Job? = null
    private var resumeJob: Job? = null
    private val measuredPages = mutableSetOf<Int>()

    init {
        viewModelScope.launch {
            prefs.readerTapZoneWidth.collect { width -> _state.update { it.copy(tapZoneWidth = width) } }
        }
        viewModelScope.launch {
            val namesFlow = combine(
                prefs.comicProgressionMode,
                prefs.comicPageFit,
                prefs.comicSpreadMode,
                directionOverrides.defaultDirection,
            ) { progression, fit, spread, direction ->
                ComicPreferenceNames(progression, fit, spread, direction)
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
                    readingDirection = mapProviderReadingDirection(names.direction) ?: ComicReadingDirection.LEFT_TO_RIGHT,
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
                preferenceSettings = settings
                publishSettings()
            }
        }
    }

    private fun publishSettings() {
        _state.update {
            it.copy(
                directionOverride = directionOverride,
                defaultSettings = preferenceSettings,
                settings = resolveComicReaderSettings(preferenceSettings, directionOverride, autoDirection),
            )
        }
    }

    private fun applyReadingDirection() {
        publishSettings()
    }

    fun initialize(args: ComicReaderArgs) {
        val sameBook = bookId == args.bookId &&
            bookSource == args.bookSource &&
            bookConnectionId == args.connectionId
        if (initialized && sameBook) return
        endStreamingSession()
        initialized = true
        movedSinceOpen = false
        if (!sameBook) {
            directionOverride = null
            autoDirection = null
            archiveDirection = null
            pageEntries = emptyList()
            publishSettings()
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
                widePages = emptySet(),
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
        preferenceSettings = settings
        publishSettings()
        val saved = preferenceSettings
        viewModelScope.launch {
            prefs.saveComicReaderPreferences(
                progressionMode = saved.progressionMode.name,
                pageFit = saved.pageFit.name,
                spreadMode = saved.spreadMode.name,
                zoomEnabled = saved.zoomEnabled,
                autoHideChrome = saved.autoHideChrome,
                backgroundArgb = saved.backgroundTheme.argb,
                volumeButtonNav = saved.volumeButtonNavigation,
                brightness = saved.brightness,
                backgroundTheme = saved.backgroundTheme.name,
            )
        }
    }

    fun setDefaultReadingDirection(direction: ComicReadingDirection) {
        updateSettings(preferenceSettings.copy(
            readingDirection = direction,
            progressionMode = if (direction.isStrip) ComicProgressionMode.VERTICAL_STRIP else ComicProgressionMode.PAGED,
        ))
        viewModelScope.launch { directionOverrides.saveDefaultDirection(direction.name) }
    }

    fun setReadingDirection(direction: ComicReadingDirection?) {
        if (direction == directionOverride) return
        directionOverride = direction
        applyReadingDirection()
        val bookKey = currentBookKey()
        viewModelScope.launch {
            if (direction != null) {
                directionOverrides.save(bookKey, direction.name)
                return@launch
            }
            directionOverrides.clear(bookKey)
            if (autoDirection == null) {
                autoDirection = resolveAutoReadingDirection()
                if (directionOverride == null) applyReadingDirection()
            }
        }
    }

    fun updatePageEntries(entries: List<List<Int>>) {
        pageEntries = entries
    }

    fun showPage(pageIndex: Int) {
        val current = _state.value
        if (current.pages.isEmpty()) return
        val clamped = pageIndex.coerceIn(0, current.pages.lastIndex)
        if (clamped == current.currentPage) return
        movedSinceOpen = true
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
        resumeJob?.cancel()
        resumeJob = null
        preloadJob?.cancel()
        preloadJob = null
        measureJob?.cancel()
        measureJob = null
        measuredPages.clear()
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

    suspend fun checkpointForProfileSwitch() {
        val current = _state.value
        if (bookId.isNotBlank() && current.pages.isNotEmpty() && movedSinceOpen) {
            val progress = comicReadProgress(current.currentPage, current.pages.size, pageEntries)
            val locator = buildPageLocator(format, current.currentPage)
            val now = System.currentTimeMillis()
            bookCacheDao.updateUnifiedProgress(bookId, bookConnectionId, progress, -1L, locator, now)
            if (aggregatorRepository.serverSyncEnabled) database.pendingProgressPushDao().upsert(com.enve.core.data.local.PendingProgressPush(
                bookId = bookId,
                source = bookSource.name,
                connectionKey = bookConnectionId.orEmpty(),
                mediaType = com.enve.core.data.model.AppMediaType.EBOOK.name,
                percentage = progress,
                isFinished = progress >= 1f,
                createdAt = now,
            ))
        }
        endStreamingSession()
    }

    fun syncProgress() {
        val current = _state.value
        if (bookId.isBlank() || current.pages.isEmpty() || !movedSinceOpen) return
        val totalPages = current.pages.size
        val percentage = comicReadProgress(current.currentPage, totalPages, pageEntries)
        val locator = buildPageLocator(format, current.currentPage)
        viewModelScope.launch {
            try {
                if (bookConnectionId == null && bookSource == BookSource.GRIMMORY) {
                    repository.syncEbookProgress(bookId, percentage, locator, current.currentPage + 1)
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

    private suspend fun resolveInitialPage(argsLocator: String?, lastIndex: Int, includeServer: Boolean = true): Int {

        val fromArgs = parseSavedPage(argsLocator, format).coerceAtLeast(0)
        val cached = bookCacheDao.getByIdAndConnection(bookId, bookConnectionId)
            ?: bookCacheDao.getById(bookId)
        val fromLocal = cached?.epubLocator
            ?.let { parseSavedPage(it, format).coerceAtLeast(0) }
            ?: 0
        val fromLocalProgress = cached?.let { pageIndexFromProgress(it.epubProgress ?: it.readProgress, lastIndex + 1) } ?: 0
        val localPage = maxOf(fromArgs, fromLocal, fromLocalProgress).coerceIn(0, lastIndex)
        if (!includeServer) return localPage
        val serverSnapshot = try {
            val stub = Book(
                id = bookId,
                title = "",
                source = bookSource,
                connectionId = bookConnectionId,
            )
            aggregatorRepository.fetchEbookProgress(stub).getOrNull()
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (_: Exception) {
            null
        }
        val fromServer = serverSnapshot?.locatorJson
            ?.let { parseSavedPage(it, format).coerceAtLeast(0) }
            ?: 0
        val fromServerProgress = pageIndexFromProgress(serverSnapshot?.percentage, lastIndex + 1)
        return maxOf(localPage, fromServer, fromServerProgress).coerceIn(0, lastIndex)
    }

    private suspend fun openComic(locator: String?) {
        _state.update { it.copy(isLoading = true, loadingText = "Downloading ${format.displayName}...", error = null) }

        val offlineFile = comicOfflineService.getLocalFile(bookId)
        archiveDirection = offlineFile?.let { file ->
            withContext(Dispatchers.IO) { readComicArchiveDirection(file) }
        }
        directionOverride = directionOverrides.direction(currentBookKey())?.let(::mapProviderReadingDirection)
        if (directionOverride == null) autoDirection = resolveAutoReadingDirection(includeProvider = offlineFile == null)
        applyReadingDirection()
        Log.d("ComicReader", "Reading direction for $bookId: override=$directionOverride auto=$autoDirection")

        if (offlineFile != null && offlineFile.exists() && offlineFile.length() > 0L) {
            val pages = try {
                loadOrExtractComicPages(
                    cacheDir = storageLocations.cacheDirectory,
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
            val initialPage = resolveInitialPage(locator, pages.lastIndex, includeServer = false)
            _state.update {
                it.copy(isLoading = false, pages = pages, currentPage = initialPage,
                    loadingProgress = null, availablePages = pages.indices.toSet())
            }
            measureExtractedPages(pages)
            val bookKey = currentBookKey()
            resumeJob = viewModelScope.launch {
                val serverPage = async { resolveInitialPage(locator, pages.lastIndex) }
                val direction = if (directionOverride == null) resolveAutoReadingDirection() else null
                val resumedPage = serverPage.await()
                if (currentBookKey() == bookKey) {
                    if (!movedSinceOpen) _state.update { it.copy(currentPage = resumedPage) }
                    if (directionOverride == null) {
                        autoDirection = direction
                        applyReadingDirection()
                    }
                }
            }
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
                cacheDir = storageLocations.cacheDirectory,
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

        archiveDirection = withContext(Dispatchers.IO) { readComicArchiveDirection(archive) }
        autoDirection = autoDirection ?: archiveDirection
        applyReadingDirection()
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
        measureExtractedPages(pages)
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
        if (pageIndex !in measuredPages) {
            val wide = withContext(Dispatchers.IO) { isWidePage(file) }
            measuredPages += pageIndex
            if (wide) _state.update { it.copy(widePages = it.widePages + pageIndex) }
        }
        return file
    }

    private fun measureExtractedPages(pages: List<File>) {
        measureJob?.cancel()
        measureJob = viewModelScope.launch {
            val wide = withContext(Dispatchers.IO) {
                pages.indices.filterTo(mutableSetOf()) { isWidePage(pages[it]) }
            }
            _state.update { it.copy(widePages = wide) }
        }
    }

    private fun isWidePage(file: File): Boolean {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        return bounds.outWidth > bounds.outHeight
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

    private suspend fun resolveAutoReadingDirection(includeProvider: Boolean = true): ComicReadingDirection? {
        val cachedBook = (bookCacheDao.getByIdAndConnection(bookId, bookConnectionId) ?: bookCacheDao.getById(bookId))?.toBook()
        val book = cachedBook ?: Book(
            id = bookId,
            title = _state.value.title,
            author = _state.value.author.takeIf { it.isNotBlank() },
            source = bookSource,
            connectionId = bookConnectionId,
            primaryFileType = format.name,
        )

        val bookKey = currentBookKey()
        val providerDirection = if (includeProvider) {
            val result = aggregatorRepository.getComicReadingDirection(book)
                .onFailure { Log.w("ComicReader", "Provider reading direction unavailable for $bookId: ${it.javaClass.simpleName}") }
            if (result.isSuccess) {
                val direction = mapProviderReadingDirection(result.getOrNull())
                directionOverrides.saveProviderDirection(bookKey, direction?.name)
                direction
            } else mapProviderReadingDirection(directionOverrides.providerDirection(bookKey))
        } else mapProviderReadingDirection(directionOverrides.providerDirection(bookKey))
        return providerDirection ?: archiveDirection
    }

    private fun currentBookKey(): String = comicBookKey(bookId, bookSource, bookConnectionId)
}

private data class ComicPreferenceNames(
    val progressionMode: String,
    val pageFit: String,
    val spreadMode: String,
    val direction: String,
)

private data class ComicPreferenceToggles(
    val zoomEnabled: Boolean,
    val autoHideChrome: Boolean,
    val backgroundArgb: Int,
    val volumeButtonNavigation: Boolean,
)

private fun <T : Enum<T>> enumValueOrDefault(value: String, default: T): T =
    default.declaringJavaClass.enumConstants?.firstOrNull { it.name == value } ?: default

internal fun mapProviderReadingDirection(raw: String?): ComicReadingDirection? = when (raw?.trim()?.uppercase()) {
    "LEFT_TO_RIGHT" -> ComicReadingDirection.LEFT_TO_RIGHT
    "RIGHT_TO_LEFT" -> ComicReadingDirection.RIGHT_TO_LEFT
    "VERTICAL" -> ComicReadingDirection.VERTICAL
    "WEBTOON" -> ComicReadingDirection.WEBTOON
    else -> null
}

internal fun comicBookKey(bookId: String, source: BookSource, connectionId: String?): String =
    "${connectionId ?: source.name}:$bookId"

internal fun resolveComicReaderSettings(
    defaults: ComicReaderSettings,
    bookOverride: ComicReadingDirection?,
    metadataDirection: ComicReadingDirection?,
): ComicReaderSettings {
    val direction = bookOverride ?: metadataDirection
    return defaults.copy(
        readingDirection = direction ?: defaults.readingDirection,
        progressionMode = direction?.let {
            if (it.isStrip) ComicProgressionMode.VERTICAL_STRIP else ComicProgressionMode.PAGED
        } ?: defaults.progressionMode,
    )
}

internal fun comicReadProgress(currentPage: Int, pageCount: Int, entries: List<List<Int>>): Float {
    val lastVisiblePage = entries.firstOrNull { currentPage in it }?.max() ?: currentPage
    return ((lastVisiblePage + 1).toFloat() / pageCount.coerceAtLeast(1)).coerceIn(0f, 1f)
}
