package com.enve.app.data.sync
import com.enve.core.data.sync.CfiLocatorConverter
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.remote.ConnectionScope
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BookloreKoreaderSink @Inject constructor(
    private val kosyncClient: KosyncClient,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
    private val deviceIdentity: DeviceIdentity,
    private val connectionRegistry: ConnectionRegistry,
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
        if (book.mediaType != AppMediaType.EBOOK) return Result.success(Unit)
        val target = targetForBook(book) ?: return Result.failure(Exception("No server URL"))
        val creds = credentialsForTarget(target) ?: return Result.success(Unit)

        val positionData = locatorJson?.let { json ->
            KOReaderXPointerConverter.xpointer(json) ?: CfiLocatorConverter.buildLocatorJson(
                CfiLocatorConverter.extractCfi(json) ?: return@let null
            )
        } ?: ""

        val localFile = runCatching {
            val downloads = android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOWNLOADS,
            )
            java.io.File(downloads, book.id)
        }.getOrNull()

        val hash = localFile?.takeIf { it.exists() }?.let {
            runCatching { PartialMd5.compute(it) }.getOrNull()
        } ?: return Result.success(Unit)

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
        if (book.mediaType != AppMediaType.EBOOK) return null
        val target = targetForBook(book) ?: return null
        val creds = credentialsForTarget(target) ?: return null

        val localFile = runCatching {
            val downloads = android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOWNLOADS,
            )
            java.io.File(downloads, book.id)
        }.getOrNull()

        val hash = localFile?.takeIf { it.exists() }?.let {
            runCatching { PartialMd5.compute(it) }.getOrNull()
        } ?: return null

        val response = kosyncClient.pullProgress(target.serverUrl, creds.username, creds.password, hash)
            .getOrNull() ?: return null

        val pct = response.percentage?.coerceIn(0f, 1f) ?: return null
        if (pct <= 0f) return null

        val locatorJson = response.positionData?.let { pos ->
            KOReaderXPointerConverter.locatorJson(pos, pct)
                ?: pos.takeIf { it.startsWith("epubcfi(") }
        }

        return SyncSnapshot(
            percentage = pct,
            locatorJson = locatorJson,
            source = response.device ?: "KOReader",
        )
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
