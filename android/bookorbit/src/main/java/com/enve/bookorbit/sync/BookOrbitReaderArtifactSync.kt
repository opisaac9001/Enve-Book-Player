package com.enve.bookorbit.sync

import com.enve.bookorbit.BOOKORBIT_PROVIDER_SOURCE
import com.enve.bookorbit.BookOrbitProviderAdapter
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.model.ReaderAnnotationDao
import com.enve.core.data.provider.ProviderAdapter
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

data class BookOrbitReaderArtifactSyncResult(
    val pulled: Int,
    val pushed: Int,
)

@Singleton
class BookOrbitReaderArtifactSync @Inject constructor(
    private val adapter: BookOrbitProviderAdapter,
    private val dao: ReaderAnnotationDao,
) {
    suspend fun sync(book: Book): BookOrbitReaderArtifactSyncResult =
        syncBookOrbitReaderArtifacts(book, adapter, dao)
}

internal suspend fun syncBookOrbitReaderArtifacts(
    book: Book,
    adapter: ProviderAdapter,
    dao: ReaderAnnotationDao,
): BookOrbitReaderArtifactSyncResult {
    val dirty = dao.getDirtyForBookAndProvider(book.id, book.connectionId, BOOKORBIT_PROVIDER_SOURCE)
    var pushed = 0
    if (dirty.isNotEmpty()) {
        val result = adapter.pushAnnotations(book, dirty).getOrThrow()
        result.accepted.forEach { accepted ->
            val local = dirty.firstOrNull { it.id == accepted.id }
            if (local?.deletedAt != null) {
                dao.purge(accepted.id)
            } else {
                dao.markClean(accepted.id, accepted.etag, accepted.serverId)
            }
        }
        pushed = result.accepted.size
    }

    val remote = adapter.fetchAnnotations(book).getOrThrow()
        .map { it.copy(connectionId = book.connectionId, connectionUnresolved = false) }
    val reconciled = remote.mapNotNull { record ->
        val serverId = record.serverId
        val existing = serverId?.let {
            dao.getByServerIdForBook(it, BOOKORBIT_PROVIDER_SOURCE, book.id, book.connectionId)
        }
        val sameId = dao.getById(record.id)
        when {
            existing != null && existing.syncDirty -> null
            existing != null -> record.copy(id = existing.id)
            sameId != null -> record.copy(id = UUID.randomUUID().toString())
            else -> record
        }
    }
    if (reconciled.isNotEmpty()) dao.upsertAll(reconciled)
    val serverIds = remote.mapNotNull(ReaderAnnotation::serverId).distinct()
    if (serverIds.isNotEmpty()) {
        dao.purgeCleanProviderRowsMissing(book.id, book.connectionId, BOOKORBIT_PROVIDER_SOURCE, serverIds)
    }
    return BookOrbitReaderArtifactSyncResult(pulled = reconciled.size, pushed = pushed)
}
