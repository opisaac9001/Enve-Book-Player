package com.enve.app.data.hardcover

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import com.enve.app.data.NetworkStateProvider
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.util.FINISHED_PROGRESS_THRESHOLD
import com.enve.core.di.ApplicationScope
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import java.io.IOException
import java.text.Normalizer
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToInt

private const val MIN_PROGRESS_INTERVAL_MS = 60_000L
private const val MIN_SYNC_FRACTION = 0.01f
private const val REREAD_START_FRACTION = 0.1f
private const val MAX_SYNC_STEPS = 4
private const val NO_MATCH_MESSAGE = "No exact Hardcover match. Link it manually in Hardcover Hub."
private const val CONFLICT_MESSAGE = "Its ISBN or ASIN matches more than one Hardcover book. Link it manually in Hardcover Hub."
private const val OFFLINE_MESSAGE = "Hardcover is unreachable. Retrying when online."
private const val STORAGE_MESSAGE = "Couldn't save Hardcover sync on this device. Recent progress may not reach Hardcover."

data class HardcoverSyncStatus(
    val bookTitle: String,
    val message: String,
    val isError: Boolean,
)

internal sealed interface HardcoverSyncPlan {
    data class AddToLibrary(val statusId: Int, val editionId: Int?) : HardcoverSyncPlan
    data class SetStatus(val userBookId: Int, val statusId: Int) : HardcoverSyncPlan
    data class StartRead(val userBookId: Int, val editionId: Int?) : HardcoverSyncPlan
    data class WriteProgress(val readId: Int, val editionId: Int, val pages: Int?, val seconds: Int?) : HardcoverSyncPlan
    data class Skip(val reason: String) : HardcoverSyncPlan
    data class NeedsEdition(val reason: String) : HardcoverSyncPlan
    data class FinishRead(val userBookId: Int, val readId: Int) : HardcoverSyncPlan
    data object AlreadyFinished : HardcoverSyncPlan
    data object UpToDate : HardcoverSyncPlan
}

internal fun hardcoverNormalized(value: String): String =
    Normalizer.normalize(value, Normalizer.Form.NFD)
        .replace(Regex("\\p{M}+"), "")
        .lowercase(Locale.ROOT)
        .replace(Regex("[^\\p{L}\\p{N}]+"), " ")
        .trim()

internal fun hardcoverAuthorNames(author: String?): Set<String> =
    author.orEmpty()
        .split(Regex(",|;|&|\\band\\b", RegexOption.IGNORE_CASE))
        .map(::hardcoverNormalized)
        .filterTo(mutableSetOf()) { it.isNotBlank() }

internal fun hardcoverExactMatch(title: String, author: String?, results: List<HardcoverBookResult>): HardcoverBookResult? {
    val wantedTitle = hardcoverNormalized(title)
    val wantedAuthors = hardcoverAuthorNames(author)
    if (wantedTitle.isBlank() || wantedAuthors.isEmpty()) return null
    return results.distinctBy { it.id }.filter { result ->
        result.id > 0 && hardcoverNormalized(result.title) == wantedTitle &&
            result.authorNames.any { hardcoverNormalized(it) in wantedAuthors }
    }.singleOrNull()
}

internal fun hardcoverProgressUnits(fraction: Float, total: Int): Int =
    (fraction.coerceIn(0f, 1f) * total).roundToInt().coerceIn(0, (total - 1).coerceAtLeast(0))

