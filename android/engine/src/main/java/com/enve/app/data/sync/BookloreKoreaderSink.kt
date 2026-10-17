package com.enve.app.data.sync

import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.SyncSnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BookloreKoreaderSink @Inject constructor(
    private val kosyncClient: KosyncClient,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val deviceIdentity: DeviceIdentity,
    private val connectionRegistry: ConnectionRegistry,
    private val serverSync: com.enve.core.data.local.ProfileServerSyncStore,
    private val offlineStorage: ComicOfflineStorage,
    private val locations: ProfileStorageLocations,
) {
    data class KoreaderCredentials(
        val username: String,
        val password: String,
        val enabled: Boolean,
    )

    private data class KoreaderTarget(val serverUrl: String, val connectionId: String?)

    fun credentialsForGrimmory(): KoreaderCredentials? {
        return targetForBook(null)?.let(::credentialsForTarget)
    }

    fun credentialsForBook(book: Book): KoreaderCredentials? {
        return targetForBook(book)?.let(::credentialsForTarget)
    }

    fun credentialsForConnectionId(connectionId: String): KoreaderCredentials? {
        val connection = connectionRegistry.getConnectionsSync().firstOrNull { it.id == connectionId }
            ?: return null
        return credentialsForTarget(
            KoreaderTarget(
                serverUrl = connection.serverUrl.trimEnd('/'),
                connectionId = connection.id,
            )
        )
    }

    fun saveCredentials(connectionId: String, serverUrl: String, username: String, password: String) {
        vault.put(CredentialVault.kosyncUsernameKeyForConnection(connectionId), username)
        vault.put(CredentialVault.kosyncPasswordKeyForConnection(connectionId), password)
        vault.put(CredentialVault.kosyncUsernameKey(serverUrl), username)
        vault.put(CredentialVault.kosyncPasswordKey(serverUrl), password)
    }

    fun clearCredentials(connectionId: String, serverUrl: String) {
        vault.remove(CredentialVault.kosyncUsernameKeyForConnection(connectionId))
        vault.remove(CredentialVault.kosyncPasswordKeyForConnection(connectionId))
        val sharedHost = connectionRegistry.getConnectionsSync()
            .any { it.id != connectionId && it.serverUrl.trimEnd('/') == serverUrl.trimEnd('/') }
        if (!sharedHost) {
            vault.remove(CredentialVault.kosyncUsernameKey(serverUrl))
            vault.remove(CredentialVault.kosyncPasswordKey(serverUrl))
        }
    }

    suspend fun testAuth(serverUrl: String, username: String, password: String): Result<Unit> {
        return kosyncClient.authenticate(serverUrl, username, password)
    }

    suspend fun push(book: Book, locatorJson: String?, percentage: Float): Result<Unit> {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return Result.success(Unit)
        if (book.mediaType != AppMediaType.EBOOK) return Result.success(Unit)
        val target = targetForBook(book) ?: return Result.failure(Exception("No server URL"))
        val creds = credentialsForTarget(target) ?: return Result.success(Unit)

        val file = localEbookFile(book) ?: return Result.success(Unit)
        val positionData = locatorJson
            ?.let { withContext(Dispatchers.IO) { KOReaderHubXPointerConverter.xpointer(it, file) } }
            ?: return Result.success(Unit)
        val hash = partialMd5(file) ?: return Result.success(Unit)

        if (!serverSync.accepts(syncStartedAt)) return Result.success(Unit)
        return kosyncClient.pushProgress(
            baseUrl = target.serverUrl,
            username = creds.username,
            password = creds.password,
            request = KosyncProgressRequest(
                document = hash,
                positionData = positionData,
                percentage = percentage,
                device = deviceIdentity.deviceName,
                deviceId = deviceIdentity.deviceId,
            ),
        )
    }

    suspend fun pull(book: Book): SyncSnapshot? {
        val syncStartedAt = System.currentTimeMillis()
        if (!serverSync.isEnabled) return null
        if (book.mediaType != AppMediaType.EBOOK) return null
        val target = targetForBook(book) ?: return null
        val creds = credentialsForTarget(target) ?: return null

        val file = localEbookFile(book) ?: return null
        val hash = partialMd5(file) ?: return null

        val response = kosyncClient.pullProgress(target.serverUrl, creds.username, creds.password, hash)
            .getOrNull() ?: return null

        val pct = response.percentage?.coerceIn(0f, 1f) ?: return null
        if (pct <= 0f) return null

        val locatorJson = response.positionData?.let { pos ->
            withContext(Dispatchers.IO) { KOReaderHubXPointerConverter.locatorJson(pos, pct.toDouble(), file) }
                ?: pos.takeIf { it.startsWith("epubcfi(") }
        }

        if (!serverSync.accepts(syncStartedAt)) return null
        return SyncSnapshot(
            percentage = pct,
            locatorJson = locatorJson,
            source = response.device ?: "KOReader",
        )
    }

    private fun localEbookFile(book: Book): File? {
        offlineStorage.getDownloadedFile(book.id)?.takeIf { it.isFile && it.length() > 0L }?.let { return it }
        val safeName = book.id.replace(Regex("[^a-zA-Z0-9_-]"), "_")
        return File(locations.cacheDirectory, "ebooks").listFiles()
            ?.filter {
                it.isFile && it.length() > 0L && it.name.startsWith("$safeName.") &&
                    !it.name.endsWith(".tmp") && !it.name.startsWith("$safeName.readaloud.")
            }
            ?.maxByOrNull(File::lastModified)
    }

    private suspend fun partialMd5(file: File): String? = withContext(Dispatchers.IO) {
        runCatching { PartialMd5.compute(file) }.getOrNull()
    }

    private fun targetForBook(book: Book?): KoreaderTarget? {
        val connectionId = ConnectionScope.getConnectionId() ?: book?.connectionId
        if (!connectionId.isNullOrBlank()) {
            val connection = connectionRegistry.getConnectionsSync().firstOrNull { it.id == connectionId }
                ?: return null
            return KoreaderTarget(connection.serverUrl.trimEnd('/'), connection.id)
        }

        val serverUrl = prefs.getServerUrlSync()?.trimEnd('/')?.takeIf { it.isNotBlank() }
            ?: return null
        return KoreaderTarget(serverUrl, prefs.getActiveConnectionIdSync())
    }

    private fun credentialsForTarget(target: KoreaderTarget): KoreaderCredentials? {
        val username = target.connectionId?.let { id ->
            vault.get(CredentialVault.kosyncUsernameKeyForConnection(id))
        } ?: vault.get(CredentialVault.kosyncUsernameKey(target.serverUrl))
            ?: return null
        val password = target.connectionId?.let { id ->
            vault.get(CredentialVault.kosyncPasswordKeyForConnection(id))
        } ?: vault.get(CredentialVault.kosyncPasswordKey(target.serverUrl))
            ?: return null
        if (username.isBlank() || password.isBlank()) return null
        return KoreaderCredentials(username = username, password = password, enabled = true)
    }

    companion object {
        fun koreaderUsernameKey(connectionId: String) = "koreader_username_$connectionId"
        fun koreaderPasswordKey(connectionId: String) = "koreader_password_$connectionId"
    }
}
