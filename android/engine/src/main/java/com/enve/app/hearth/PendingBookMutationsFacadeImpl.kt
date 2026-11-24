package com.enve.app.hearth

import com.enve.app.data.repository.AggregatorRepository
import com.enve.app.data.sync.PendingBookMutationReplay
import com.enve.app.data.sync.PendingBookMutationScheduler
import com.enve.app.data.sync.PendingBookMutationTrigger
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PendingBookMutation
import com.enve.core.data.local.PendingBookMutationKind
import com.enve.core.data.local.PendingBookMutationStore
import com.enve.core.data.local.forCurrentAccounts
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.ProviderConnection
import com.enve.core.di.ApplicationScope
import com.enve.engine.library.BookEditOutcome
import com.enve.engine.library.PendingBookMutationsFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PendingBookMutationsFacadeImpl @Inject constructor(
    private val store: PendingBookMutationStore,
    private val replay: PendingBookMutationReplay,
    private val scheduler: PendingBookMutationScheduler,
    private val aggregator: AggregatorRepository,
    private val connections: ConnectionRegistry,
    @ApplicationScope parentScope: CoroutineScope,
) : PendingBookMutationsFacade {
    private val visible = MutableStateFlow(
        store.mutations.value.let { if (it.isEmpty()) it else it.forCurrentAccounts(connections.getConnectionsSync()) },
    )
    override val pending: StateFlow<List<PendingBookMutation>> = visible.asStateFlow()

    init {
        CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.Default).launch {
            combine(store.mutations, connections.connections) { _, registered -> registered }.collect { publish(it) }
        }
    }

    override fun readStatusOptions(book: Book): List<String> = aggregator.readStatusOptions(book)

    override suspend fun setPersonalRating(book: Book, rating: Int): BookEditOutcome {
        if (!aggregator.supportsPersonalRating(book)) return BookEditOutcome.REJECTED
        return replay.submit(book, PendingBookMutationKind.RATING, rating.coerceIn(1, 5).toString()).also { publish() }
    }

    override suspend fun setReadStatus(book: Book, status: String): BookEditOutcome {
        val normalized = status.uppercase()
        if (normalized !in readStatusOptions(book)) return BookEditOutcome.REJECTED
        if (book.usesProgressQueue(normalized)) {
            return if (aggregator.updateBookStatus(book, normalized).isSuccess) BookEditOutcome.SYNCED
            else BookEditOutcome.NOT_SAVED
        }
        return replay.submit(book, PendingBookMutationKind.READ_STATUS, normalized).also { publish() }
    }

    override suspend fun retry(mutation: PendingBookMutation): BookEditOutcome =
        replay.retry(mutation.identity).also { publish() }

    override suspend fun discard(mutation: PendingBookMutation) {
        replay.discard(mutation.identity, mutation.revision)
        publish()
    }

    override fun replayOnForeground() {
        scheduler.request(PendingBookMutationTrigger.FOREGROUND)
    }

    private suspend fun publish() = publish(connections.connections.first())

    private fun publish(registered: List<ProviderConnection>) = synchronized(visible) {
        visible.value = store.mutations.value.forCurrentAccounts(registered)
    }

    private fun Book.usesProgressQueue(status: String): Boolean =
        (mediaType == AppMediaType.AUDIOBOOK || mediaType == AppMediaType.PODCAST) && status in PROGRESS_QUEUE_STATUSES

    private companion object {
        val PROGRESS_QUEUE_STATUSES = setOf("READ", "UNREAD")
    }
}