internal fun hardcoverSyncPlan(
    state: HardcoverBookState,
    mediaType: AppMediaType,
    fraction: Float,
    finished: Boolean,
    initialFraction: Float = fraction,
): HardcoverSyncPlan {
    val audio = mediaType == AppMediaType.AUDIOBOOK
    val selected = state.selectedEdition
    val defaultEdition = selected
        ?: if (audio) state.defaultAudioEdition else state.defaultEbookEdition ?: state.defaultPhysicalEdition
    val userBook = state.userBook ?: return HardcoverSyncPlan.AddToLibrary(if (finished) 1 else 2, defaultEdition?.id)
    val read = userBook.activeRead
    if (finished) {
        return when {
            read != null -> HardcoverSyncPlan.FinishRead(userBook.id, read.id)
            userBook.statusId == 3 -> HardcoverSyncPlan.AlreadyFinished
            userBook.reads.firstOrNull()?.finishedAt != null -> HardcoverSyncPlan.SetStatus(userBook.id, 3)
            else -> HardcoverSyncPlan.StartRead(userBook.id, selected?.id ?: userBook.edition?.id ?: defaultEdition?.id)
        }
    }
    if (read == null) {
        if (userBook.statusId == 3 && initialFraction > REREAD_START_FRACTION) {
            return HardcoverSyncPlan.Skip("Finished on Hardcover; a re-read starts once you're back near the beginning.")
        }
        return if (userBook.statusId == 2) HardcoverSyncPlan.StartRead(userBook.id, selected?.id ?: userBook.edition?.id ?: defaultEdition?.id)
        else HardcoverSyncPlan.SetStatus(userBook.id, 2)
    }
    val edition = selected ?: read.edition ?: userBook.edition ?: defaultEdition
        ?: return HardcoverSyncPlan.NeedsEdition("Choose an edition for this book on Hardcover.")
    val usesSeconds = (edition.audioSeconds ?: 0) > 0
    val total = (if (usesSeconds) edition.audioSeconds else edition.pages)?.takeIf { it > 0 }
        ?: return HardcoverSyncPlan.NeedsEdition("The selected Hardcover edition has no page count or audio length.")
    val units = hardcoverProgressUnits(fraction, total)
    val current = if (usesSeconds) read.progressSeconds else read.progressPages
    if (current != null && units < current) return HardcoverSyncPlan.Skip("Hardcover already has further progress.")
    if (current == units && read.edition?.id == edition.id) return HardcoverSyncPlan.UpToDate
    return HardcoverSyncPlan.WriteProgress(
        readId = read.id,
        editionId = edition.id,
        pages = units.takeUnless { usesSeconds },
        seconds = units.takeIf { usesSeconds },
    )
}

