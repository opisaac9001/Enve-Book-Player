package com.enve.app.data.sync

import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.PendingBookMutation
import com.enve.core.data.local.PendingBookMutationFailure
import com.enve.core.data.local.PendingBookMutationIdentity
import com.enve.core.data.local.PendingBookMutationKind
import com.enve.core.data.local.PendingBookMutationStore
import com.enve.core.data.local.forCurrentAccounts
import com.enve.core.data.model.Book
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.provider.ProviderMutationException
import com.enve.engine.library.BookEditOutcome
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

enum class PendingBookMutationTrigger { SUBMIT, MANUAL, START, FOREGROUND, NETWORK }

enum class PendingBookMutationTarget { READY, UNAVAILABLE, NEEDS_SIGN_IN }

interface PendingBookMutationTransport {
    val syncEnabled: Boolean

    fun accountKey(book: Book): String

    fun target(mutation: PendingBookMutation): PendingBookMutationTarget

    suspend fun applyLocally(book: Book, kind: PendingBookMutationKind, value: String)

    suspend fun send(mutation: PendingBookMutation): Result<Unit>
}

internal object PendingBookMutationPolicy {
    const val MAX_AUTOMATIC_ATTEMPTS = 8
    private const val FIRST_RETRY_MS = 30_000L
    private const val MAX_RETRY_MS = 60L * 60L * 1_000L
    private const val AUTH_RETRY_MS = 15L * 60L * 1_000L
    private val finishedStatuses = setOf("READ", "SKIMMED", "COMPLETED", "FINISHED")

    fun classify(error: Throwable): PendingBookMutationFailure = when (error) {
        is ProviderMutationException -> classify(error.httpStatus)
        is retrofit2.HttpException -> classify(error.code())
        is IOException -> PendingBookMutationFailure.TRANSIENT
        is UnsupportedOperationException, is NumberFormatException -> PendingBookMutationFailure.REJECTED
        else -> PendingBookMutationFailure.TRANSIENT
    }

    fun classify(httpStatus: Int): PendingBookMutationFailure = when (httpStatus) {
        401 -> PendingBookMutationFailure.AUTH
        408, 425, 429 -> PendingBookMutationFailure.TRANSIENT
        in 400..499 -> PendingBookMutationFailure.REJECTED
        else -> PendingBookMutationFailure.TRANSIENT
    }

    fun retryDelayMs(attempts: Int): Long {
        val doublings = (attempts - 1).coerceIn(0, 16)
        return (FIRST_RETRY_MS shl doublings).coerceAtMost(MAX_RETRY_MS)
    }

    fun isDue(mutation: PendingBookMutation, trigger: PendingBookMutationTrigger, now: Long): Boolean {
        if (trigger == PendingBookMutationTrigger.SUBMIT || trigger == PendingBookMutationTrigger.MANUAL) return true
        val sinceLastAttempt = now - mutation.lastAttemptAt
        return when (mutation.failure) {
            null -> true
            PendingBookMutationFailure.UNAVAILABLE -> true
            PendingBookMutationFailure.REJECTED -> false
            PendingBookMutationFailure.AUTH ->
                trigger != PendingBookMutationTrigger.NETWORK &&
                    mutation.attempts < MAX_AUTOMATIC_ATTEMPTS && sinceLastAttempt >= AUTH_RETRY_MS
            PendingBookMutationFailure.TRANSIENT ->
                mutation.attempts < MAX_AUTOMATIC_ATTEMPTS &&
                    (trigger == PendingBookMutationTrigger.NETWORK || sinceLastAttempt >= retryDelayMs(mutation.attempts))
        }
    }

    fun outcome(remaining: PendingBookMutation?): BookEditOutcome = when (remaining?.failure) {
        null -> if (remaining == null) BookEditOutcome.SYNCED else BookEditOutcome.WAITING
        PendingBookMutationFailure.TRANSIENT -> BookEditOutcome.WAITING
        PendingBookMutationFailure.AUTH -> BookEditOutcome.NEEDS_SIGN_IN
        PendingBookMutationFailure.REJECTED -> BookEditOutcome.REJECTED
        PendingBookMutationFailure.UNAVAILABLE -> BookEditOutcome.UNAVAILABLE
    }

    fun isFinishedStatus(status: String): Boolean = status.uppercase() in finishedStatuses
}

