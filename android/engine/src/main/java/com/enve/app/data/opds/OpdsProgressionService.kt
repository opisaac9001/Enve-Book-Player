package com.enve.app.data.opds

import com.enve.app.data.repository.isHttpUrl
import com.enve.app.data.repository.opdsOrigin
import com.enve.app.data.sync.DeviceIdentity
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.sync.SyncSnapshot
import com.enve.core.data.util.reachesFinishedThreshold
import com.enve.core.data.util.stringLiteralOrNull
import com.enve.core.reader.EpubBridgeCheckpointCodec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.roundToLong

sealed interface OpdsProgressionPushResult {
    data object Written : OpdsProgressionPushResult

    data object Skipped : OpdsProgressionPushResult

    data object Superseded : OpdsProgressionPushResult

    data class Failed(val reason: String) : OpdsProgressionPushResult
}

class OpdsProgressionSupersededException :
    IllegalStateException("OPDS progression service holds a newer position")

data class OpdsProgressionAuthenticationPrompt(
    val connectionId: String,
    val bookId: String,
    val bookTitle: String,
    val authenticateUrl: String,
)

enum class OpdsProgressionTransport { SCOPED, PRIVATE_NETWORK, PUBLIC_NETWORK }

data class OpdsProgressionEndpoint(val url: String, val transport: OpdsProgressionTransport)

internal fun opdsProgressionEndpoint(url: String, serverUrl: String): OpdsProgressionEndpoint? {
    if (!isHttpUrl(url) || !isUriReference(url)) return null
    val parsed = url.toHttpUrlOrNull() ?: return null
    if (parsed.encodedUsername.isNotEmpty() || parsed.encodedPassword.isNotEmpty()) return null
    val origin = opdsOrigin(url) ?: return null
    val transport = when {
        origin == opdsOrigin(serverUrl) -> OpdsProgressionTransport.SCOPED
        isPrivateNetworkHost(parsed.host) -> OpdsProgressionTransport.PRIVATE_NETWORK
        else -> OpdsProgressionTransport.PUBLIC_NETWORK
    }
    return OpdsProgressionEndpoint(url = url, transport = transport)
}

internal fun isPrivateNetworkHost(host: String): Boolean {
    val normalized = host.trim().removeSurrounding("[", "]").lowercase()
    if (normalized.isEmpty()) return false
    if (normalized == "localhost") return true
    privateIpv4Octets(normalized)?.let { return isPrivateIpv4(it) }
    if (normalized.contains(':')) return isPrivateIpv6(normalized)
    if (!normalized.contains('.')) return true
    return PRIVATE_SUFFIXES.any { normalized.endsWith(it) }
}

private fun privateIpv4Octets(host: String): List<Int>? {
    val parts = host.split('.')
    if (parts.size != 4) return null
    return parts.map { it.toIntOrNull()?.takeIf { value -> value in 0..255 } ?: return null }
}

private fun isPrivateIpv4(octets: List<Int>): Boolean = when {
    octets[0] == 10 || octets[0] == 127 -> true
    octets[0] == 172 && octets[1] in 16..31 -> true
    octets[0] == 192 && octets[1] == 168 -> true
    octets[0] == 169 && octets[1] == 254 -> true
    octets[0] == 100 && octets[1] in 64..127 -> true
    else -> false
}

private fun isPrivateIpv6(host: String): Boolean {
    if (host == "::1") return true
    val leading = host.substringBefore(':').takeIf { it.isNotEmpty() }?.toIntOrNull(16) ?: return false
    if (leading and 0xFE00 == 0xFC00) return true
    return leading and 0xFFC0 == 0xFE80
}

private val PRIVATE_SUFFIXES = listOf(".local", ".lan", ".home", ".internal", ".localdomain")

