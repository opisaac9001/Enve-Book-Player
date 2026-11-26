package com.enve.app.data.backup

import android.content.Context
import android.net.ConnectivityManager
import android.net.Uri
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.app.data.readwise.ReadwiseExportService
import com.enve.app.data.sync.KOReaderHubService
import com.enve.engine.backup.PortableIntegrationPreview
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ConnectionAuthMode
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import com.enve.engine.backup.PortableBackupPreview
import com.enve.engine.backup.PortableRestoreResult
import com.enve.engine.backup.PortableSourcePreview
import com.enve.engine.backup.SettingsTransferFacade
import com.enve.engine.backup.SettingsTransferOffer
import com.enve.engine.backup.SettingsTransferReview
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import java.io.IOException
import java.net.URI
import java.util.Locale
import java.util.UUID
import javax.inject.Inject

class SettingsTransferFacadeImpl @Inject constructor(
    @ApplicationContext private val context: Context,
    private val settings: SettingsBackupFacadeImpl,
    private val registry: ConnectionRegistry,
    private val vault: CredentialVault,
    private val readwise: ReadwiseExportService,
    private val koReader: KOReaderHubService,
    private val locations: ProfileStorageLocations,
) : SettingsTransferFacade {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val restoreLock = Mutex()

    override suspend fun send(includeSettings: Boolean, includeSources: Boolean, includeIntegrations: Boolean, includeSignIns: Boolean): SettingsTransferOffer =
        withContext(Dispatchers.IO) {
            val network = context.getSystemService(ConnectivityManager::class.java)
            val address = network.getLinkProperties(network.activeNetwork)?.linkAddresses.orEmpty()
                .mapNotNull { it.address.hostAddress }.firstOrNull(SettingsTransferWire::isLocalAddress)
                ?: throw IOException("Connect both devices to the same Wi-Fi network.")
            SettingsTransferWire.offer(address, snapshot(includeSettings, includeSources, includeIntegrations, includeSignIns))
        }

    override suspend fun receive(code: String): SettingsTransferReview = review(SettingsTransferWire.receive(code))

    override suspend fun exportFile(
        uri: String,
        includeSettings: Boolean,
        includeSources: Boolean,
        includeIntegrations: Boolean,
        includeSignIns: Boolean,
        passphrase: String,
    ) = withContext(Dispatchers.IO) {
        require(passphrase.length >= 12)
        val bytes = SettingsTransferWire.seal(snapshot(includeSettings, includeSources, includeIntegrations, includeSignIns), passphrase)
        val stream = context.contentResolver.openOutputStream(Uri.parse(uri), "wt") ?: throw IOException("Could not save backup")
        stream.use { it.write(bytes) }
    }

    override suspend fun importFile(uri: String, passphrase: String): SettingsTransferReview = withContext(Dispatchers.IO) {
        val stream = context.contentResolver.openInputStream(Uri.parse(uri)) ?: throw IOException("Could not open backup")
        val bytes = stream.use {
            val result = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val count = it.read(buffer)
                if (count < 0) break
                require(result.size() + count <= SettingsTransferWire.maxBytes)
                result.write(buffer, 0, count)
            }
            result.toByteArray()
        }
        review(SettingsTransferWire.open(bytes, passphrase))
    }

    private suspend fun snapshot(includeSettings: Boolean, includeSources: Boolean, includeIntegrations: Boolean, includeSignIns: Boolean): ByteArray {
        val native = if (includeSettings) settings.portableSnapshot() else null
        val sources = if (includeSources) registry.connections.first().mapNotNull { source(it, includeSignIns) } else emptyList()
        checkOwner()
        val integrations = if (includeIntegrations) integrations(includeSignIns) else null
        require(native != null || sources.isNotEmpty() || integrations?.options()?.isNotEmpty() == true)
        val shared = native?.filterKeys { it in sharedSettingsKeys }?.toMutableMap()?.let {
            val theme = (it["themeMode"] as? JsonPrimitive)?.contentOrNull
            when (theme) {
                "INK" -> it["themeMode"] = JsonPrimitive("DARK")
                "PAPER" -> it["themeMode"] = JsonPrimitive("LIGHT")
            }
            JsonObject(it)
        }
        return json.encodeToString(Portable(sources = sources, sharedSettings = shared, androidSettings = native, integrations = integrations)).encodeToByteArray()
    }

    private fun source(connection: ProviderConnection, includeSignIns: Boolean): Source? {
        if (connection.source == BookSource.LOCAL || connection.source == BookSource.SMB) return null
        val endpoint = sanitizeAddress(connection.serverUrl) ?: return null
        val canShare = includeSignIns && connection.authMode != ConnectionAuthMode.SSO && !connection.mtlsEnabled
        val password = if (canShare) vault.get(CredentialVault.passwordKey(connection.id))?.takeIf(String::isNotEmpty) else null
        val apiKey = if (canShare && connection.authMode == ConnectionAuthMode.TOKEN && connection.source != BookSource.PLEX)
            vault.get(CredentialVault.accessTokenKey(connection.id))?.takeIf(String::isNotEmpty) else null
        val headers = if (canShare) connection.customHeaders.filterKeys { !it.equals("Cookie", true) }.toMutableMap() else mutableMapOf()
        if (canShare && connection.serviceClientId.isNotEmpty() && connection.serviceClientSecret.isNotEmpty()) {
            headers["CF-Access-Client-Id"] = connection.serviceClientId
            headers["CF-Access-Client-Secret"] = connection.serviceClientSecret
        }
        val portableId = runCatching { UUID.fromString(connection.id).toString() }.getOrElse { UUID.randomUUID().toString() }
        val anonymous = connection.source in basicSources && connection.authMode == ConnectionAuthMode.AUTO &&
            connection.username.isBlank() && connection.customHeaders.isEmpty() && connection.serviceClientId.isEmpty()
        return Source(
            portableId, connection.name, endpoint.toString(), connection.source.name.lowercase(Locale.ROOT),
            connection.username, !connection.enabled, connection.cloudRootPaths.firstOrNull(), connection.cloudRootPaths,
            wireAuth(connection.authMode), connection.mtlsEnabled, headers, headers.keys,
            password, apiKey, connection.mtlsEnabled || connection.authMode == ConnectionAuthMode.SSO ||
                (!anonymous && password == null && apiKey == null),
        )
    }

    private suspend fun review(payload: ByteArray): SettingsTransferReview {
        val backup = json.decodeFromString<Portable>(payload.decodeToString(throwOnInvalidSequence = true))
        require(backup.sources.map { it.id }.distinct().size == backup.sources.size)
        val selected = backup.sources.mapNotNull { source -> candidate(source)?.let { source.id to it } }.toMap()
        checkOwner()
        val native = backup.androidSettings ?: (backup.sharedSettings ?: iosPreferences(backup.settings))?.let(::forAndroid)
        val preview = native?.let { settings.inspectPortable(it) }
        val integrations = backup.integrations?.options().orEmpty()
        return object : SettingsTransferReview {
            override val preview = PortableBackupPreview(
                preview?.changes.orEmpty(),
                selected.map { (id, item) -> PortableSourcePreview(id, item.connection.name, item.connection.serverUrl, item.connection.needsReauth) },
                integrations,
            )

            override suspend fun restore(settings: Boolean, sourceIds: Set<String>, integrationIds: Set<String>): PortableRestoreResult =
                withContext(Dispatchers.IO + NonCancellable) {
                    restoreLock.withLock {
                        var restored = 0
                        var kept = 0
                        var signIns = 0
                        val known = registry.connections.first().mapTo(mutableSetOf(), ::identity)
                        for ((id, candidate) in selected) {
                            if (id !in sourceIds) continue
                            if (!known.add(identity(candidate.connection))) {
                                kept++
                                continue
                            }
                            val connection = candidate.connection.copy(id = UUID.randomUUID().toString())
                            val tokenKey = CredentialVault.accessTokenKey(connection.id)
                            val passwordKey = CredentialVault.passwordKey(connection.id)
                            val usernameKey = CredentialVault.usernameKey(connection.id)
                            try {
                                candidate.token?.let { vault.put(tokenKey, it) }
                                candidate.password?.let { vault.put(passwordKey, it) }
                                if (connection.username.isNotEmpty()) vault.put(usernameKey, connection.username)
                                registry.upsert(connection)
                            } catch (error: Exception) {
                                if (registry.connections.first().none { it.id == connection.id }) {
                                    vault.remove(tokenKey)
                                    vault.remove(passwordKey)
                                    vault.remove(usernameKey)
                                }
                                throw error
                            }
                            restored++
                            if (connection.needsReauth) signIns++
                        }
                        val saved = !settings || preview == null || this@SettingsTransferFacadeImpl.settings.apply(preview.backup)
                        val (integrationsRestored, reconnect) = restoreIntegrations(backup.integrations, integrationIds)
                        PortableRestoreResult(saved, restored, kept, signIns, integrationsRestored, reconnect)
                    }
                }
        }
    }

    private fun checkOwner() {
        check(locations.profileId == DEFAULT_ADULT_PROFILE_ID)
    }

    private fun integrations(includeSignIns: Boolean): Integrations {
        val hardcover = vault.get(CredentialVault.HARDCOVER_API_KEY)?.takeIf(String::isNotEmpty)
        val readwiseKey = readwise.backupToken()
        val config = koReader.config
        val ko = sanitizeAddress(config.baseUrl.orEmpty())?.let {
            KOReader(it.toString(), config.username, if (includeSignIns) config.passwordHash else "", config.autoSyncEnabled)
        }
        return Integrations(hardcover != null, hardcover.takeIf { includeSignIns },
            readwiseKey != null, readwiseKey.takeIf { includeSignIns }, ko)
    }

    private suspend fun restoreIntegrations(backup: Integrations?, selected: Set<String>): Pair<Int, List<String>> {
        if (backup == null) return 0 to emptyList()
        var restored = 0
        val reconnect = mutableListOf<String>()
        for (option in backup.options().filter { it.id in selected }) {
            when (option.id) {
                "hardcover" -> {
                    if (vault.get(CredentialVault.HARDCOVER_API_KEY)?.isNotEmpty() == true) continue
                    val key = backup.hardcoverKey?.takeIf(::validCredential)
                    if (key == null) reconnect.add(option.name)
                    else {
                        vault.put(CredentialVault.HARDCOVER_API_KEY, key)
                        restored++
                    }
                }
                "readwise" -> {
                    if (readwise.backupToken() != null) continue
                    val key = backup.readwiseKey?.takeIf(::validCredential)
                    if (key != null && readwise.restoreBackupToken(key)) restored++ else reconnect.add(option.name)
                }
                "koreader" -> {
                    if (koReader.config.serverUrl.isNotEmpty()) continue
                    val config = backup.koreader ?: continue
                    val address = sanitizeAddress(config.serverURL)
                    if (address == null) {
                        reconnect.add(option.name)
                        continue
                    }
                    val hash = config.passwordHash.takeIf { it.matches(Regex("[0-9a-fA-F]{32}")) }.orEmpty()
                    koReader.restoreBackupConfig(address.toString(), config.username, hash, config.autoSyncEnabled)
                    restored++
                    if (hash.isEmpty()) reconnect.add(option.name)
                }
            }
        }
        return restored to reconnect
    }

    private class Candidate(val connection: ProviderConnection, val password: String?, val token: String?)

    private fun candidate(source: Source): Candidate? {
        val provider = BookSource.entries.firstOrNull { it.name.equals(source.type, true) }
            ?.takeUnless { it == BookSource.LOCAL || it == BookSource.SMB } ?: return null
        val endpoint = sanitizeAddress(source.url) ?: return null
        val mode = ConnectionAuthMode.entries.firstOrNull { wireAuth(it) == source.authMode } ?: return null
        val canRestore = mode != ConnectionAuthMode.SSO && !source.mtlsEnabled
        val token = source.apiKey?.takeIf { canRestore && mode == ConnectionAuthMode.TOKEN && provider != BookSource.PLEX && validCredential(it) }
        val password = source.password?.takeIf { canRestore && validCredential(it) }
        val reauth = source.needsSignIn || source.mtlsEnabled || mode == ConnectionAuthMode.SSO ||
            (token == null && provider !in basicSources)
        val headers = if (canRestore) source.headers.orEmpty().filter {
            !it.key.equals("Cookie", true) && it.key.matches(headerName) && validCredential(it.value)
        } else emptyMap()
        return Candidate(
            ProviderConnection(
                id = source.id, source = provider, name = source.name, serverUrl = endpoint.toString(),
                username = source.username.orEmpty(), enabled = !source.isArchived, needsReauth = reauth,
                authMode = mode, urlScheme = if (endpoint.scheme == "http") UrlScheme.HTTP else UrlScheme.HTTPS,
                customHeaders = headers, mtlsEnabled = source.mtlsEnabled,
                cloudRootPaths = source.androidRootPaths.ifEmpty { listOfNotNull(source.rootPath) },
            ),
            password, token,
        )
    }

    private fun identity(connection: ProviderConnection) =
        listOf(connection.source.name, sanitizeAddress(connection.serverUrl)?.toString().orEmpty(), connection.username) +
            connection.cloudRootPaths

    private fun sanitizeAddress(raw: String): URI? = runCatching {
        val uri = URI(raw.trim())
        val scheme = uri.scheme.lowercase(Locale.ROOT)
        val host = uri.host.lowercase(Locale.ROOT)
        require(scheme == "http" || scheme == "https")
        val port = uri.port.takeUnless { (scheme == "http" && it == 80) || (scheme == "https" && it == 443) } ?: -1
        URI(scheme, null, host, port, uri.path.orEmpty().trimEnd('/'), null, null)
    }.getOrNull()

    private fun validCredential(value: String) = value.isNotEmpty() && value.length <= 8192 &&
        value.none { it == '\r' || it == '\n' || it == '\u0000' }

    private fun wireAuth(mode: ConnectionAuthMode) = when (mode) {
        ConnectionAuthMode.AUTO -> "auto"
        ConnectionAuthMode.USERNAME_PASSWORD -> "usernamePassword"
        ConnectionAuthMode.TOKEN -> "token"
        ConnectionAuthMode.SSO -> "sso"
    }

    private fun iosPreferences(document: JsonObject?): JsonObject? {
        val prefs = document?.get("preferences") as? JsonObject ?: return null
        val mapped = buildMap {
            (prefs["theme"] as? JsonPrimitive)?.contentOrNull?.uppercase(Locale.ROOT)
                ?.takeIf { it in setOf("SYSTEM", "LIGHT", "DARK") }?.let { put("themeMode", JsonPrimitive(it)) }
            (prefs["playbackSpeed"] as? JsonPrimitive)?.doubleOrNull?.let { put("defaultSpeed", JsonPrimitive(it)) }
            (prefs["skipForwardAmount"] as? JsonPrimitive)?.doubleOrNull?.toInt()?.let { put("skipForwardSeconds", JsonPrimitive(it)) }
            (prefs["skipBackwardAmount"] as? JsonPrimitive)?.doubleOrNull?.toInt()?.let { put("skipBackwardSeconds", JsonPrimitive(it)) }
            prefs["readingEnabled"]?.let { put("readingEnabled", it) }
        }
        return JsonObject(mapped)
    }

    private fun forAndroid(shared: JsonObject): JsonObject {
        val mapped = shared.toMutableMap()
        val theme = when ((mapped.remove("themeMode") as? JsonPrimitive)?.contentOrNull) {
            "LIGHT" -> "PAPER"
            "DARK" -> "INK"
            "SYSTEM" -> "SYSTEM"
            else -> null
        }
        if (theme != null) mapped["themeMode"] = JsonPrimitive(theme)
        for (key in listOf("skipForwardSeconds", "skipBackwardSeconds", "defaultSpeed")) {
            val value = (mapped[key] as? JsonPrimitive)?.doubleOrNull ?: continue
            val bounds = if (key == "defaultSpeed") 0.5..3.0 else 5.0..300.0
            if (value !in bounds) mapped.remove(key)
        }
        return JsonObject(mapped)
    }

    @Serializable
    private class Integrations(
        val hasHardcover: Boolean = false,
        val hardcoverKey: String? = null,
        val hasReadwise: Boolean = false,
        val readwiseKey: String? = null,
        val koreader: KOReader? = null,
    ) {
        fun options(): List<PortableIntegrationPreview> = buildList {
            if (hasHardcover) add(PortableIntegrationPreview("hardcover", "Hardcover", hardcoverKey.isNullOrEmpty()))
            if (hasReadwise) add(PortableIntegrationPreview("readwise", "Readwise", readwiseKey.isNullOrEmpty()))
            if (koreader != null) add(PortableIntegrationPreview("koreader", "KOReader sync", koreader.passwordHash.isEmpty()))
        }
    }

    @Serializable
    private class KOReader(val serverURL: String, val username: String, val passwordHash: String, val autoSyncEnabled: Boolean)

    @Serializable
    private class Portable(
        val sources: List<Source> = emptyList(),
        val sharedSettings: JsonObject? = null,
        val androidSettings: JsonObject? = null,
        val settings: JsonObject? = null,
        val integrations: Integrations? = null,
    )

    @Serializable
    private class Source(
        val id: String,
        val name: String,
        val url: String,
        val type: String,
        val username: String? = null,
        val isArchived: Boolean = false,
        val rootPath: String? = null,
        val androidRootPaths: List<String> = emptyList(),
        val authMode: String = "auto",
        val mtlsEnabled: Boolean = false,
        val headers: Map<String, String>? = null,
        val secretHeaderNames: Set<String> = emptySet(),
        val password: String? = null,
        val apiKey: String? = null,
        val needsSignIn: Boolean = true,
    )

    private companion object {
        val sharedSettingsKeys = setOf("themeMode", "defaultSpeed", "skipForwardSeconds", "skipBackwardSeconds", "readingEnabled", "accentHex")
        val basicSources = setOf(BookSource.OPDS, BookSource.WEBDAV)
        val headerName = Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+")
    }
}