internal fun CachedBook.preservingPendingEdits(
    existing: CachedBook?,
    pending: List<PendingBookMutation>,
    connections: List<ProviderConnection>,
): CachedBook {
    if (pending.isEmpty()) return this
    val mine = pending
        .filter { it.source == source && it.connectionKey == connectionId.orEmpty() && it.bookId == id }
        .forCurrentAccounts(connections)
    if (mine.isEmpty()) return this
    var row = this
    mine.firstOrNull { it.kind == PendingBookMutationKind.RATING }?.value?.toFloatOrNull()?.let { rating ->
        row = row.copy(personalRating = rating)
    }
    mine.firstOrNull { it.kind == PendingBookMutationKind.READ_STATUS }?.let { status ->
        row = if (existing != null) {
            row.copy(
                serverReadStatus = existing.serverReadStatus,
                isFinished = existing.isFinished,
                hideFromContinue = existing.hideFromContinue,
                inProgress = existing.inProgress,
            )
        } else {
            val finished = PendingBookMutationPolicy.isFinishedStatus(status.value)
            val hidden = status.value == "ABANDONED"
            row.copy(
                serverReadStatus = status.value,
                isFinished = finished,
                hideFromContinue = hidden,
                inProgress = row.inProgress && !finished && !hidden,
            )
        }
    }
    return row
}

@Singleton
class PendingBookMutationReplay internal constructor(
    private val store: PendingBookMutationStore,
    private val transport: PendingBookMutationTransport,
    private val clock: () -> Long,
) {
    @Inject
    constructor(store: PendingBookMutationStore, transport: AggregatorBookMutationTransport) :
        this(store, transport, System::currentTimeMillis)

    private val mutex = Mutex()

    suspend fun submit(book: Book, kind: PendingBookMutationKind, value: String): BookEditOutcome {
        if (!transport.syncEnabled) {
            transport.applyLocally(book, kind, value)
            return BookEditOutcome.LOCAL_ONLY
        }
        val identity = PendingBookMutationIdentity(
            source = book.source.name,
            connectionKey = book.connectionId.orEmpty(),
            accountKey = transport.accountKey(book),
            bookId = book.id,
            kind = kind,
        )
        store.enqueue(identity, value, clock()) ?: return BookEditOutcome.NOT_SAVED
        transport.applyLocally(book, kind, value)
        replay(PendingBookMutationTrigger.SUBMIT, identity)
        return PendingBookMutationPolicy.outcome(store.find(identity))
    }

    suspend fun retry(identity: PendingBookMutationIdentity): BookEditOutcome {
        replay(PendingBookMutationTrigger.MANUAL, identity)
        return PendingBookMutationPolicy.outcome(store.find(identity))
    }

    suspend fun discard(identity: PendingBookMutationIdentity, revision: Long): Boolean =
        store.acknowledge(identity, revision)

    suspend fun replay(trigger: PendingBookMutationTrigger, only: PendingBookMutationIdentity? = null): Int =
        mutex.withLock {
            if (!transport.syncEnabled) return@withLock 0
            val identities = only?.let(::listOf)
                ?: store.mutations.value.sortedBy(PendingBookMutation::revision).map(PendingBookMutation::identity)
            var completed = 0
            for (identity in identities) {
                currentCoroutineContext().ensureActive()
                val mutation = store.find(identity) ?: continue
                if (!PendingBookMutationPolicy.isDue(mutation, trigger, clock())) continue
                when (transport.target(mutation)) {
                    PendingBookMutationTarget.UNAVAILABLE -> {
                        mark(mutation, PendingBookMutationFailure.UNAVAILABLE)
                        continue
                    }
                    PendingBookMutationTarget.NEEDS_SIGN_IN -> {
                        mark(mutation, PendingBookMutationFailure.AUTH)
                        continue
                    }
                    PendingBookMutationTarget.READY -> Unit
                }
                val error = try {
                    transport.send(mutation).exceptionOrNull()
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (failure: Exception) {
                    failure
                }
                when (error) {
                    null -> if (store.acknowledge(identity, mutation.revision)) completed += 1
                    is CancellationException -> throw error
                    else -> store.recordFailure(
                        identity,
                        mutation.revision,
                        when (transport.target(mutation)) {
                            PendingBookMutationTarget.UNAVAILABLE -> PendingBookMutationFailure.UNAVAILABLE
                            PendingBookMutationTarget.NEEDS_SIGN_IN -> PendingBookMutationFailure.AUTH
                            PendingBookMutationTarget.READY -> PendingBookMutationPolicy.classify(error)
                        },
                        clock(),
                    )
                }
            }
            completed
        }

    private suspend fun mark(mutation: PendingBookMutation, failure: PendingBookMutationFailure) {
        if (mutation.failure != failure) store.recordFailure(mutation.identity, mutation.revision, failure, clock())
    }
}
