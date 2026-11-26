package com.enve.app.data.readwise

import com.enve.app.data.repository.AnnotationRepository
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.BookCacheDao
import com.enve.engine.readwise.ReadwiseExportPreview
import com.enve.engine.readwise.ReadwiseExportProgress
import com.enve.engine.readwise.ReadwiseExportResult
import com.enve.engine.readwise.ReadwiseExportScope
import com.enve.engine.readwise.ReadwiseFacade
import com.enve.engine.readwise.ReadwiseFailure
import com.enve.engine.readwise.ReadwisePreviewHighlight
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ReadwiseExportService @Inject constructor(
    private val client: ReadwiseClient,
    private val vault: CredentialVault,
    private val receipts: ReadwiseReceiptStore,
    private val annotations: AnnotationRepository,
    private val bookCacheDao: BookCacheDao,
) : ReadwiseFacade {
    private val sender = ReadwiseExportSender(client, receipts)
    private val exportMutex = Mutex()
    private val connected = MutableStateFlow(storedToken() != null)
    override val isConnected: StateFlow<Boolean> = connected.asStateFlow()

    internal fun backupToken(): String? = storedToken()

    internal fun restoreBackupToken(token: String): Boolean {
        val normalized = normalizedReadwiseToken(token) ?: return false
        if (storedToken() != null) return false
        vault.put(TOKEN_KEY, normalized)
        connected.value = true
        return true
    }

    override suspend fun connect(token: String): ReadwiseFailure? {
        val normalized = normalizedReadwiseToken(token) ?: return ReadwiseFailure.INVALID_TOKEN
        checkToken(normalized)?.let { return it }
        currentCoroutineContext().ensureActive()
        vault.put(TOKEN_KEY, normalized)
        connected.value = true
        return null
    }

    override suspend fun validate(): ReadwiseFailure? {
        val token = storedToken() ?: return ReadwiseFailure.NOT_CONNECTED
        return checkToken(token)
    }

    override fun disconnect() {
        vault.remove(TOKEN_KEY)
        connected.value = false
    }

    override suspend fun preview(scope: ReadwiseExportScope): ReadwiseExportPreview {
        val account = storedToken()?.let(ReadwiseHighlightMapper::accountFingerprint)
        val plan = plan(scope, account?.let { receipts.receipts(it) }.orEmpty())
        return ReadwiseExportPreview(
            scope = scope,
            bookCount = plan.bookCount,
            newCount = plan.pending.count { !it.changed },
            changedCount = plan.pending.count { it.changed },
            alreadySentCount = plan.alreadySentCount,
            excludedCount = plan.excludedCount + plan.oversizedCount,
            samples = plan.pending.take(PREVIEW_SAMPLES).map {
                ReadwisePreviewHighlight(it.payload.title, it.payload.author, it.payload.text, it.payload.note)
            },
        )
    }

    override suspend fun export(
        scope: ReadwiseExportScope,
        onProgress: (ReadwiseExportProgress) -> Unit,
    ): ReadwiseExportResult {
        exportMutex.withLock {
            val token = storedToken() ?: return ReadwiseExportResult(0, 0, ReadwiseFailure.NOT_CONNECTED)
            val account = ReadwiseHighlightMapper.accountFingerprint(token)
            val plan = plan(scope, receipts.receipts(account))
            val result = if (plan.pending.isEmpty()) {
                ReadwiseExportResult(0, 0, null)
            } else {
                sender.send(token, account, plan.pending, onProgress)
            }
            if (plan.oversizedCount == 0) return result
            return result.copy(
                unsentCount = result.unsentCount + plan.oversizedCount,
                failure = result.failure ?: ReadwiseFailure.REJECTED,
            )
        }
    }

    private suspend fun plan(scope: ReadwiseExportScope, sent: Map<String, ReadwiseReceipt>): ReadwiseExportPlan {
        val rows = when (scope) {
            ReadwiseExportScope.AllBooks -> annotations.all().first()
            is ReadwiseExportScope.Book -> annotations.forBook(scope.bookId, scope.connectionId)
        }
        val bookIds = rows.mapTo(mutableSetOf()) { it.bookId }
        val catalog = bookIds.chunked(900).flatMap { bookCacheDao.getByIds(it) }
            .groupBy({ it.id }, { ReadwiseCatalogBook(it.source, it.title, it.author) })
        val books = rows.map { it.bookId to it.providerSource }.distinct().associateWith { (bookId, providerSource) ->
            ReadwiseHighlightMapper.bookInfo(catalog[bookId].orEmpty(), providerSource)
        }
        return ReadwiseExportPlanner.plan(rows, { books[it.bookId to it.providerSource] }, sent)
    }

    private suspend fun checkToken(token: String): ReadwiseFailure? =
        try {
            client.checkToken(token)
            null
        } catch (e: ReadwiseRequestException) {
            e.failure
        } catch (_: IOException) {
            ReadwiseFailure.NETWORK
        }

    private fun storedToken(): String? = vault.get(TOKEN_KEY)?.takeIf { it.isNotBlank() }

    private companion object {
        const val TOKEN_KEY = "readwise_access_token"
        const val PREVIEW_SAMPLES = 3
    }
}

internal fun normalizedReadwiseToken(raw: String): String? {
    val token = raw.trim().removePrefix("Token ").trim()
    return token.takeIf { it.isNotEmpty() && it.length <= 256 && it.all { c -> c in '!'..'~' } }
}