@OptIn(ExperimentalCoroutinesApi::class)
@Singleton
class HardcoverSyncService @Inject constructor(
    private val service: HardcoverService,
    private val store: HardcoverSyncStore,
    private val outbox: HardcoverOutbox,
    private val bookCache: BookCacheDao,
    private val network: NetworkStateProvider,
    @ApplicationContext private val context: Context,
    @ApplicationScope parentScope: CoroutineScope,
) {
    private sealed interface Outcome {
        data object Sent : Outcome
        data class Deferred(val message: String, val retryAfterMs: Long?, val waitingForNetwork: Boolean) : Outcome
        data class Failed(val message: String) : Outcome
    }

    private val generation = AtomicLong()
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)
    private val commands = Channel<suspend () -> Unit>(Channel.UNLIMITED)
    private val wake = Channel<Unit>(Channel.CONFLATED)
    private val lastSentAt = ConcurrentHashMap<String, Long>()
    private val confirmedFinished = ConcurrentHashMap.newKeySet<String>()
    @Volatile private var drainJob: Job? = null
    @Volatile private var timer: Job? = null

    private val mutableStatus = MutableStateFlow<HardcoverSyncStatus?>(null)
    val status: StateFlow<HardcoverSyncStatus?> = mutableStatus.asStateFlow()
    val enabled: StateFlow<Boolean> = store.enabled
    val matches: StateFlow<Map<String, HardcoverBookMatch>> = store.matches

    private val accountKey = MutableStateFlow(service.activeAccountKey())
    private val storageError = MutableStateFlow<String?>(null)
    val queue: StateFlow<HardcoverQueueSummary> = combine(
        accountKey.flatMapLatest { key ->
            if (key == null) flowOf(emptyList<HardcoverOutboxEvent>())
            else flow { emitAll(outbox.dao.observe(key)) }.catch {
                storageError.value = STORAGE_MESSAGE
                emit(emptyList())
            }
        },
        storageError,
    ) { events, error -> hardcoverQueueSummary(events, error) }
        .stateIn(scope, SharingStarted.Eagerly, HardcoverQueueSummary())

    init {
        scope.launch {
            for (command in commands) {
                try {
                    command()
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    storageError.value = STORAGE_MESSAGE
                }
                wake.trySend(Unit)
            }
        }
        scope.launch {
            while (true) {
                wake.receive()
                val job = scope.launch { drain() }
                drainJob = job
                job.join()
            }
        }
        scope.launch {
            networkAvailability().collect {
                val account = service.activeAccountKey() ?: return@collect
                commands.trySend { outbox.dao.networkRestored(account, System.currentTimeMillis()) }
            }
        }
    }

    fun start() {
        accountKey.value = service.activeAccountKey()
        wake.trySend(Unit)
    }

    fun setEnabled(value: Boolean) {
        store.setEnabled(value)
        if (value) start() else stop()
    }

    fun submitProgress(book: Book, fraction: Float) {
        submit(book, fraction, finished = fraction >= FINISHED_PROGRESS_THRESHOLD)
    }

    fun submitFinished(book: Book) {
        submit(book, 1f, finished = true)
    }

    fun confirmMatch(book: Book, result: HardcoverBookResult) {
        val key = book.hardcoverLocalKey()
        store.saveMatch(HardcoverBookMatch(key, book.title, book.author, result.id, result.title, automatic = false))
        val account = service.activeAccountKey() ?: return
        commands.trySend { outbox.dao.retryBook(account, key) }
    }

    fun unlink(localKey: String) {
        store.unlink(localKey)
        commands.trySend { outbox.dao.deleteBook(localKey) }
    }

    fun retryFailed() {
        val account = service.activeAccountKey() ?: return
        commands.trySend { outbox.dao.retryFailed(account) }
    }

    fun discardFailed() {
        val account = service.activeAccountKey() ?: return
        commands.trySend { outbox.dao.discardFailed(account) }
    }

    fun resetAccount() {
        setEnabled(false)
    }

    fun disconnect() {
        resetAccount()
        commands.trySend { outbox.dao.clear() }
        service.clearToken()
        accountKey.value = null
    }

    private fun stop() {
        generation.incrementAndGet()
        drainJob?.cancel()
        timer?.cancel()
        lastSentAt.clear()
        confirmedFinished.clear()
        mutableStatus.value = null
    }

    private fun submit(book: Book, fraction: Float, finished: Boolean) {
        if (!store.enabled.value || book.mediaType == AppMediaType.PODCAST) return
        if (!fraction.isFinite() || fraction !in 0f..1f) return
        if (!finished && fraction < MIN_SYNC_FRACTION) return
        val account = service.activeAccountKey() ?: return
        val key = book.hardcoverLocalKey()
        if (store.isUnlinked(key)) return
        val requestGeneration = generation.get()
        val occurredAt = System.currentTimeMillis()
        commands.trySend {
            if (requestGeneration != generation.get()) return@trySend
            if (finished && key in confirmedFinished) return@trySend
            if (!finished) confirmedFinished.remove(key)
            val cached = bookCache.getByIdAndConnection(book.id, book.connectionId)
            val identifiers = hardcoverIdentifiers(book.isbn13).takeUnless { it.isEmpty } ?: hardcoverIdentifiers(cached?.isbn13)
            outbox.dao.enqueue(
                HardcoverOutboxEvent(
                    accountKey = account,
                    localKey = key,
                    bookId = book.id,
                    connectionId = book.connectionId,
                    mediaType = book.mediaType,
                    title = cached?.title ?: book.title,
                    author = cached?.author ?: book.author,
                    isbn10 = identifiers.isbn10,
                    isbn13 = identifiers.isbn13,
                    asin = identifiers.asin,
                    fraction = fraction,
                    finished = finished,
                    occurredAt = occurredAt,
                ),
            )
            storageError.value = null
            if (finished) confirmedFinished += key
        }
    }

    private suspend fun drain() {
        val workGeneration = generation.get()
        while (true) {
            if (!store.enabled.value || workGeneration != generation.get()) return
            val account = service.activeAccountKey() ?: return
            accountKey.value = account
            if (!network.hasActiveNetwork()) return
            val events = try {
                outbox.dao.forAccount(account)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                storageError.value = STORAGE_MESSAGE
                return
            }
            val schedule = hardcoverOutboxSchedule(events, System.currentTimeMillis(), lastSentAt, MIN_PROGRESS_INTERVAL_MS)
            val event = schedule.ready
            if (event == null) {
                schedule.wakeAt?.let(::scheduleWake)
                return
            }
            if (!process(event, workGeneration)) return
        }
    }

    private fun scheduleWake(at: Long) {
        timer?.cancel()
        timer = scope.launch {
            delay((at - System.currentTimeMillis()).coerceAtLeast(0))
            wake.trySend(Unit)
        }
    }

    private suspend fun process(event: HardcoverOutboxEvent, workGeneration: Long): Boolean {
        val active = {
            store.enabled.value && workGeneration == generation.get() && service.activeAccountKey() == event.accountKey
        }
        val outcome = try {
            val session = service.currentSession() ?: return false
            if (session.accountKey != event.accountKey || !active()) return false
            resolveMatch(session, event, active)?.let { apply(session, it, event, active) }
            Outcome.Sent
        } catch (e: CancellationException) {
            throw e
        } catch (_: HardcoverAccountChangedException) {
            return false
        } catch (e: HardcoverTransientException) {
            Outcome.Deferred(e.message ?: OFFLINE_MESSAGE, e.retryAfterMs, waitingForNetwork = false)
        } catch (_: IOException) {
            Outcome.Deferred(OFFLINE_MESSAGE, null, waitingForNetwork = true)
        } catch (e: Exception) {
            Outcome.Failed(e.message ?: "Hardcover sync failed.")
        }
        if (!active()) return false
        return record(event, outcome)
    }

    private suspend fun record(event: HardcoverOutboxEvent, outcome: Outcome): Boolean {
        val now = System.currentTimeMillis()
        try {
            when (outcome) {
                Outcome.Sent -> {
                    outbox.dao.delete(listOf(event.id))
                    lastSentAt[event.localKey] = now
                }
                is Outcome.Deferred -> {
                    val attempts = event.attempts + 1
                    val next = now + maxOf(hardcoverBackoffMs(attempts), outcome.retryAfterMs ?: 0L)
                    outbox.dao.defer(event.id, attempts, next, outcome.waitingForNetwork, outcome.message)
                    mutableStatus.value = HardcoverSyncStatus(event.title, outcome.message, isError = true)
                }
                is Outcome.Failed -> {
                    outbox.dao.fail(event.id, outcome.message)
                    mutableStatus.value = HardcoverSyncStatus(event.title, outcome.message, isError = true)
                }
            }
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (_: Exception) {
            storageError.value = STORAGE_MESSAGE
            return false
        }
    }

    private suspend fun resolveMatch(
        session: HardcoverSession,
        event: HardcoverOutboxEvent,
        active: () -> Boolean,
    ): HardcoverBookMatch? {
        store.match(event.localKey)?.let { return it }
        if (store.isUnlinked(event.localKey)) return null
        val identifiers = HardcoverIdentifiers(event.isbn10, event.isbn13, event.asin)
        val identified = hardcoverIdentifierMatch(identifiers, service.editionsByIdentifiers(session, identifiers))
        if (!active()) throw HardcoverAccountChangedException()
        val match = when (identified) {
            is HardcoverIdentifierMatch.Matched -> HardcoverBookMatch(
                localKey = event.localKey,
                localTitle = event.title,
                localAuthor = event.author,
                hardcoverBookId = identified.bookId,
                hardcoverTitle = identified.bookTitle.ifBlank { event.title },
                automatic = true,
                editionId = identified.edition?.id,
            )
            HardcoverIdentifierMatch.Conflict -> throw HardcoverMatchRequiredException(CONFLICT_MESSAGE)
            HardcoverIdentifierMatch.NoHit -> titleMatch(session, event, active)
        }
        store.match(event.localKey)?.let { return it }
        if (store.isUnlinked(event.localKey)) return null
        store.saveMatch(match)
        return match
    }

    private suspend fun titleMatch(
        session: HardcoverSession,
        event: HardcoverOutboxEvent,
        active: () -> Boolean,
    ): HardcoverBookMatch {
        val author = event.author?.takeIf { it.isNotBlank() } ?: throw HardcoverMatchRequiredException(NO_MATCH_MESSAGE)
        val hit = hardcoverExactMatch(event.title, author, service.searchBooks("${event.title} $author", limit = 10, session = session))
        if (!active()) throw HardcoverAccountChangedException()
        hit ?: throw HardcoverMatchRequiredException(NO_MATCH_MESSAGE)
        return HardcoverBookMatch(event.localKey, event.title, author, hit.id, hit.title, automatic = true)
    }

    private suspend fun apply(
        session: HardcoverSession,
        match: HardcoverBookMatch,
        event: HardcoverOutboxEvent,
        active: () -> Boolean,
    ) {
        var startedRead = false
        repeat(MAX_SYNC_STEPS) {
            if (!active()) throw HardcoverAccountChangedException()
            val state = service.bookState(session, match.hardcoverBookId, match.editionId)
            if (!active()) throw HardcoverAccountChangedException()
            when (val plan = hardcoverSyncPlan(state, event.mediaType, event.fraction, event.finished, event.initialFraction)) {
                is HardcoverSyncPlan.AddToLibrary -> {
                    service.insertUserBook(session, match.hardcoverBookId, plan.statusId, plan.editionId, event.startedAt)
                    startedRead = plan.statusId == 2
                }
                is HardcoverSyncPlan.SetStatus -> {
                    service.updateUserBookStatus(session, plan.userBookId, plan.statusId,
                        if (plan.statusId == 3) event.occurredAt else event.startedAt)
                    if (plan.statusId == 3) return
                    startedRead = true
                }
                is HardcoverSyncPlan.StartRead ->
                    service.insertUserBookRead(session, plan.userBookId, plan.editionId, event.startedAt)
                is HardcoverSyncPlan.FinishRead -> {
                    service.updateReadFinishedDate(session, plan.readId, hardcoverDate(event.occurredAt), event.occurredAt)
                    if (!active()) throw HardcoverAccountChangedException()
                    service.updateUserBookStatus(session, plan.userBookId, 3, event.occurredAt)
                    mutableStatus.value = HardcoverSyncStatus(match.hardcoverTitle, "Marked as read.", isError = false)
                    return
                }
                is HardcoverSyncPlan.NeedsEdition -> throw HardcoverMatchRequiredException(plan.reason)
                is HardcoverSyncPlan.WriteProgress -> {
                    service.updateReadProgress(
                        session = session,
                        readId = plan.readId,
                        editionId = plan.editionId,
                        progressPages = plan.pages,
                        progressSeconds = plan.seconds,
                        occurredAt = event.occurredAt,
                        startedAt = hardcoverDate(event.startedAt).takeIf { startedRead },
                    )
                    mutableStatus.value = HardcoverSyncStatus(
                        match.hardcoverTitle,
                        "Progress synced (${(event.fraction * 100).roundToInt()}%).",
                        isError = false,
                    )
                    return
                }
                is HardcoverSyncPlan.Skip -> {
                    mutableStatus.value = HardcoverSyncStatus(match.hardcoverTitle, plan.reason, isError = false)
                    return
                }
                HardcoverSyncPlan.AlreadyFinished, HardcoverSyncPlan.UpToDate -> return
            }
        }
        throw HardcoverException("Hardcover did not confirm the saved update. Retry it from Hardcover Hub.")
    }

    private fun networkAvailability(): Flow<Unit> = callbackFlow {
        val manager = checkNotNull(context.getSystemService(ConnectivityManager::class.java))
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                trySend(Unit)
            }
        }
        manager.registerDefaultNetworkCallback(callback)
        awaitClose { manager.unregisterNetworkCallback(callback) }
    }
}

fun Book.hardcoverLocalKey(): String = hardcoverLocalKey(source, connectionId, id)