@Singleton
class OpdsProgressionService @Inject constructor(
    private val client: OpdsProgressionClient,
    private val bookCache: BookCacheDao,
    private val connectionRegistry: ConnectionRegistry,
    private val deviceIdentity: DeviceIdentity,
    private val state: OpdsProgressionStateStore,
) {
    private val _authenticationPrompt = MutableStateFlow<OpdsProgressionAuthenticationPrompt?>(null)
    val authenticationPrompt: StateFlow<OpdsProgressionAuthenticationPrompt?> =
        _authenticationPrompt.asStateFlow()

    fun dismissAuthenticationPrompt() {
        _authenticationPrompt.value = null
    }

    suspend fun fetch(book: Book): SyncSnapshot? {
        val service = resolve(book) ?: return null
        return when (val response = client.fetch(service.endpoint)) {
            is OpdsProgressionResponse.Document -> {
                state.save(
                    connectionId = service.connectionId,
                    bookId = book.id,
                    references = response.document.unhandledReferences,
                    additionalMembers = response.document.additionalMembers,
                )
                response.document.toSnapshot(book)
            }

            OpdsProgressionResponse.Empty -> {
                state.save(service.connectionId, book.id, emptyList(), JsonObject(emptyMap()))
                null
            }

            OpdsProgressionResponse.Unauthorized -> {
                promptForAuthentication(service.connectionId, book)
                null
            }

            else -> null
        }
    }

    suspend fun push(
        book: Book,
        percentage: Float,
        currentTimeSec: Long?,
        locatorJson: String?,
        page: Int?,
    ): OpdsProgressionPushResult {
        val service = resolve(book) ?: return OpdsProgressionPushResult.Skipped
        val anchor = readOpdsLocalAnchor(locatorJson)
        val carryover = state.carryover(service.connectionId, book.id)
        val document = OpdsProgressionDocument.at(
            modifiedAtMs = System.currentTimeMillis(),
            device = OpdsProgressionDevice(
                id = deviceIdentity.deviceUri,
                name = deviceIdentity.deviceName,
            ),
            progression = percentage.toDouble(),
            title = anchor.title,
            references = mergeProgressionReferences(
                generated = opdsProgressionReferences(book.mediaType, currentTimeSec, anchor, page),
                carried = carryover.references,
            ),
            additionalMembers = carryover.additionalMembers,
        )
        return when (val response = client.update(service.endpoint, document)) {
            is OpdsProgressionResponse.Document -> {
                state.save(
                    connectionId = service.connectionId,
                    bookId = book.id,
                    references = response.document.unhandledReferences,
                    additionalMembers = response.document.additionalMembers,
                )
                OpdsProgressionPushResult.Written
            }

            is OpdsProgressionResponse.Conflict -> OpdsProgressionPushResult.Superseded
            OpdsProgressionResponse.Unauthorized -> {
                promptForAuthentication(service.connectionId, book)
                OpdsProgressionPushResult.Failed("unauthorized")
            }
            OpdsProgressionResponse.Empty -> OpdsProgressionPushResult.Failed("no progression document")
            is OpdsProgressionResponse.Failure -> OpdsProgressionPushResult.Failed(
                response.problem?.type ?: "HTTP ${response.status}",
            )
        }
    }

    private suspend fun promptForAuthentication(connectionId: String, book: Book) {
        val url = state.authenticateUrl(connectionId, book.id) ?: return
        _authenticationPrompt.value = OpdsProgressionAuthenticationPrompt(
            connectionId = connectionId,
            bookId = book.id,
            bookTitle = book.title,
            authenticateUrl = url,
        )
    }

    private suspend fun resolve(book: Book): ResolvedProgressionService? {
        val connectionId = ConnectionScope.getConnectionId() ?: book.connectionId ?: return null
        val url = book.opdsProgressionUrl
            ?: bookCache.getByIdAndConnection(book.id, connectionId)?.opdsProgressionUrl
            ?: return null
        val serverUrl = connectionRegistry.connections.first()
            .firstOrNull { it.id == connectionId }
            ?.serverUrl
            ?: return null
        val endpoint = opdsProgressionEndpoint(url, serverUrl) ?: return null
        return ResolvedProgressionService(connectionId, endpoint)
    }

    private data class ResolvedProgressionService(
        val connectionId: String,
        val endpoint: OpdsProgressionEndpoint,
    )
}

