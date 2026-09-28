package com.enve.bookorbit.sync

import com.enve.bookorbit.BOOKORBIT_PROVIDER_SOURCE
import com.enve.bookorbit.BookOrbitProviderAdapter
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import com.enve.core.data.model.ReaderAnnotationDao
import com.enve.core.data.provider.ProviderAdapter
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
    val dirty = dao.getDirtyForBookAndProvider(book.id, BOOKORBIT_PROVIDER_SOURCE)
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
    val reconciled = remote.mapNotNull { record ->
        val existing = record.serverId?.let { dao.getByServerId(it, BOOKORBIT_PROVIDER_SOURCE) }
        when {
            existing == null -> record
            existing.syncDirty -> null
            else -> record.copy(id = existing.id)
        }
    }
    if (reconciled.isNotEmpty()) dao.upsertAll(reconciled)
    val serverIds = remote.mapNotNull(ReaderAnnotation::serverId).distinct()
    if (serverIds.isNotEmpty()) {
        dao.purgeCleanProviderRowsMissing(book.id, BOOKORBIT_PROVIDER_SOURCE, serverIds)
    }
    return BookOrbitReaderArtifactSyncResult(pulled = reconciled.size, pushed = pushed)
}
