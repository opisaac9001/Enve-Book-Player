package com.enve.core.data.provider

import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ConnectionAuthMode
import com.enve.core.data.remote.security.PrivateNetworkTrust
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager

data class DetectedServer(
    val source: BookSource,
    val displayName: String,
    val normalizedUrl: String,
    val oidcEnabled: Boolean,
    val recommendedAuth: ConnectionAuthMode,
)

sealed interface ServerProbeOutcome {
    data class Identified(val server: DetectedServer) : ServerProbeOutcome
    data class OidcIssuerOnly(val normalizedUrl: String) : ServerProbeOutcome
    data class Unknown(val normalizedUrl: String) : ServerProbeOutcome
    data object Unreachable : ServerProbeOutcome
}

object ServerProbe {

    private val AUTO_SSO_SOURCES = setOf(
        BookSource.AUDIOBOOKSHELF, BookSource.GRIMMORY, BookSource.STORYTELLER,
    )

    suspend fun detect(rawUrl: String): ServerProbeOutcome {
        val bases = candidateBases(rawUrl)
        if (bases.isEmpty()) return ServerProbeOutcome.Unreachable

        var reachable: String? = null
        for (base in bases) {
            identify(base)?.let { return ServerProbeOutcome.Identified(it) }
            oidcIssuer(base)?.let { return ServerProbeOutcome.OidcIssuerOnly(it) }
            if (reachable == null && isReachable(base)) reachable = base
        }
        return reachable?.let { ServerProbeOutcome.Unknown(it) } ?: ServerProbeOutcome.Unreachable
    }

    private suspend fun identify(base: String): DetectedServer? = coroutineScope {

        val probes = listOf(
            async { fingerprintAudiobookshelf(base) },
            async { fingerprintGrimmory(base) },
            async { fingerprintBookOrbit(base) },
            async { fingerprintKomga(base) },
            async { fingerprintPlex(base) },
            async { fingerprintJellyfinEmby(base) },
            async { fingerprintStoryteller(base) },
            async { fingerprintSilo(base) },
            async { fingerprintKavita(base) },
            async { fingerprintOpds(base) },
        )
        probes.firstNotNullOfOrNull { it.await() }
    }

    private fun ssoOrPassword(source: BookSource, oidc: Boolean): ConnectionAuthMode =
        if (oidc && source in AUTO_SSO_SOURCES) ConnectionAuthMode.SSO else ConnectionAuthMode.USERNAME_PASSWORD

    private suspend fun fingerprintAudiobookshelf(base: String): DetectedServer? {
        val r = get(base, "/status") ?: return null
        if (r.code != 200) return null
        val json = r.body.toJsonObjectOrNull() ?: return null
        if (json.optString("app").lowercase() != "audiobookshelf") return null
        val methods = json.optJSONArray("authMethods")
        val oidc = (0 until (methods?.length() ?: 0)).any {
            methods!!.optString(it).lowercase().contains("openid")
        }
        return DetectedServer(BookSource.AUDIOBOOKSHELF, "Audiobookshelf", base, oidc,
            ssoOrPassword(BookSource.AUDIOBOOKSHELF, oidc))
    }

    private suspend fun fingerprintGrimmory(base: String): DetectedServer? {
        val r = get(base, "/api/v1/public-settings") ?: return null
        if (r.code != 200) return null
        val json = r.body.toJsonObjectOrNull() ?: return null
        if (!json.has("oidcEnabled")) return null
        val oidc = json.optBoolean("oidcEnabled")
        return DetectedServer(BookSource.GRIMMORY, "Grimmory", base, oidc,
            ssoOrPassword(BookSource.GRIMMORY, oidc))
    }

    private suspend fun fingerprintBookOrbit(base: String): DetectedServer? {
        val r = get(base, "/api/v1/app-settings/oidc/providers/public") ?: return null
        if (r.code != 200) return null
        val arr = r.body.toJsonArrayOrNull() ?: return null
        val oidc = arr.length() > 0
        return DetectedServer(BookSource.BOOKORBIT, "BookOrbit", base, oidc,
            ssoOrPassword(BookSource.BOOKORBIT, oidc))
    }

    private suspend fun fingerprintKomga(base: String): DetectedServer? {
        val r = get(base, "/api/v1/claim") ?: return null
        if (r.code != 200) return null
        val json = r.body.toJsonObjectOrNull() ?: return null
        if (!json.has("isClaimed")) return null
        return DetectedServer(BookSource.KOMGA, "Komga", base, komgaHasOidc(base),
            ConnectionAuthMode.USERNAME_PASSWORD)
    }

    private suspend fun komgaHasOidc(base: String): Boolean {
        val r = get(base, "/api/v1/oauth2/providers") ?: return false
        if (r.code != 200) return false
        r.body.toJsonArrayOrNull()?.let { return it.length() > 0 }
        r.body.toJsonObjectOrNull()?.let { return it.length() > 0 }
        return false
    }

    private suspend fun fingerprintPlex(base: String): DetectedServer? {
        val r = get(base, "/identity", accept = "application/json") ?: return null
        if (r.code != 200 || !r.body.lowercase().contains("machineidentifier")) return null
        return DetectedServer(BookSource.PLEX, "Plex", base, false, ConnectionAuthMode.USERNAME_PASSWORD)
    }

