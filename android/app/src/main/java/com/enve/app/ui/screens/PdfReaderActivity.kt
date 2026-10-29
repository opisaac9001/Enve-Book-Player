package com.enve.app.ui.screens

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.Rect
import android.graphics.pdf.PdfRenderer
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.view.WindowCompat
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.reader.PdfReadingLayout
import com.enve.core.reader.PdfSpread
import com.enve.engine.prefs.ReadNextPosition
import com.enve.engine.theme.HearthPaletteStyle
import com.enve.app.data.reader.nextBookInSeries
import com.enve.app.ui.screens.reader.HearthPdfChrome
import com.enve.app.viewmodel.ThemeViewModel
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.concurrent.Executors
import kotlin.math.roundToInt

internal data class PdfReaderUiState(
    val title: String = "",
    val author: String = "",
    val isLoading: Boolean = true,
    val loadingText: String = "Preparing PDF…",
    val loadingProgress: Int? = null,
    val error: String? = null,
    val pageCount: Int = 0,
    val currentPage: Int = 0,
    val spread: PdfSpread = PdfSpread(0, 0),
    val layout: PdfReadingLayout = PdfReadingLayout(),
    val currentBitmap: Bitmap? = null,
    val appearanceVisible: Boolean = false,
    val nextInSeries: Book? = null,
)

@AndroidEntryPoint
class PdfReaderActivity : ComponentActivity() {
    @javax.inject.Inject lateinit var profileCoordinator: com.enve.app.profiles.ProfileSwitchCoordinator
    @javax.inject.Inject lateinit var profileLifecycle: com.enve.app.profiles.ProfileLifecycleRegistry
    private lateinit var profileBinding: com.enve.app.profiles.ProfileActivityBinding

    private val okHttpClient get() = profileBinding.runtime.component.httpClient()
    private val repository get() = profileBinding.runtime.component.grimmoryRepository()
    private val aggregatorRepository get() = profileBinding.runtime.component.aggregator()
    private val bookCacheDao get() = profileBinding.runtime.component.bookCacheDao()
    private val epdRefreshManager get() = profileBinding.runtime.component.epdRefreshManager()
    private val lastOpenedBookStore get() = profileBinding.runtime.component.lastOpenedBookStore()
    private val hearthPreferences get() = profileBinding.runtime.component.preferencesFacade()
    private val audioPlaybackManager get() = profileBinding.runtime.component.audioPlayback()
    private val pdfReadingPreferences get() = profileBinding.runtime.component.pdfReadingPreferencesStore()

    private var uiState by mutableStateOf(PdfReaderUiState())
    private var bookId: String = ""
    private var bookSource: BookSource = BookSource.GRIMMORY
    private var bookConnectionId: String? = null
    private val bookKey get() = Book(id = bookId, title = "", source = bookSource, connectionId = bookConnectionId).uniqueKey
    private var renderer: PdfRenderer? = null
    private var descriptor: ParcelFileDescriptor? = null
    private val renderDispatcher = Executors.newSingleThreadExecutor().asCoroutineDispatcher()
    private var renderJob: Job? = null
    private var renderGeneration = 0
    private var movedSinceOpen = false
    private val themeViewModel: ThemeViewModel by viewModels { profileBinding.factory }

    companion object {
        private const val EXTRA_BOOK_ID = "bookId"
        private const val EXTRA_BOOK_SOURCE = "bookSource"
        private const val EXTRA_CONNECTION_ID = "connectionId"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_AUTHOR = "author"
        private const val EXTRA_LOCATOR = "locator"
        private const val STATE_PAGE = "currentPage"

        fun createIntent(
            context: Context,
            bookId: String,
            bookSource: BookSource,
            connectionId: String? = null,
            title: String,
            author: String,
            locator: String?,
        ): Intent = Intent(context, PdfReaderActivity::class.java).apply {
            com.enve.app.profiles.ProfileActivityBinding.capture(context, this)
            putExtra(EXTRA_BOOK_ID, bookId)
            putExtra(EXTRA_BOOK_SOURCE, bookSource.name)
            if (connectionId != null) putExtra(EXTRA_CONNECTION_ID, connectionId)
            putExtra(EXTRA_TITLE, title)
            putExtra(EXTRA_AUTHOR, author)
            if (locator != null) putExtra(EXTRA_LOCATOR, locator)
        }
    }

    @Suppress("DEPRECATION")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        profileBinding = com.enve.app.profiles.ProfileActivityBinding.attach(this, profileCoordinator, profileLifecycle) {
            checkpointForProfileSwitch()
        } ?: run { finish(); return }

        WindowCompat.setDecorFitsSystemWindows(window, false)

