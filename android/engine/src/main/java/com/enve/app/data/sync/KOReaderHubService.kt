package com.enve.app.data.sync

import android.content.Context
import android.util.Log
import com.enve.core.data.local.BookCacheDao
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.toBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.sync.KOReaderBookLink
import com.enve.core.data.sync.KOReaderFileIdentity
import com.enve.core.data.sync.KOReaderHubConfig
import com.enve.core.data.sync.KOReaderProgress
import com.enve.core.data.sync.SyncSnapshot
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

private const val TAG = "KOReaderHubService"

@Singleton
class KOReaderHubService @Inject constructor(
    private val client: KOReaderHubClient,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val deviceIdentity: DeviceIdentity,
    private val bookCacheDao: BookCacheDao,
    @ApplicationContext private val context: Context,
) {
    private val json = Json { ignoreUnknownKeys = true }

    val config: KOReaderHubConfig
        get() = KOReaderHubConfig(
            serverUrl = prefs.getKosyncHubServerUrlSync(),
            username = prefs.getKosyncHubUsernameSync(),
            passwordHash = vault.get(CredentialVault.KOSYNC_HUB_PASSWORD_HASH).orEmpty(),
            autoSyncEnabled = prefs.getKosyncHubAutoSyncSync(),
        )

    suspend fun updateConfig(
        serverUrl: String,
        username: String,
        plaintextPassword: String?,
        autoSync: Boolean,
    ) {
        prefs.setKosyncHubConfig(serverUrl.trim(), username.trim(), autoSync)
        if (!plaintextPassword.isNullOrEmpty()) {
            vault.put(CredentialVault.KOSYNC_HUB_PASSWORD_HASH, md5Hash(plaintextPassword))
        }
    }

    suspend fun clearConfig() {
        prefs.clearKosyncHubConfig()
        vault.remove(CredentialVault.KOSYNC_HUB_PASSWORD_HASH)
        vault.remove(CredentialVault.KOSYNC_HUB_LINKS_JSON)
    }

    suspend fun authorize(): Result<Unit> {
        val c = config
        val base = c.baseUrl ?: return Result.failure(IllegalStateException("Not configured"))
        return client.authorize(base, c.username, c.passwordHash)
    }

    suspend fun register(serverUrl: String, username: String, plaintextPassword: String): Result<Unit> {
        val base = KOReaderHubConfig(serverUrl = serverUrl).baseUrl
            ?: return Result.failure(IllegalStateException("Invalid server URL"))
        return client.register(base, username, md5Hash(plaintextPassword))
    }

    suspend fun testAuth(serverUrl: String, username: String, plaintextPassword: String): Result<Unit> {
        val base = KOReaderHubConfig(serverUrl = serverUrl).baseUrl
            ?: return Result.failure(IllegalStateException("Invalid server URL"))
        return client.authorize(base, username, md5Hash(plaintextPassword))
    }

    private fun loadLinks(): MutableMap<String, KOReaderBookLink> {
        val raw = vault.get(CredentialVault.KOSYNC_HUB_LINKS_JSON) ?: return mutableMapOf()
        return runCatching {
            json.decodeFromString(ListSerializer(KOReaderBookLink.serializer()), raw)
                .associateBy { it.bookStableId }
                .toMutableMap()
        }.getOrDefault(mutableMapOf())
    }

    private fun saveLinks(links: Map<String, KOReaderBookLink>) {
        val encoded = json.encodeToString(
            ListSerializer(KOReaderBookLink.serializer()), links.values.toList(),
        )
        vault.put(CredentialVault.KOSYNC_HUB_LINKS_JSON, encoded)
    }

    val links: List<KOReaderBookLink> get() = loadLinks().values.toList()

    fun link(for_: String): KOReaderBookLink? = loadLinks()[for_]

    fun link(
        book: Book,
        documentHash: String,
        isAutomatic: Boolean,
        fileIdentity: KOReaderFileIdentity? = null,
    ) {
        val trimmed = documentHash.trim().lowercase()
        if (trimmed.length != 32 || !trimmed.all { it.isDigit() || it in 'a'..'f' }) return
        val links = loadLinks()
        links[book.uniqueKey] = repairedLink(
            previous = links[book.uniqueKey],
            bookStableId = book.uniqueKey,
            documentHash = trimmed,
            isAutomatic = isAutomatic,
            fileIdentity = fileIdentity,
        )
        saveLinks(links)
    }

    fun linkFilename(book: Book, filename: String?) {
        val trimmed = filename?.trim()?.takeIf { it.isNotEmpty() }
        val links = loadLinks()
        val existing = links[book.uniqueKey]
        when {
            existing != null -> {
                if (existing.filename == trimmed) return
                if (trimmed == null && existing.documentHash.isBlank()) links.remove(book.uniqueKey)
                else links[book.uniqueKey] = existing.copy(filename = trimmed)
            }
            trimmed != null -> links[book.uniqueKey] = KOReaderBookLink(
                bookStableId = book.uniqueKey,
                isAutomatic = true,
                filename = trimmed,
            )
            else -> return
        }
        saveLinks(links)
    }

    fun unlink(bookStableId: String) {
        val links = loadLinks()
        if (links.remove(bookStableId) != null) saveLinks(links)
    }

    private fun updateLinkSyncStatus(bookStableId: String, percentage: Double) {
        val links = loadLinks()
        val link = links[bookStableId] ?: return
        links[bookStableId] = link.copy(
            lastSyncedAt = System.currentTimeMillis(),
            lastSyncedPercentage = percentage,
        )
        saveLinks(links)
    }

    private suspend fun ensureDocumentHash(book: Book): String? {
        val existing = loadLinks()[book.uniqueKey]
        val pinned = existing?.documentHash?.takeIf { it.isNotBlank() }
        if (existing != null && !existing.isAutomatic) return pinned
        if (book.mediaType != AppMediaType.EBOOK) return pinned
        val file = resolveEbookFile(book) ?: return pinned
        val identity = KOReaderFileIdentity.read(file) ?: return pinned
        if (pinned != null && existing.fileIdentity == identity) return pinned
        val hash = computePartialMd5(file) ?: return pinned
        if (KOReaderFileIdentity.read(file) != identity) return pinned

        val current = loadLinks()[book.uniqueKey]
        if (current != existing) return current?.documentHash?.takeIf { it.isNotBlank() }
        link(book, hash, isAutomatic = true, fileIdentity = identity)
        return hash
    }

    fun suggestedFilename(book: Book): String? =
        loadLinks()[book.uniqueKey]?.filename ?: KOReaderDocumentId.filenameSuggestion(book)

    private suspend fun documentIdsFor(book: Book): DocumentIds = DocumentIds(
        binaryHash = ensureDocumentHash(book),
        filenameHash = loadLinks()[book.uniqueKey]?.filename?.let(KOReaderDocumentId::fromFilename),
    )

    fun resolveEbookFile(book: Book): File? {
        val dir = File(context.cacheDir, "ebooks")
        if (!dir.isDirectory) return null
        val safeName = book.id.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        return dir.listFiles()
            ?.firstOrNull {
                it.isFile && it.length() > 10_240 &&
                    it.name.startsWith("$safeName.") && !it.name.endsWith(".tmp")
            }
    }

    suspend fun computePartialMd5(file: File): String? =
        withContext(Dispatchers.IO) { runCatching { PartialMd5.compute(file) }.getOrNull() }

    suspend fun pushIfConfigured(book: Book, percentage: Float, locatorJson: String?) {
        val c = config
        if (!c.isConfigured || !c.autoSyncEnabled) return
        if (book.mediaType != AppMediaType.EBOOK) return
        val base = c.baseUrl ?: return
        val document = documentIdsFor(book).pushTarget ?: return

        val file = resolveEbookFile(book)
        val xpointer = if (locatorJson != null && file != null) {
            KOReaderHubXPointerConverter.xpointer(locatorJson, file)
        } else null
        val progressStr = xpointer ?: String.format(java.util.Locale.US, "%.6f", percentage)

        try {
            client.pushProgress(
                baseUrl = base,
                username = c.username,
                passwordHash = c.passwordHash,
                document = document,
                progress = progressStr,
                percentage = percentage.toDouble(),
                device = deviceIdentity.deviceName,
                deviceId = deviceIdentity.deviceId,
            ).onSuccess {
                updateLinkSyncStatus(book.uniqueKey, percentage.toDouble())
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w(TAG, "push failed for ${book.title}: ${e.message}")
        }
    }

    suspend fun snapshotFor(book: Book): SyncSnapshot? {
        val c = config
        if (!c.isConfigured) return null
        if (book.mediaType != AppMediaType.EBOOK) return null
        val base = c.baseUrl ?: return null
        val documents = documentIdsFor(book).pullTargets
        if (documents.isEmpty()) return null

        val remote = selectRemoteRecord(
            documents.mapNotNull { document ->
                client.fetchProgress(base, c.username, c.passwordHash, document).getOrNull()
            },
        ) ?: return null
        val pct = remote.percentage.coerceIn(0.0, 1.0)
        if (pct <= 0.0) return null

        val file = resolveEbookFile(book)
        val locatorJson = if (remote.progress.isNotBlank() && file != null) {
            KOReaderHubXPointerConverter.locatorJson(remote.progress, pct, file)
        } else null

        return SyncSnapshot(
            percentage = pct.toFloat(),
            locatorJson = locatorJson,
            source = remote.device.ifBlank { "KOReader" },
            updatedAt = remote.timestamp?.let { it * 1000L },
        )
    }

    suspend fun pullAllAndMerge(): Int {
        val c = config
        if (!c.isConfigured) return 0
        val ebooks = bookCacheDao.observeAll().first()
            .filter { it.mediaType == AppMediaType.EBOOK.name }
            .map { it.toBook() }

        var applied = 0
        for (book in ebooks) {
            try {
                val snapshot = snapshotFor(book) ?: continue
                val local = book.epubProgress ?: 0f
                if (snapshot.percentage <= local + 0.005f) continue
                bookCacheDao.updateUnifiedProgress(
                    bookId = book.id,
                    connectionId = book.connectionId,
                    progress = snapshot.percentage,
                    currentTimeSec = -1L,
                    locatorJson = snapshot.locatorJson,
                    nowMs = System.currentTimeMillis(),
                )
                updateLinkSyncStatus(book.uniqueKey, snapshot.percentage.toDouble())
                applied++
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "merge failed for ${book.title}: ${e.message}")
            }
        }
        prefs.setKosyncHubLastSyncTime(System.currentTimeMillis())
        return applied
    }

    private data class DocumentIds(val binaryHash: String?, val filenameHash: String?) {
        val pushTarget: String? = filenameHash ?: binaryHash
        val pullTargets: List<String> = listOfNotNull(pushTarget, binaryHash).distinct()
    }

    companion object {
        const val MAX_HASH_HISTORY = 5

        fun selectRemoteRecord(records: List<KOReaderProgress>): KOReaderProgress? {
            val newest = records.mapNotNull { it.timestamp?.takeIf { ts -> ts > 0L } }.maxOrNull()
                ?: return records.firstOrNull()
            return records.first { it.timestamp == newest }
        }

        fun repairedLink(
            previous: KOReaderBookLink?,
            bookStableId: String,
            documentHash: String,
            isAutomatic: Boolean,
            fileIdentity: KOReaderFileIdentity?,
            filename: String? = previous?.filename,
        ): KOReaderBookLink {
            if (previous == null) {
                return KOReaderBookLink(
                    bookStableId = bookStableId,
                    documentHash = documentHash,
                    isAutomatic = isAutomatic,
                    fileIdentity = fileIdentity,
                    filename = filename,
                )
            }
            if (previous.documentHash == documentHash) {
                return previous.copy(
                    isAutomatic = isAutomatic,
                    fileIdentity = fileIdentity,
                    filename = filename,
                )
            }
            return KOReaderBookLink(
                bookStableId = bookStableId,
                documentHash = documentHash,
                isAutomatic = isAutomatic,
                fileIdentity = fileIdentity,
                filename = filename,
                previousHashes = (listOf(previous.documentHash) + previous.previousHashes)
                    .filter { it.isNotBlank() && it != documentHash }
                    .take(MAX_HASH_HISTORY),
            )
        }
    }
}
