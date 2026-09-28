package com.enve.app.ui.screens

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.view.WindowCompat
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.engine.prefs.ReadNextPosition
import com.enve.app.data.reader.nextBookInSeries
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.ui.screens.reader.HearthPdfChrome
import com.enve.app.viewmodel.ThemeViewModel
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.io.File
import javax.inject.Inject

internal data class PdfReaderUiState(
    val title: String = "",
    val author: String = "",
    val isLoading: Boolean = true,
    val loadingText: String = "Preparing PDF…",
    val loadingProgress: Int? = null,
    val error: String? = null,
    val pageCount: Int = 0,
    val currentPage: Int = 0,
    val currentBitmap: Bitmap? = null,
    val nextInSeries: Book? = null,
)

@AndroidEntryPoint
class PdfReaderActivity : ComponentActivity() {

    @Inject lateinit var prefs: PreferencesManager
    @Inject lateinit var okHttpClient: OkHttpClient
    @Inject lateinit var repository: GrimmoryRepository
    @Inject lateinit var aggregatorRepository: com.enve.app.data.repository.AggregatorRepository
    @Inject lateinit var bookCacheDao: BookCacheDao
    @Inject lateinit var epdRefreshManager: com.enve.app.eink.EpdRefreshManager
    @Inject lateinit var lastOpenedBookStore: LastOpenedBookStore
    @Inject lateinit var hearthPreferences: com.enve.engine.prefs.PreferencesFacade
    @Inject lateinit var audioPlaybackManager: com.enve.app.playback.AudioPlaybackManager

    private var uiState by mutableStateOf(PdfReaderUiState())
    private var bookId: String = ""
    private var bookSource: BookSource = BookSource.GRIMMORY
    private var bookConnectionId: String? = null
    private var renderer: PdfRenderer? = null
    private var descriptor: ParcelFileDescriptor? = null
    private var openedFile: File? = null
    private val themeViewModel: ThemeViewModel by viewModels()

    companion object {
        private const val EXTRA_BOOK_ID = "bookId"
        private const val EXTRA_BOOK_SOURCE = "bookSource"
        private const val EXTRA_CONNECTION_ID = "connectionId"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_AUTHOR = "author"
        private const val EXTRA_LOCATOR = "locator"

        fun createIntent(
            context: Context,
            bookId: String,
            bookSource: BookSource,
            connectionId: String? = null,
            title: String,
            author: String,
            locator: String?,
        ): Intent = Intent(context, PdfReaderActivity::class.java).apply {
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

        uiState = uiState.copy(title = title, author = author)
        lifecycleScope.launch {
            val nextInSeries = bookCacheDao.nextBookInSeries(bookId, bookConnectionId)
            uiState = uiState.copy(nextInSeries = nextInSeries)
        }

        setContent {
            val themeState by themeViewModel.themeState.collectAsStateWithLifecycle()
            val uiTextScale by hearthPreferences.uiTextScale.collectAsStateWithLifecycle(initialValue = 1f)
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
                    onBack = { finish() },
                    onPrevious = { showPage(uiState.currentPage - 1) },
                    onNext = { showPage(uiState.currentPage + 1) },
                    onSeekPage = { showPage(it) },
                    readNextEnabled = readNextEnabled,
                    readNextPosition = readNextPosition,
                    onReadNext = openNext,
                    restReminder = restReminder,
                )
            }
        }

        lifecycleScope.launch {
            openPdf(locator)
        }
    }

    private suspend fun openPdf(locator: String?) {
        uiState = uiState.copy(isLoading = true, loadingText = "Downloading PDF…", error = null)

        val downloadUrl = aggregatorRepository.getEbookDownloadUrl(bookId, bookSource, bookConnectionId)
            ?: repository.getEbookDownloadUrl(bookId)

        val file = try {
            downloadReaderFile(
                cacheDir = cacheDir,
                okHttpClient = okHttpClient,
                bookId = bookId,
                format = ReaderFormat.PDF,
                downloadUrl = downloadUrl,
                contentResolver = contentResolver,
                onStatus = { status -> uiState = uiState.copy(loadingText = status) },
                onProgress = { progress -> uiState = uiState.copy(loadingProgress = progress) },
            )
        } catch (e: Exception) {
            uiState = uiState.copy(isLoading = false, error = "Download failed: ${e.message}")
            return
        }

        if (!file.looksLikePdfFile()) {
            uiState = uiState.copy(isLoading = false, error = "Downloaded file is not a valid PDF.")
            return
        }

        openedFile = file

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

        uiState = uiState.copy(pageCount = totalPages)
        val initialPage = resolveInitialPage(locator, totalPages)
        showPage(initialPage)
    }

    private suspend fun resolveInitialPage(argsLocator: String?, totalPages: Int): Int {
        val lastIndex = (totalPages - 1).coerceAtLeast(0)
        val fromArgs = parseSavedPage(argsLocator, ReaderFormat.PDF).coerceAtLeast(0)

        val cached = runCatching {
            bookCacheDao.getByIdAndConnection(bookId, bookConnectionId) ?: bookCacheDao.getById(bookId)
        }.getOrNull()
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

    private fun showPage(pageIndex: Int) {
        val pdfRenderer = renderer ?: return
        val clamped = pageIndex.coerceIn(0, (pdfRenderer.pageCount - 1).coerceAtLeast(0))

        lifecycleScope.launch {
            uiState = uiState.copy(isLoading = true, loadingText = "Rendering page ${clamped + 1}…", error = null)
            val bitmap = withContext(Dispatchers.IO) {
                pdfRenderer.openPage(clamped).use { page ->
                    val targetWidth = (resources.displayMetrics.widthPixels * 1.25f).toInt().coerceAtLeast(1200)
                    val scale = targetWidth.toFloat() / page.width.toFloat().coerceAtLeast(1f)
                    val targetHeight = (page.height * scale).toInt().coerceAtLeast(1)
                    Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888).also { bmp ->
                        bmp.eraseColor(android.graphics.Color.WHITE)
                        page.render(bmp, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    }
                }
            }

            uiState = uiState.copy(
                isLoading = false,
                currentPage = clamped,
                currentBitmap = bitmap,
                loadingProgress = null,
            )

            if (themeViewModel.themeState.value.einkProfile.active) {
                epdRefreshManager.requestPageTurnRefresh(window.decorView, isFullPageBoundary = true)
            }

            syncProgress()
        }
    }

    private fun syncProgress() {
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
        if (uiState.pageCount > 0) syncProgress()
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
                    ReaderPageKeyDirection.FORWARD -> showPage(uiState.currentPage + 1)
                    ReaderPageKeyDirection.BACKWARD -> showPage(uiState.currentPage - 1)
                }
            }
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onDestroy() {
        super.onDestroy()
        renderer?.close()
        descriptor?.close()
        uiState.currentBitmap?.recycle()
    }
}