        window.statusBarColor = android.graphics.Color.BLACK
        window.navigationBarColor = android.graphics.Color.BLACK

        bookId = intent.getStringExtra(EXTRA_BOOK_ID) ?: run {
            finish()
            return
        }
        bookSource = intent.getStringExtra(EXTRA_BOOK_SOURCE)?.let { runCatching { BookSource.valueOf(it) }.getOrNull() } ?: BookSource.GRIMMORY
        bookConnectionId = intent.getStringExtra(EXTRA_CONNECTION_ID)
        if (savedInstanceState == null) {
            lifecycleScope.launch { lastOpenedBookStore.record(bookId, bookSource, bookConnectionId) }
        }
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val author = intent.getStringExtra(EXTRA_AUTHOR).orEmpty()
        val locator = intent.getStringExtra(EXTRA_LOCATOR)
        val restoredPage = savedInstanceState?.takeIf { it.containsKey(STATE_PAGE) }?.getInt(STATE_PAGE)

        uiState = uiState.copy(title = title, author = author)
        lifecycleScope.launch {
            val nextInSeries = bookCacheDao.nextBookInSeries(bookId, bookConnectionId)
            uiState = uiState.copy(nextInSeries = nextInSeries)
        }

        setContent {
            val themeState by themeViewModel.themeState.collectAsStateWithLifecycle()
            val uiTextScale by hearthPreferences.uiTextScale.collectAsStateWithLifecycle(initialValue = 1f)
            val paletteStyle by hearthPreferences.paletteStyle.collectAsStateWithLifecycle(
                initialValue = HearthPaletteStyle.PARCHMENT,
            )
            val readNextEnabled by hearthPreferences.readNextEnabled.collectAsStateWithLifecycle(initialValue = true)
            val readNextPosition by hearthPreferences.readNextPosition.collectAsStateWithLifecycle(
                initialValue = ReadNextPosition.BOTTOM,
            )
            val restReminder = com.enve.app.ui.screens.reader.rememberReaderRestReminderSpec(hearthPreferences)
            val openNext: (Book) -> Unit = { next ->
                startActivity(readerIntentForBook(next))
                finish()
            }
            com.enve.hearth.design.HearthUiTextScale(uiTextScale) {
                HearthPdfChrome(
                    state = uiState,
                    einkActive = themeState.einkProfile.active,
                    paletteStyle = paletteStyle,
                    onBack = { finish() },
                    onPrevious = { turnSpread(forward = false) },
                    onNext = { turnSpread(forward = true) },
                    onSeekPage = { selectPage(it) },
                    onOpenAppearance = { uiState = uiState.copy(appearanceVisible = true) },
                    onCloseAppearance = { uiState = uiState.copy(appearanceVisible = false) },
                    onLayoutChange = { updateLayout(it) },
                    readNextEnabled = readNextEnabled,
                    readNextPosition = readNextPosition,
                    onReadNext = openNext,
                    restReminder = restReminder,
                )
            }
        }

