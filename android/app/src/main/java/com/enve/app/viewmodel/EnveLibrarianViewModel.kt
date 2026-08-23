package com.enve.app.viewmodel

import android.net.Uri
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.app.data.librarian.BookIntelligenceScope
import com.enve.app.data.librarian.EbookContextService
import com.enve.app.data.librarian.EnveLibrarianService
import com.enve.app.data.librarian.LibrarianAnswer
import com.enve.app.data.librarian.LibrarianEngineManager
import com.enve.app.data.librarian.LibrarianEnginePreference
import com.enve.app.data.librarian.LibrarianEngineStatus
import com.enve.app.data.librarian.LibrarianBookRef
import com.enve.app.data.librarian.LibrarianConversationStore
import com.enve.app.data.librarian.LibrarianRemoteServerSettings
import com.enve.app.data.librarian.LibrarianMessage
import com.enve.app.data.librarian.LibrarianMessageRole
import com.enve.app.data.librarian.RecommendedLibrarianModel
import com.enve.app.data.librarian.LITERT_GENERATE_TIMEOUT_HINT_MINUTES
import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.document.EbookSourceFormat
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import javax.inject.Inject

data class PreviousBookSummaryChoice(
    val book: LibrarianBookRef,
    val title: String,
    val author: String?,
    val seriesNumber: String?,
    val isSuggested: Boolean,
)

data class EnveLibrarianUiState(
    val book: LibrarianBookRef? = null,
    val messages: List<LibrarianMessage> = emptyList(),
    val selectedScope: BookIntelligenceScope = BookIntelligenceScope.PREVIOUS_CHAPTER,
    val isPreparingContext: Boolean = false,
    val contextProgress: Double = 0.0,
    val contextStatusText: String? = null,
    val isSending: Boolean = false,
    val sendStatusText: String? = null,
    val selectedEngine: LibrarianEnginePreference = LibrarianEnginePreference.AUTOMATIC,
    val engineStatuses: List<LibrarianEngineStatus> = emptyList(),
    val recommendedModel: RecommendedLibrarianModel? = null,
    val isDownloadingGemini: Boolean = false,
    val remoteServerUrl: String = "",
    val remoteServerModel: String = "",
    val remoteServerApiKey: String = "",
    val remoteServerHasStoredKey: Boolean = false,
    val remoteServerModels: List<String> = emptyList(),
    val isTestingRemoteServer: Boolean = false,
    val isDownloadingRecommendedModel: Boolean = false,
    val recommendedModelDownloadProgress: Double? = null,
    val isImportingModel: Boolean = false,
    val isRemovingModel: Boolean = false,
    val isLoadingPreviousBookChoices: Boolean = false,
    val previousBookChoices: List<PreviousBookSummaryChoice> = emptyList(),
    val alertMessage: String? = null,
)

