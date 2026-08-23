package com.enve.app.ui.screens

import android.content.Context
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.core.os.BundleCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.app.data.librarian.LibrarianBookRef
import com.enve.app.ui.theme.AppTheme
import com.enve.app.viewmodel.EnveLibrarianViewModel
import com.enve.app.viewmodel.ThemeViewModel
import com.enve.core.data.model.BookSource
import com.enve.engine.eink.EinkMode
import com.enve.engine.eink.EinkState
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.design.HearthEink
import com.enve.hearth.design.HearthTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class EbookLibrarianActivity : ComponentActivity() {
    private val librarianViewModel: EnveLibrarianViewModel by viewModels()
    private val themeViewModel: ThemeViewModel by viewModels()
    @javax.inject.Inject lateinit var hearthPreferences: com.enve.engine.prefs.PreferencesFacade

    companion object {
        private const val EXTRA_BOOK_ID = "bookId"
        private const val EXTRA_BOOK_SOURCE = "bookSource"
        private const val EXTRA_CONNECTION_ID = "connectionId"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_AUTHOR = "author"
        private const val EXTRA_BOOK_FORMAT = "bookFormat"
        private const val EXTRA_CURRENT_PROGRESS = "currentProgress"

        fun createIntent(
            context: Context,
            bookId: String,
            bookSource: BookSource,
            connectionId: String?,
            title: String,
            author: String?,
            bookFormat: String?,
            currentProgress: Double,
        ): Intent = Intent(context, EbookLibrarianActivity::class.java).apply {
            putExtra(EXTRA_BOOK_ID, bookId)
            putExtra(EXTRA_BOOK_SOURCE, bookSource.name)
            if (connectionId != null) putExtra(EXTRA_CONNECTION_ID, connectionId)
            putExtra(EXTRA_TITLE, title)
            if (!author.isNullOrBlank()) putExtra(EXTRA_AUTHOR, author)
            if (!bookFormat.isNullOrBlank()) putExtra(EXTRA_BOOK_FORMAT, bookFormat)
            putExtra(EXTRA_CURRENT_PROGRESS, currentProgress)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        val bookId = intent.getStringExtra(EXTRA_BOOK_ID) ?: run {
            finish()
            return
        }
        val source = intent.getStringExtra(EXTRA_BOOK_SOURCE)
            ?.let { runCatching { BookSource.valueOf(it) }.getOrNull() }
            ?: BookSource.GRIMMORY
        val book = LibrarianBookRef(
            bookId = bookId,
            sourceName = source.name,
            connectionId = intent.getStringExtra(EXTRA_CONNECTION_ID),
            title = intent.getStringExtra(EXTRA_TITLE).orEmpty(),
            author = intent.getStringExtra(EXTRA_AUTHOR),
            formatName = intent.getStringExtra(EXTRA_BOOK_FORMAT),
            currentProgress = currentProgressExtra(),
        )
        librarianViewModel.initialize(book)

        setContent {
            val themeState = themeViewModel.themeState.collectAsStateWithLifecycle().value
            val state = librarianViewModel.state.collectAsStateWithLifecycle().value
            val uiTextScale = hearthPreferences.uiTextScale.collectAsStateWithLifecycle(initialValue = 1f).value
            val profile = themeState.einkProfile
            HearthTheme(
                mode = when (themeState.effectiveAppTheme) {
                    AppTheme.SYSTEM -> HearthThemeMode.SYSTEM
                    AppTheme.LIGHT, AppTheme.PAPER_WHITE -> HearthThemeMode.PAPER
                    else -> HearthThemeMode.INK
                },
                accent = themeState.themeColor,
                oledEnabled = themeState.effectiveAppTheme == AppTheme.OLED,
                uiTextScale = uiTextScale,
                eink = if (profile.active) {
                    HearthEink(
                        EinkState(
                            active = true,
                            monochrome = profile.monochrome,
                            mode = EinkMode.valueOf(profile.displayMode.name),
                            boldText = profile.boldText,
                            refreshStrength = profile.refreshStrength,
                        ),
                    )
                } else {
                    HearthEink.Inactive
                },
            ) {
                EnveLibrarianScreen(
                    state = state,
                    onBack = { finish() },
                    onScopeChange = librarianViewModel::setScope,
                    onPrepareContext = librarianViewModel::prepareContext,
                    onRefreshContextStatus = librarianViewModel::refreshContextStatus,
                    onRefreshEngineStatus = librarianViewModel::refreshEngineStatus,
                    onEngineChange = librarianViewModel::setEngine,
                    onDownloadGeminiNano = librarianViewModel::downloadGeminiNano,
                    onDownloadRecommendedModel = librarianViewModel::downloadRecommendedModel,
                    onCancelModelDownload = librarianViewModel::cancelRecommendedModelDownload,
                    onImportLocalModel = librarianViewModel::importLiteRtModel,
                    onRemoveLocalModel = librarianViewModel::removeLiteRtModel,
                    onRemoteServerUrlChange = librarianViewModel::setRemoteServerUrl,
                    onRemoteServerModelChange = librarianViewModel::setRemoteServerModel,
                    onRemoteServerApiKeyChange = librarianViewModel::setRemoteServerApiKey,
                    onTestRemoteServer = librarianViewModel::testRemoteServer,
                    onSaveRemoteServerSettings = librarianViewModel::saveRemoteServerSettings,
                    onSend = librarianViewModel::send,
                    onCatchUp = librarianViewModel::sendCatchUp,
                    onChoosePreviousBookSummary = librarianViewModel::choosePreviousBookSummary,
                    onSelectPreviousBookSummary = librarianViewModel::summarizePreviousBook,
                    onDismissPreviousBookChoices = librarianViewModel::dismissPreviousBookChoices,
                    onClearConversation = librarianViewModel::clearConversation,
                    onDismissAlert = librarianViewModel::dismissAlert,
                )
            }
        }
    }

    private fun currentProgressExtra(): Double =
        intent.extras
            ?.let { BundleCompat.getSerializable(it, EXTRA_CURRENT_PROGRESS, Number::class.java) }
            ?.toDouble()
            ?.coerceIn(0.0, 1.0)
            ?: 0.0
}
