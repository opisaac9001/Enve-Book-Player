package com.enve.app.ui.screens

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.os.Bundle
import android.os.ParcelFileDescriptor
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.core.view.WindowCompat
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.LastOpenedBookStore
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.app.data.reader.nextBookInSeries
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.app.ui.screens.reader.HearthPdfChrome
import com.enve.app.ui.theme.EnveTheme
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
        const val EXTRA_HEARTH_CHROME = "hearthChrome"

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
            uiState = uiState.copy(nextInSeries = bookCacheDao.nextBookInSeries(bookId, bookConnectionId))
        }

        setContent {
            val themeState by themeViewModel.themeState.collectAsStateWithLifecycle()
            val uiTextScale by hearthPreferences.uiTextScale.collectAsStateWithLifecycle(initialValue = 1f)
            val useHearthChrome = remember { intent.getBooleanExtra(EXTRA_HEARTH_CHROME, false) }
            val openNext: (Book) -> Unit = { next ->
                startActivity(readerIntentForBook(next, hearthChrome = useHearthChrome))
                finish()
            }
            com.enve.hearth.design.HearthUiTextScale(uiTextScale) {
                if (useHearthChrome) {
                    HearthPdfChrome(
                        state = uiState,
                        einkActive = themeState.einkProfile.active,
                        onBack = { finish() },
                        onPrevious = { showPage(uiState.currentPage - 1) },
                        onNext = { showPage(uiState.currentPage + 1) },
                        onSeekPage = { showPage(it) },
                        onReadNext = openNext,
                    )
                } else {
                    EnveTheme(
                        appTheme = themeState.effectiveAppTheme,
                        themeColor = themeState.themeColor,
                        dynamicBackgroundEnabled = themeState.dynamicBackgroundEnabled,
                        einkProfile = themeState.einkProfile,
                    ) {
                        PdfReaderScreen(
                            state = uiState,
                            onBack = { finish() },
                            onPrevious = { showPage(uiState.currentPage - 1) },
                            onNext = { showPage(uiState.currentPage + 1) },
                            onReadNext = openNext,
                        )
                    }
                }
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
                    repository.syncEbookProgress(bookId, percentage, locator)
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

    override fun onDestroy() {
        super.onDestroy()
        renderer?.close()
        descriptor?.close()
        uiState.currentBitmap?.recycle()
    }
}

@Composable
private fun PdfReaderScreen(
    state: PdfReaderUiState,
    onBack: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onReadNext: (Book) -> Unit,
) {
    val isEink = EnveTheme.isEink
    val canvasBg = if (isEink) Color.White else Color(0xFF111111)
    val chromeBg = if (isEink) Color.White else Color.Black.copy(alpha = 0.64f)
    val chromeBgFooter = if (isEink) Color.White else Color.Black.copy(alpha = 0.66f)
    val chromeBorder = if (isEink) Color.Black.copy(alpha = 0.18f) else Color.White.copy(alpha = 0.08f)
    val pillBg = if (isEink) Color.Black.copy(alpha = 0.06f) else Color.White.copy(alpha = 0.08f)
    val titleColor = if (isEink) Color.Black else Color.White
    val subtitleColor = if (isEink) Color.Black.copy(alpha = 0.6f) else Color.White.copy(alpha = 0.7f)
    val mutedColor = if (isEink) Color.Black.copy(alpha = 0.55f) else Color.White.copy(alpha = 0.7f)
    val accentColor = if (isEink) Color.Black else MaterialTheme.colorScheme.primary
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(canvasBg),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .navigationBarsPadding(),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(20.dp))
                    .background(chromeBg)
                    .border(1.dp, chromeBorder, RoundedCornerShape(20.dp))
                    .padding(horizontal = 6.dp, vertical = 5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = titleColor)
                }
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = state.title,
                        color = titleColor,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (state.author.isNotBlank()) {
                        Text(
                            text = state.author,
                            color = subtitleColor,
                            fontSize = 14.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                Surface(shape = RoundedCornerShape(999.dp), color = pillBg) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(Icons.Default.PictureAsPdf, contentDescription = null, tint = accentColor, modifier = Modifier.size(16.dp))
                        Text("PDF", color = titleColor, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
            }

            Box(
                modifier = Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                contentAlignment = Alignment.Center,
            ) {
                val error = state.error
                when {
                    error != null -> {
                        Text(
                            text = error,
                            color = titleColor,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.padding(24.dp),
                        )
                    }
                    state.currentBitmap != null -> {
                        Image(
                            bitmap = state.currentBitmap.asImageBitmap(),
                            contentDescription = "PDF page ${state.currentPage + 1}",
                            modifier = Modifier.fillMaxSize(),
                            contentScale = ContentScale.Fit,
                        )
                    }
                    else -> {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            if (!isEink) {
                                CircularProgressIndicator(color = accentColor)
                                Spacer(Modifier.height(16.dp))
                            }
                            Text(state.loadingText, color = titleColor.copy(alpha = 0.9f))
                        }
                    }
                }
            }

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 8.dp)
                    .clip(RoundedCornerShape(22.dp))
                    .background(chromeBgFooter)
                    .border(1.dp, chromeBorder, RoundedCornerShape(22.dp))
                    .padding(horizontal = 14.dp, vertical = 10.dp),
            ) {
                if (state.pageCount > 0) {
                    LinearProgressIndicator(
                        progress = { (state.currentPage + 1).toFloat() / state.pageCount.toFloat() },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(4.dp),
                        color = accentColor,
                        trackColor = if (isEink) Color.Black.copy(alpha = 0.12f) else Color.White.copy(alpha = 0.14f),
                    )
                    Spacer(Modifier.height(8.dp))
                }

                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Surface(shape = RoundedCornerShape(999.dp), color = pillBg) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            IconButton(onClick = onPrevious, enabled = state.currentPage > 0) {
                                Icon(Icons.Default.ChevronLeft, contentDescription = "Previous page", tint = titleColor)
                            }
                            Text(
                                text = if (state.pageCount > 0) "Page ${state.currentPage + 1} of ${state.pageCount}" else "Preparing…",
                                color = titleColor,
                                fontSize = 14.sp,
                                modifier = Modifier.padding(end = 8.dp),
                            )
                            IconButton(onClick = onNext, enabled = state.currentPage < state.pageCount - 1) {
                                Icon(Icons.Default.ChevronRight, contentDescription = "Next page", tint = titleColor)
                            }
                        }
                    }

                    if (state.loadingProgress != null && state.isLoading) {
                        Text("${state.loadingProgress}%", color = mutedColor, fontSize = 12.sp)
                    }
                }
            }
        }
        val nextBook = state.nextInSeries
        if (nextBook != null && state.pageCount > 0 && state.currentPage >= state.pageCount - 1) {
            NextInSeriesButton(
                book = nextBook,
                onClick = { onReadNext(nextBook) },
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 96.dp, start = 24.dp, end = 24.dp),
            )
        }
    }
}