        lifecycleScope.launch {
            openPdf(locator, restoredPage)
        }
    }

    private suspend fun openPdf(locator: String?, restoredPage: Int?) {
        uiState = uiState.copy(isLoading = true, loadingText = "Downloading PDF…", error = null)

        val downloadUrl = aggregatorRepository.getEbookDownloadUrl(bookId, bookSource, bookConnectionId)
            ?: repository.getEbookDownloadUrl(bookId)

        val file = try {
            withContext(com.enve.core.data.remote.ConnectionScope.asContextElement(bookConnectionId)) {
                downloadReaderFile(
                    cacheDir = profileBinding.runtime.component.storageLocations().cacheDirectory,
                    okHttpClient = okHttpClient,
                    bookId = bookId,
                    format = ReaderFormat.PDF,
                    downloadUrl = downloadUrl,
                    contentResolver = contentResolver,
                    onStatus = { status -> uiState = uiState.copy(loadingText = status) },
                    onProgress = { progress -> uiState = uiState.copy(loadingProgress = progress) },
                )
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            uiState = uiState.copy(isLoading = false, error = "Download failed: ${e.message}")
            return
        }

        if (!file.looksLikePdfFile()) {
            uiState = uiState.copy(isLoading = false, error = "Downloaded file is not a valid PDF.")
            return
        }

        try {
            descriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(descriptor!!)
        } catch (e: Exception) {
            uiState = uiState.copy(isLoading = false, error = "Could not open PDF: ${e.message}")
            return
        }

        val totalPages = renderer?.pageCount ?: 0
        if (totalPages <= 0) {
            uiState = uiState.copy(isLoading = false, error = "PDF has no readable pages.")
            return
        }

        val layout = pdfReadingPreferences.layout(bookKey)
        uiState = uiState.copy(pageCount = totalPages, layout = layout)
        val initialPage = restoredPage?.coerceIn(0, totalPages - 1) ?: resolveInitialPage(locator, totalPages)
        selectPage(initialPage, userInitiated = false)
    }

    private suspend fun resolveInitialPage(argsLocator: String?, totalPages: Int): Int {
        val lastIndex = (totalPages - 1).coerceAtLeast(0)
        val fromArgs = parseSavedPage(argsLocator, ReaderFormat.PDF).coerceAtLeast(0)

        val cached = runCatching {
            bookCacheDao.getByIdAndConnection(bookId, bookConnectionId) ?: bookCacheDao.getById(bookId)
        }.getOrNull()
        val pending = profileBinding.runtime.component.database().pendingProgressPushDao()
            .get(bookId, bookSource.name, bookConnectionId.orEmpty())
        commandReaderPage(cached, pending, ReaderFormat.PDF, totalPages, bookKey, bookSource.name, bookConnectionId)?.let { return it }
        val fromLocalLocator = cached?.epubLocator
            ?.let { parseSavedPage(it, ReaderFormat.PDF).coerceAtLeast(0) }
            ?: 0
        val fromLocalProgress = cached?.let { pageIndexFromProgress(it.epubProgress ?: it.readProgress, totalPages) } ?: 0

        val serverSnapshot = runCatching {
            aggregatorRepository.fetchEbookProgress(
                Book(
                    id = bookId,
                    title = "",
                    source = bookSource,
                    connectionId = bookConnectionId,
                )
            ).getOrNull()
        }.getOrNull()
        val fromServerLocator = serverSnapshot?.locatorJson
            ?.let { parseSavedPage(it, ReaderFormat.PDF).coerceAtLeast(0) }
            ?: 0
        val fromServerProgress = pageIndexFromProgress(serverSnapshot?.percentage, totalPages)

        return maxOf(fromArgs, fromLocalLocator, fromLocalProgress, fromServerLocator, fromServerProgress)
            .coerceIn(0, lastIndex)
    }

    private fun selectPage(pageIndex: Int, userInitiated: Boolean = true) {
        val pageCount = uiState.pageCount
        if (pageCount <= 0) return
        val page = pageIndex.coerceIn(0, pageCount - 1)
        val spread = uiState.layout.spreadContaining(page, pageCount)
        uiState = uiState.copy(currentPage = page, spread = spread)
        movedSinceOpen = movedSinceOpen || userInitiated
        renderSpread(spread)
        syncProgress()
    }

    private fun turnSpread(forward: Boolean) {
        val pageCount = uiState.pageCount
        if (pageCount <= 0) return
        val target = if (forward) {
            uiState.layout.pageAfterTurningForward(uiState.currentPage, pageCount)
        } else {
            uiState.layout.pageAfterTurningBackward(uiState.currentPage, pageCount)
        }
        if (target != null) selectPage(target)
    }

    private fun updateLayout(layout: PdfReadingLayout) {
        if (layout == uiState.layout) return
        val pageCount = uiState.pageCount
        val spread = if (pageCount > 0) layout.spreadContaining(uiState.currentPage, pageCount) else uiState.spread
        uiState = uiState.copy(layout = layout, spread = spread)
        if (pageCount > 0) renderSpread(spread)
        profileBinding.runtime.component.resources().scope.launch { pdfReadingPreferences.save(bookKey, layout) }
    }

    private fun renderSpread(spread: PdfSpread) {
        val pdfRenderer = renderer ?: return
        val generation = ++renderGeneration
        renderJob?.cancel()
        renderJob = lifecycleScope.launch {
            uiState = uiState.copy(
                isLoading = true,
                loadingText = "Rendering ${pageLabel(spread.pages.toList(), uiState.pageCount).lowercase()}…",
                error = null,
            )
            val targetWidth = (resources.displayMetrics.widthPixels * 1.25f).toInt().coerceAtLeast(1200)
            val rendered = arrayOfNulls<Bitmap>(1)
            try {
                withContext(renderDispatcher) {
                    rendered[0] = renderSpreadBitmap(pdfRenderer, spread, targetWidth)
                }
                if (generation != renderGeneration) return@launch
                uiState = uiState.copy(
                    isLoading = false,
                    currentBitmap = rendered[0],
                    loadingProgress = null,
                )
                rendered[0] = null
                if (themeViewModel.themeState.value.einkProfile.active) {
                    epdRefreshManager.requestPageTurnRefresh(window.decorView, isFullPageBoundary = true)
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (generation == renderGeneration) {
                    uiState = uiState.copy(isLoading = false, error = "Could not render PDF: ${e.message}")
                }
            } finally {
                rendered[0]?.recycle()
            }
        }
    }

    private fun renderSpreadBitmap(pdfRenderer: PdfRenderer, spread: PdfSpread, targetWidth: Int): Bitmap {
        val pageSizes = spread.pages.map { index ->
            pdfRenderer.openPage(index).use { page -> page.width.coerceAtLeast(1) to page.height.coerceAtLeast(1) }
        }
        val aspectSum = pageSizes.sumOf { (width, height) -> width.toDouble() / height }
        val height = (targetWidth / aspectSum).roundToInt().coerceAtLeast(1)
        val widths = pageSizes.map { (width, pageHeight) -> (height * width.toDouble() / pageHeight).roundToInt().coerceAtLeast(1) }
        val bitmap = Bitmap.createBitmap(widths.sum(), height, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.WHITE)
        var left = 0
        spread.pages.forEachIndexed { slot, index ->
            val width = widths[slot]
            pdfRenderer.openPage(index).use { page ->
                val transform = Matrix().apply {
                    setScale(width / page.width.toFloat(), height / page.height.toFloat())
                    postTranslate(left.toFloat(), 0f)
                }
                page.render(bitmap, Rect(left, 0, left + width, height), transform, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            }
            left += width
        }
        return bitmap
    }

    private suspend fun checkpointForProfileSwitch() {
        if (uiState.pageCount <= 0 || bookId.isBlank() || !movedSinceOpen) return
        val progress = (uiState.currentPage + 1).toFloat() / uiState.pageCount
        val locator = buildPageLocator(ReaderFormat.PDF, uiState.currentPage)
        val now = System.currentTimeMillis()
        bookCacheDao.updateUnifiedProgress(bookId, bookConnectionId, progress, -1L, locator, now)
        if (aggregatorRepository.serverSyncEnabled) profileBinding.runtime.component.database().pendingProgressPushDao().upsert(com.enve.core.data.local.PendingProgressPush(
            bookId = bookId,
            source = bookSource.name,
            connectionKey = bookConnectionId.orEmpty(),
            mediaType = com.enve.core.data.model.AppMediaType.EBOOK.name,
            percentage = progress,
            isFinished = progress >= 1f,
            createdAt = now,
        ))
    }

    private fun syncProgress() {
        if (!::profileBinding.isInitialized || profileBinding.retired || !movedSinceOpen) return
        val totalPages = uiState.pageCount.coerceAtLeast(1)
        val percentage = (uiState.currentPage + 1).toFloat() / totalPages.toFloat()
        val locator = buildPageLocator(ReaderFormat.PDF, uiState.currentPage)
        lifecycleScope.launch {
            runCatching {
                if (bookConnectionId == null && bookSource == BookSource.GRIMMORY) {
                    repository.syncEbookProgress(bookId, percentage, locator, uiState.currentPage + 1)
                } else {
                    aggregatorRepository.syncEbookProgress(
                        bookId = bookId,
                        source = bookSource,
                        percentage = percentage,
                        locator = locator,
                        page = uiState.currentPage + 1,
                        pageCount = totalPages,
                        connectionId = bookConnectionId,
                    )
                }
            }
        }
    }

    override fun onPause() {
        super.onPause()
        if (!::profileBinding.isInitialized || profileBinding.retired || !movedSinceOpen) return
        if (uiState.pageCount > 0) syncProgress()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        if (uiState.pageCount > 0) outState.putInt(STATE_PAGE, uiState.currentPage)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        if (uiState.pageCount > 0) renderSpread(uiState.spread)
    }

    @SuppressLint("RestrictedApi")
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val direction = ReaderHardwareKeyPolicy.directionFor(
            keyCode = event.keyCode,
            volumeButtonNavigation = false,
            audioActive = audioPlaybackManager.state.value.isPlaying,
        )
        if (direction != null) {
            if (ReaderHardwareKeyPolicy.shouldTriggerTurn(event.action, event.repeatCount)) {
                when (direction) {
                    ReaderPageKeyDirection.FORWARD -> turnSpread(forward = true)
                    ReaderPageKeyDirection.BACKWARD -> turnSpread(forward = false)
                }
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        super.onDestroy()
        renderJob?.cancel()
        val pdfRenderer = renderer
        val fileDescriptor = descriptor
        renderer = null
        descriptor = null
        renderDispatcher.executor.execute {
            pdfRenderer?.close()
            fileDescriptor?.close()
        }
        renderDispatcher.close()
        uiState.currentBitmap?.recycle()
    }
}