    private suspend fun fingerprintJellyfinEmby(base: String): DetectedServer? {
        val r = get(base, "/System/Info/Public") ?: return null
        if (r.code != 200) return null
        val product = r.body.toJsonObjectOrNull()?.optString("ProductName")?.lowercase()
            ?: r.body.lowercase()
        return when {
            product.contains("jellyfin") ->
                DetectedServer(BookSource.JELLYFIN, "Jellyfin", base, false, ConnectionAuthMode.USERNAME_PASSWORD)
            product.contains("emby") ->
                DetectedServer(BookSource.EMBY, "Emby", base, false, ConnectionAuthMode.USERNAME_PASSWORD)
            else -> null
        }
    }

    private suspend fun fingerprintStoryteller(base: String): DetectedServer? {

        val providers = get(base, "/api/v2/auth/providers")
        if (providers != null && providers.code == 200) {
            val obj = providers.body.toJsonObjectOrNull()
            if (obj != null && obj.has("credentials")) {
                val sso = obj.keys().asSequence().any { it.lowercase() != "credentials" }
                return DetectedServer(BookSource.STORYTELLER, "Storyteller", base, sso,
                    ssoOrPassword(BookSource.STORYTELLER, sso))
            }
        }
        val r = get(base, "/api") ?: return null
        if (r.code != 200) return null
        val lower = r.body.lowercase()
        if (!lower.contains("\"hello\"") && !lower.contains("storyteller")) return null
        return DetectedServer(BookSource.STORYTELLER, "Storyteller", base, false,
            ConnectionAuthMode.USERNAME_PASSWORD)
    }

    private suspend fun fingerprintSilo(base: String): DetectedServer? {

        val r = get(base, "/api/v1/health") ?: return null
        if (r.code != 200) return null
        val json = r.body.toJsonObjectOrNull() ?: return null
        if (json.optString("status") != "ok" || json.optString("server_id").isBlank()) return null
        return DetectedServer(BookSource.SILO, "Silo", base, false, ConnectionAuthMode.USERNAME_PASSWORD)
    }

    private suspend fun fingerprintKavita(base: String): DetectedServer? {
        val r = get(base, "/api/health") ?: return null
        if (r.code != 200) return null
        val trimmed = r.body.trim().lowercase()
        if (trimmed != "ok" && trimmed != "healthy") return null
        return DetectedServer(BookSource.KAVITA, "Kavita", base, false, ConnectionAuthMode.USERNAME_PASSWORD)
    }

    private suspend fun fingerprintOpds(base: String): DetectedServer? {
        val r = get(base, "") ?: return null
        if (r.code != 200) return null
        val contentType = (r.contentType ?: "").lowercase()
        val snippet = r.body.take(2048).lowercase()
        val isOpds = contentType.contains("atom+xml") || contentType.contains("opds") ||
            (snippet.contains("<feed") && snippet.contains("www.w3.org/2005/atom"))
        if (!isOpds) return null
        return DetectedServer(BookSource.OPDS, "OPDS", base, false, ConnectionAuthMode.USERNAME_PASSWORD)
    }

    private suspend fun oidcIssuer(base: String): String? {
        val r = get(base, "/.well-known/openid-configuration") ?: return null
        if (r.code != 200) return null
        val json = r.body.toJsonObjectOrNull() ?: return null
        if (!json.has("issuer") || !json.has("authorization_endpoint")) return null
        return base
    }

    private data class HttpResult(val code: Int, val body: String, val contentType: String?)

    private suspend fun isReachable(base: String): Boolean = get(base, "") != null

    private suspend fun get(base: String, path: String, accept: String? = null): HttpResult? =
        withContext(Dispatchers.IO) {
            val builder = runCatching { Request.Builder().url(base + path).get() }.getOrNull()
                ?: return@withContext null
            if (accept != null) builder.header("Accept", accept)
            try {
                client.newCall(builder.build()).execute().use { resp ->
                    HttpResult(resp.code, resp.body?.string().orEmpty(), resp.header("Content-Type"))
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
        }

    private fun candidateBases(raw: String): List<String> {
        val value = raw.trim().trimEnd('/')
        if (value.isEmpty()) return emptyList()
        val lower = value.lowercase()
        return if (lower.startsWith("http://") || lower.startsWith("https://")) listOf(value)
        else listOf("https://$value", "http://$value")
    }

    private fun String.toJsonObjectOrNull(): JSONObject? = runCatching { JSONObject(this) }.getOrNull()
    private fun String.toJsonArrayOrNull(): JSONArray? = runCatching { JSONArray(this) }.getOrNull()

    private val client: OkHttpClient by lazy {
        val trustManager = PrivateNetworkTrust.buildTrustManager()
        val sslContext = SSLContext.getInstance("TLS").apply {
            init(null, arrayOf<TrustManager>(trustManager), SecureRandom())
        }
        OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustManager)
            .hostnameVerifier(PrivateNetworkTrust.buildHostnameVerifier())
            .connectTimeout(6, TimeUnit.SECONDS)
            .readTimeout(6, TimeUnit.SECONDS)
            .build()
    }
}