@HiltViewModel
class EnveLibrarianViewModel @Inject constructor(
    private val ebookContextService: EbookContextService,
    private val librarianService: EnveLibrarianService,
    private val engineManager: LibrarianEngineManager,
    private val conversationStore: LibrarianConversationStore,
    private val aggregatorRepository: AggregatorRepository,
    private val bookCacheDao: BookCacheDao,
) : ViewModel() {
    private val _state = MutableStateFlow(EnveLibrarianUiState())
    val state: StateFlow<EnveLibrarianUiState> = _state.asStateFlow()

    private var prepareJob: Job? = null

    private var remoteApiKeyDirty = false

    init {
        viewModelScope.launch { observeModelDownload() }
        viewModelScope.launch {
            val settings = engineManager.remoteServerSettings()
            _state.update {
                it.copy(
                    remoteServerUrl = settings.serverUrl,
                    remoteServerModel = settings.model,
                    remoteServerHasStoredKey = engineManager.hasRemoteApiKey(),
                )
            }
        }
    }

    private suspend fun observeModelDownload() {
        var wasActive = false
        engineManager.recommendedModelDownloadStates().collect { download ->
            if (download?.isActive == true) {
                val percent = download.progress?.let { " ${(it * 100).toInt()}%" }.orEmpty()
                _state.update {
                    it.copy(
                        isDownloadingRecommendedModel = true,
                        recommendedModelDownloadProgress = download.progress ?: 0.0,
                        sendStatusText = if (it.isSending) {
                            it.sendStatusText
                        } else {
                            "Downloading ${engineManager.recommendedModel.title}$percent"
                        },
                    )
                }
            } else {
                val finishedJustNow = wasActive
                val selectedEngine = if (finishedJustNow) engineManager.selectedPreference() else null
                val statuses = if (finishedJustNow) engineManager.refreshStatuses() else null
                _state.update {
                    it.copy(
                        isDownloadingRecommendedModel = false,
                        recommendedModelDownloadProgress = null,
                        sendStatusText = if (it.isSending) it.sendStatusText else null,
                        selectedEngine = selectedEngine ?: it.selectedEngine,
                        engineStatuses = statuses ?: it.engineStatuses,
                        alertMessage = if (finishedJustNow) download?.errorMessage ?: it.alertMessage else it.alertMessage,
                    )
                }
            }
            wasActive = download?.isActive == true
        }
    }

    fun initialize(book: LibrarianBookRef) {
        if (_state.value.book?.stableId == book.stableId) return
        _state.value = EnveLibrarianUiState(book = book)
        viewModelScope.launch {
            val selectedEngine = engineManager.selectedPreference()
            val engineStatuses = engineManager.refreshStatuses()
            val messages = conversationStore.load(book.stableId, fallbackStableId = book.legacyStableId)
            _state.update {
                it.copy(
                    messages = messages,
                    selectedEngine = selectedEngine,
                    engineStatuses = engineStatuses,
                    recommendedModel = engineManager.recommendedModel,
                )
            }
            prepareContext()
        }
    }

    fun setScope(scope: BookIntelligenceScope) {
        _state.update { it.copy(selectedScope = scope) }
    }

    fun prepareContext() {
        val book = _state.value.book ?: return
        if (prepareJob?.isActive == true) return
        prepareJob = viewModelScope.launch {
            _state.update {
                it.copy(
                    isPreparingContext = true,
                    contextStatusText = "Preparing ebook text",
                    contextProgress = 0.0,
                    alertMessage = null,
                )
            }
            try {
                ebookContextService.prepareContext(book)
                _state.update {
                    it.copy(
                        isPreparingContext = false,
                        contextStatusText = null,
                        contextProgress = 1.0,
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        isPreparingContext = false,
                        contextStatusText = e.message ?: "Book text unavailable.",
                        alertMessage = e.message ?: "Book text unavailable.",
                    )
                }
            }
        }
    }

    fun refreshContextStatus() {
        val book = _state.value.book ?: return
        val building = ebookContextService.buildingBookIds.value.contains(book.stableId)
        _state.update {
            it.copy(
                isPreparingContext = building,
                contextProgress = ebookContextService.progressByBook.value[book.stableId] ?: it.contextProgress,
                contextStatusText = ebookContextService.statusByBook.value[book.stableId] ?: it.contextStatusText,
            )
        }
    }

    fun refreshEngineStatus() {
        viewModelScope.launch {
            val selectedEngine = engineManager.selectedPreference()
            val statuses = engineManager.refreshStatuses()
            _state.update {
                it.copy(
                    selectedEngine = selectedEngine,
                    engineStatuses = statuses,
                    recommendedModel = engineManager.recommendedModel,
                )
            }
        }
    }

    fun setEngine(preference: LibrarianEnginePreference) {
        viewModelScope.launch {
            engineManager.savePreference(preference)
            _state.update {
                it.copy(
                    selectedEngine = preference,
                    engineStatuses = engineManager.statuses.value,
                )
            }
        }
    }

    fun setRemoteServerUrl(value: String) {
        _state.update { it.copy(remoteServerUrl = value) }
    }

    fun setRemoteServerModel(value: String) {
        _state.update { it.copy(remoteServerModel = value) }
    }

    fun setRemoteServerApiKey(value: String) {
        remoteApiKeyDirty = true
        _state.update { it.copy(remoteServerApiKey = value) }
    }

    fun saveRemoteServerSettings() {
        viewModelScope.launch { persistRemoteServerSettings() }
    }

    fun testRemoteServer() {
        if (_state.value.isTestingRemoteServer) return
        viewModelScope.launch {
            _state.update { it.copy(isTestingRemoteServer = true, alertMessage = null) }
            try {
                persistRemoteServerSettings()
                val models = engineManager.testRemoteServer()
                val autoSelected = _state.value.remoteServerModel.ifBlank { models.firstOrNull().orEmpty() }
                _state.update {
                    it.copy(
                        isTestingRemoteServer = false,
                        remoteServerModels = models,
                        remoteServerModel = autoSelected,
                    )
                }
                if (autoSelected.isNotBlank()) persistRemoteServerSettings()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        isTestingRemoteServer = false,
                        remoteServerModels = emptyList(),
                        alertMessage = e.message ?: "Could not reach the local server.",
                    )
                }
            }
        }
    }

    private suspend fun persistRemoteServerSettings() {
        val current = _state.value
        if (remoteApiKeyDirty) {
            engineManager.saveRemoteApiKey(current.remoteServerApiKey)
            remoteApiKeyDirty = false
        }
        engineManager.saveRemoteServerSettings(
            LibrarianRemoteServerSettings(
                serverUrl = current.remoteServerUrl.trim(),
                model = current.remoteServerModel.trim(),
            )
        )
        _state.update {
            it.copy(
                engineStatuses = engineManager.statuses.value,
                remoteServerHasStoredKey = engineManager.hasRemoteApiKey(),
            )
        }
    }

    fun downloadGeminiNano() {
        if (_state.value.isDownloadingGemini) return
        viewModelScope.launch {
            _state.update {
                it.copy(
                    isDownloadingGemini = true,
                    sendStatusText = "Downloading Gemini Nano",
                    alertMessage = null,
                )
            }
            try {
                engineManager.downloadGeminiNano()
                _state.update {
                    it.copy(
                        isDownloadingGemini = false,
                        sendStatusText = null,
                        engineStatuses = engineManager.statuses.value,
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        isDownloadingGemini = false,
                        sendStatusText = null,
                        engineStatuses = engineManager.statuses.value,
                        alertMessage = e.message ?: "Gemini Nano download failed.",
                    )
                }
            }
        }
    }

    fun downloadRecommendedModel() {
        if (_state.value.isDownloadingRecommendedModel) return
        _state.update {
            it.copy(
                isDownloadingRecommendedModel = true,
                recommendedModelDownloadProgress = 0.0,
                alertMessage = null,
            )
        }
        engineManager.startRecommendedModelDownload()
    }

    fun cancelRecommendedModelDownload() {
        engineManager.cancelRecommendedModelDownload()
    }

    fun importLiteRtModel(uri: Uri) {
        if (_state.value.isImportingModel) return
        viewModelScope.launch {
            _state.update {
                it.copy(
                    isImportingModel = true,
                    sendStatusText = "Importing local model",
                    alertMessage = null,
                )
            }
            try {
                engineManager.importLiteRtModel(uri)
                _state.update {
                    it.copy(
                        isImportingModel = false,
                        sendStatusText = null,
                        selectedEngine = LibrarianEnginePreference.LITERT_LM,
                        engineStatuses = engineManager.statuses.value,
                    )
                }
                engineManager.savePreference(LibrarianEnginePreference.LITERT_LM)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        isImportingModel = false,
                        sendStatusText = null,
                        engineStatuses = engineManager.statuses.value,
                        alertMessage = e.message ?: "Could not import the selected model.",
                    )
                }
            }
        }
    }

    fun removeLiteRtModel() {
        if (_state.value.isRemovingModel) return
        viewModelScope.launch {
            _state.update {
                it.copy(
                    isRemovingModel = true,
                    sendStatusText = "Removing local model",
                    alertMessage = null,
                )
            }
            try {
                engineManager.removeLiteRtModel()
                val selectedEngine = engineManager.selectedPreference()
                _state.update {
                    it.copy(
                        isRemovingModel = false,
                        sendStatusText = null,
                        selectedEngine = selectedEngine,
                        engineStatuses = engineManager.statuses.value,
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        isRemovingModel = false,
                        sendStatusText = null,
                        engineStatuses = engineManager.statuses.value,
                        alertMessage = e.message ?: "Could not remove the installed local model.",
                    )
                }
            }
        }
    }

    fun send(question: String) {
        val trimmed = question.trim()
        val current = _state.value
        val book = current.book ?: return
        if (trimmed.isBlank() || current.isSending) return

        viewModelScope.launch {
            Log.i(
                TAG,
                "send started bookId=${book.bookId} engine=${current.selectedEngine} scope=${current.selectedScope} questionChars=${trimmed.length}"
            )
            val user = LibrarianMessage(
                role = LibrarianMessageRole.USER,
                text = trimmed,
                scope = current.selectedScope,
            )
            val withUser = _state.value.messages + user
            _state.update {
                it.copy(
                    messages = withUser,
                    isSending = true,
                    sendStatusText = "Preparing context",
                    alertMessage = null,
                )
            }
            conversationStore.save(book.stableId, withUser)

            if (ebookContextService.buildingBookIds.value.contains(book.stableId)) {
                _state.update { it.copy(sendStatusText = "Reading the book's text") }
                withTimeoutOrNull(60_000L) {
                    ebookContextService.buildingBookIds.first { book.stableId !in it }
                }
            }

            val freshProgress = bookCacheDao.getById(book.bookId)?.toBook()
                ?.let { fresh -> maxOf(book.currentProgress, (fresh.epubProgress ?: fresh.readProgress).toDouble()) }
                ?: book.currentProgress

            val answer = try {
                _state.update { it.copy(sendStatusText = thinkingStatusText()) }
                val resolved = librarianService.answer(
                    question = trimmed,
                    book = book,
                    scope = _state.value.selectedScope,
                    currentProgress = freshProgress,
                )
                Log.i(
                    TAG,
                    "send received answer engine=${resolved.engineTitle} answerChars=${resolved.text.length}"
                )
                resolved
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "send failed: ${e.message}", e)
                LibrarianAnswer(
                    text = e.message ?: "Enve Librarian could not answer from the local context.",
                    engineTitle = "Unavailable",
                )
            }

            val finalMessages = _state.value.messages + LibrarianMessage(
                role = LibrarianMessageRole.ASSISTANT,
                text = answer.text,
                scope = _state.value.selectedScope,
                engineTitle = answer.engineTitle,
            )
            _state.update {
                it.copy(
                    messages = finalMessages,
                    isSending = false,
                    sendStatusText = null,
                )
            }
            Log.i(TAG, "send finished messages=${finalMessages.size}")
            conversationStore.save(book.stableId, finalMessages)
        }
    }

    fun sendCatchUp() {
        send("Catch me up on the last part of the previous chapter.")
    }

    fun choosePreviousBookSummary() {
        val current = _state.value
        val currentRef = current.book ?: return
        if (current.isSending || current.isPreparingContext || current.isLoadingPreviousBookChoices) return

        viewModelScope.launch {
            _state.update {
                it.copy(
                    isLoadingPreviousBookChoices = true,
                    previousBookChoices = emptyList(),
                    alertMessage = null,
                )
            }

            try {
                val currentBook = resolveCurrentBook(currentRef)
                    ?: throw IllegalStateException("Enve could not resolve this book from the local library cache yet.")
                val seriesName = currentBook.seriesName?.trim().orEmpty()
                if (seriesName.isBlank()) {
                    throw IllegalStateException("This book does not have series metadata, so Enve cannot suggest a previous book yet.")
                }

                val candidates = aggregatorRepository.getBooksInSeries(seriesName)
                    .filter { candidate ->
                        candidate.id != currentBook.id &&
                            candidate.connectionId == currentBook.connectionId &&
                            candidate.source == currentBook.source &&
                            candidate.seriesName?.trim()?.equals(seriesName, ignoreCase = true) == true &&
                            candidate.isLibrarianEligible()
                    }
                    .toPreviousBookChoices(currentBook)

                if (candidates.isEmpty()) {
                    throw IllegalStateException("Enve could not find an earlier ebook in this series that has readable local book text.")
                }

                _state.update {
                    it.copy(
                        isLoadingPreviousBookChoices = false,
                        previousBookChoices = candidates,
                    )
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _state.update {
                    it.copy(
                        isLoadingPreviousBookChoices = false,
                        previousBookChoices = emptyList(),
                        alertMessage = e.message ?: "Enve could not find a previous book to summarize.",
                    )
                }
            }
        }
    }

    fun dismissPreviousBookChoices() {
        _state.update { it.copy(previousBookChoices = emptyList(), isLoadingPreviousBookChoices = false) }
    }

    fun summarizePreviousBook(choice: PreviousBookSummaryChoice) {
        val current = _state.value
        val currentBook = current.book ?: return
        if (current.isSending || current.isPreparingContext) return

        viewModelScope.launch {
            val prompt = "Summarize previous book: ${choice.title}"
            val user = LibrarianMessage(
                role = LibrarianMessageRole.USER,
                text = prompt,
                scope = BookIntelligenceScope.BOOK_SO_FAR,
            )
            val withUser = _state.value.messages + user
            _state.update {
                it.copy(
                    messages = withUser,
                    previousBookChoices = emptyList(),
                    isLoadingPreviousBookChoices = false,
                    isSending = true,
                    sendStatusText = "Preparing ${choice.title}",
                    alertMessage = null,
                )
            }
            conversationStore.save(currentBook.stableId, withUser)

            val answer = try {
                _state.update { it.copy(sendStatusText = thinkingStatusText()) }
                librarianService.answer(
                    question = PREVIOUS_BOOK_SUMMARY_PROMPT,
                    book = choice.book,
                    scope = BookIntelligenceScope.BOOK_SO_FAR,
                    currentProgress = 1.0,
                )
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                LibrarianAnswer(
                    text = e.message ?: "Enve Librarian could not summarize that book from the local context.",
                    engineTitle = "Unavailable",
                )
            }

            val finalMessages = _state.value.messages + LibrarianMessage(
                role = LibrarianMessageRole.ASSISTANT,
                text = answer.text,
                scope = BookIntelligenceScope.BOOK_SO_FAR,
                engineTitle = answer.engineTitle,
            )
            _state.update {
                it.copy(
                    messages = finalMessages,
                    isSending = false,
                    sendStatusText = null,
                )
            }
            conversationStore.save(currentBook.stableId, finalMessages)
        }
    }

    fun clearConversation() {
        val book = _state.value.book ?: return
        viewModelScope.launch {
            conversationStore.clear(book.stableId)
            _state.update { it.copy(messages = emptyList()) }
        }
    }

    fun dismissAlert() {
        _state.update { it.copy(alertMessage = null) }
    }

    private fun thinkingStatusText(): String =
        when (_state.value.selectedEngine) {
            LibrarianEnginePreference.LITERT_LM -> "Loading Local Model (first run can take up to ${LITERT_GENERATE_TIMEOUT_HINT_MINUTES} min)"
            LibrarianEnginePreference.GEMINI_NANO -> "Running Gemini Nano"
            else -> "Thinking"
        }

    private suspend fun resolveCurrentBook(book: LibrarianBookRef): Book? =
        bookCacheDao.getByIdAndConnection(book.bookId, book.connectionId)?.toBook()
            ?: bookCacheDao.getById(book.bookId)?.toBook()

    private fun List<Book>.toPreviousBookChoices(currentBook: Book): List<PreviousBookSummaryChoice> {
        val currentSequence = currentBook.seriesSequenceValue()
        val sorted = sortedWith(
            compareBy<Book> { candidate ->
                val candidateSequence = candidate.seriesSequenceValue()
                when {
                    currentSequence == null -> 1
                    candidateSequence == null -> 1
                    candidateSequence < currentSequence -> 0
                    else -> 1
                }
            }.thenByDescending { candidate ->
                candidate.seriesSequenceValue()
                    ?.takeIf { currentSequence == null || it < currentSequence }
                    ?: Double.NEGATIVE_INFINITY
            }.thenBy { candidate ->
                candidate.seriesSequenceValue()
                    ?.takeIf { currentSequence == null || it >= currentSequence }
                    ?: Double.POSITIVE_INFINITY
            }.thenBy { it.title.lowercase() }
        )
        val suggestedKey = sorted.firstOrNull()?.uniqueKey
        return sorted.map { candidate ->
            PreviousBookSummaryChoice(
                book = candidate.toLibrarianBookRef(progress = 1.0),
                title = candidate.title,
                author = candidate.author,
                seriesNumber = candidate.seriesNumber,
                isSuggested = candidate.uniqueKey == suggestedKey,
            )
        }
    }

    private fun Book.isLibrarianEligible(): Boolean {
        val format = EbookSourceFormat.fromServerType(primaryFileType)
        return readAlongAvailable || hasEbook || format != EbookSourceFormat.UNKNOWN
    }

    private fun Book.toLibrarianBookRef(progress: Double): LibrarianBookRef =
        LibrarianBookRef(
            bookId = id,
            sourceName = source.name,
            connectionId = connectionId,
            title = title,
            author = author,
            formatName = when {
                readAlongAvailable -> EbookSourceFormat.READALOUD.name
                primaryFileType.isNullOrBlank() && hasEbook -> EbookSourceFormat.EPUB.name
                else -> primaryFileType
            },
            currentProgress = progress.coerceIn(0.0, 1.0),
        )

    private fun Book.seriesSequenceValue(): Double? =
        seriesNumber
            ?.replace(',', '.')
            ?.trim()
            ?.takeIf { it.isNotBlank() }
            ?.toDoubleOrNull()

    private companion object {
        private const val TAG = "EnveLibrarianVm"
        const val PREVIOUS_BOOK_SUMMARY_PROMPT =
            "Summarize the entire book, including the important people, the major events, and where it leaves off for the next book in the series."
    }
}