internal fun OpdsProgressionDocument.toSnapshot(book: Book): SyncSnapshot {
    val derivedPositionMs = (book.duration * 1000.0 * progression)
        .roundToLong()
        .takeIf { book.duration > 0L && book.mediaType != AppMediaType.EBOOK }
    return SyncSnapshot(
        percentage = progression.toFloat().coerceIn(0f, 1f),
        positionMs = timeSeconds?.let { (it * 1000.0).roundToLong() } ?: derivedPositionMs,
        locatorJson = progressionLocatorJson(),
        epubCfi = epubCfi?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi),
        href = resourcePath,
        source = BookSource.OPDS.displayName,
        updatedAt = modifiedAtMs,
        finished = progression.reachesFinishedThreshold(),
    )
}

internal fun OpdsProgressionDocument.progressionLocatorJson(): String? {
    val cfi = epubCfi?.takeIf(EpubBridgeCheckpointCodec::isFullEpubCfi)
    val resource = resourcePath
    val fragment = fragmentId
    val quote = textQuote
    val page = pdfPage
    if (cfi == null && resource == null && fragment == null && quote == null && page == null) return null
    return buildJsonObject {
        put("href", resource.orEmpty())
        put("type", "application/xhtml+xml")
        page?.let { put("page", it) }
        put(
            "locations",
            buildJsonObject {
                put("totalProgression", progression)
                cfi?.let { put("cfi", it) }
                fragment?.let { put("fragments", JsonArray(listOf(JsonPrimitive(it)))) }
            },
        )
        quote?.let { text -> put("text", buildJsonObject { put("highlight", text) }) }
    }.toString()
}

internal fun opdsProgressionReferences(
    mediaType: AppMediaType,
    currentTimeSec: Long?,
    anchor: OpdsLocalAnchor,
    page: Int?,
): List<OpdsProgressionReference> = buildList {
    if (mediaType != AppMediaType.EBOOK && currentTimeSec != null && currentTimeSec > 0L) {
        add(OpdsProgressionReferences.time(currentTimeSec.toDouble()))
    }
    when {
        anchor.quote != null -> add(OpdsProgressionReferences.text(anchor.resource, anchor.quote))
        anchor.fragmentId != null -> add(OpdsProgressionReferences.id(anchor.resource, anchor.fragmentId))
        anchor.resource != null -> add(OpdsProgressionReferences.resource(anchor.resource))
    }
    (page ?: anchor.page)?.takeIf { it > 0 }?.let { add(OpdsProgressionReferences.page(it)) }
    anchor.cfi?.let { add(OpdsProgressionReferences.cfi(anchor.resource, it)) }
}

internal data class OpdsLocalAnchor(
    val resource: String? = null,
    val cfi: String? = null,
    val quote: String? = null,
    val fragmentId: String? = null,
    val page: Int? = null,
    val title: String? = null,
)

internal fun readOpdsLocalAnchor(locatorJson: String?): OpdsLocalAnchor {
    val raw = locatorJson?.trim()?.takeIf { it.startsWith("{") } ?: return OpdsLocalAnchor()
    val cfi = EpubBridgeCheckpointCodec.cfi(raw)
    EpubBridgeCheckpointCodec.decode(raw)?.let { checkpoint ->
        return OpdsLocalAnchor(
            resource = checkpoint.href?.takeIf { it.isNotBlank() },
            cfi = cfi,
            quote = checkpoint.textQuote?.exact?.takeIf { it.isNotBlank() },
        )
    }
    val root = runCatching { anchorJson.parseToJsonElement(raw) as? JsonObject }.getOrNull()
        ?: return OpdsLocalAnchor(cfi = cfi)
    val locations = root["locations"] as? JsonObject
    return OpdsLocalAnchor(
        resource = root["href"].stringLiteralOrNull()?.takeIf { it.isNotBlank() },
        cfi = cfi,
        quote = (root["text"] as? JsonObject)?.get("highlight").stringLiteralOrNull()?.takeIf { it.isNotBlank() },
        fragmentId = (locations?.get("fragments") as? JsonArray)
            ?.firstNotNullOfOrNull { it.stringLiteralOrNull() }
            ?.takeIf { !it.startsWith("epubcfi(") },
        page = (root["page"] as? JsonPrimitive)?.takeIf { !it.isString }?.content?.toIntOrNull(),
        title = root["title"].stringLiteralOrNull()?.takeIf { it.isNotBlank() },
    )
}

private val anchorJson = Json { ignoreUnknownKeys = true; isLenient = true }
