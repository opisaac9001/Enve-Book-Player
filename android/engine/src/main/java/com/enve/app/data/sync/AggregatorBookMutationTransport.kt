package com.enve.app.data.sync

import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PendingBookMutation
import com.enve.core.data.local.PendingBookMutationKind
import com.enve.core.data.local.ProfileServerSyncStore
import com.enve.core.data.local.pendingBookMutationAccountKey
import com.enve.core.data.local.pendingBookMutationConnection
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AggregatorBookMutationTransport @Inject constructor(
    private val aggregator: AggregatorRepository,
    private val connections: ConnectionRegistry,
    private val books: BookCacheDao,
    private val serverSync: ProfileServerSyncStore,
) : PendingBookMutationTransport {
    override val syncEnabled: Boolean get() = serverSync.isEnabled

    override fun accountKey(book: Book): String =
        connections.getConnectionsSync().pendingBookMutationAccountKey(book.source.name, book.connectionId)

    override fun target(mutation: PendingBookMutation): PendingBookMutationTarget {
        if (BookSource.entries.none { it.name == mutation.source }) return PendingBookMutationTarget.UNAVAILABLE
        val registered = connections.getConnectionsSync()
        val connection = registered.pendingBookMutationConnection(mutation.source, mutation.connectionId)
        return when {
            connection == null ->
                if (mutation.connectionId == null && mutation.accountKey.isEmpty() &&
                    registered.none { it.source.name == mutation.source }
                ) PendingBookMutationTarget.READY else PendingBookMutationTarget.UNAVAILABLE
            !connection.enabled || connection.pendingBookMutationAccountKey() != mutation.accountKey ->
                PendingBookMutationTarget.UNAVAILABLE
            connection.needsReauth -> PendingBookMutationTarget.NEEDS_SIGN_IN
            else -> PendingBookMutationTarget.READY
        }
    }

    override suspend fun applyLocally(book: Book, kind: PendingBookMutationKind, value: String) {
        books.insertIfAbsent(book.toCachedBook())
        val now = System.currentTimeMillis()
        val connectionId = book.connectionId
        when (kind) {
            PendingBookMutationKind.RATING -> books.updatePersonalRating(book.id, connectionId, value.toFloat(), now)
            PendingBookMutationKind.READ_STATUS -> if (book.source == BookSource.BOOKORBIT && connectionId != null) {
                val rating = books.getByIdAndConnection(book.id, connectionId)?.personalRating
                books.updateBookOrbitUserData(book.id, connectionId, rating, value, now)
            } else {
                books.updateReadState(
                    bookId = book.id,
                    connectionId = connectionId,
                    finished = PendingBookMutationPolicy.isFinishedStatus(value),
                    hideFromContinue = value == "ABANDONED",
                    serverReadStatus = value,
                    nowMs = now,
                )
            }
        }
    }

    override suspend fun send(mutation: PendingBookMutation): Result<Unit> {
        val source = BookSource.valueOf(mutation.source)
        return aggregator.pushBookEdit(source, mutation.connectionId, mutation.accountKey) { adapter ->
            when (mutation.kind) {
                PendingBookMutationKind.RATING -> adapter.updatePersonalRating(mutation.bookId, mutation.value.toInt())
                PendingBookMutationKind.READ_STATUS -> adapter.updateBookStatus(mutation.bookId, mutation.value)
            }
        }
    }
}
