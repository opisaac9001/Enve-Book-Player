// AGENT-LOCKED
package com.enve.plex.auth

import com.enve.core.data.util.asObjectOrNull
import com.enve.core.data.util.optArray
import com.enve.core.data.util.optBoolean
import com.enve.core.data.util.optString
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Resolved Plex server discovered via plex.tv `/api/v2/resources` after a
 * successful PIN OAuth. The chosen `url` is the best reachable connection
 * (local > secure > relay-last).
 */
data class PlexResolvedServer(
    val url: String,
    val accessToken: String,
    val machineIdentifier: String? = null,
    val name: String? = null,
)

/**
 * plex.tv PIN OAuth + server discovery. Talks directly to plex.tv (not the
 * user's PMS) so it uses its own [OkHttpClient] without the app's
 * Authorization / DynamicUrl interceptors attached.
 *
 * Extracted from `GrimmoryRepository` — the PIN flow has no Grimmory
 * dependency and was just co-located by historical accident. The 5 call
 * sites live in `AuthViewModel`.
 */
@Singleton
class PlexPinAuthService @Inject constructor() {

    private val plexHttpClient: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(10, TimeUnit.SECONDS)
            .build()
    }

    private val jsonSerializer = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = true
    }

    suspend fun createPlexPin(clientId: String, appName: String): Result<Pair<Long, String>> =
        withContext(Dispatchers.IO) {
            try {
                val url = "https://plex.tv/api/v2/pins?" +
                    "strong=true" +
                    "&X-Plex-Product=${appName.replace(" ", "%20")}" +
                    "&X-Plex-Client-Identifier=$clientId"
                val request = Request.Builder()
                    .url(url)
                    .post("".toRequestBody("application/x-www-form-urlencoded".toMediaType()))
                    .header("Accept", "application/json")
                    .build()
                val response = plexHttpClient.newCall(request).execute()
                val body = response.body?.string()
                    ?: return@withContext Result.failure(Exception("Empty response from plex.tv"))
                val jsonElement = jsonSerializer.parseToJsonElement(body).jsonObject
                val pinId = jsonElement["id"]?.jsonPrimitive?.longOrNull
                    ?: return@withContext Result.failure(Exception("No PIN id in plex.tv response"))
                val pinCode = jsonElement["code"]?.jsonPrimitive?.contentOrNull
                    ?: return@withContext Result.failure(Exception("No PIN code in plex.tv response"))
                Result.success(Pair(pinId, pinCode))
            } catch (e: Exception) {
                Result.failure(e)
            }
        }

    suspend fun checkPlexPin(pinId: Long, code: String, clientId: String): Result<String?> =
        withContext(Dispatchers.IO) {
            try {
                val url = "https://plex.tv/api/v2/pins/$pinId?" +
                    "code=$code" +
                    "&X-Plex-Client-Identifier=$clientId"
                val request = Request.Builder()
                    .url(url)
                    .get()
                    .header("Accept", "application/json")
                    .build()
                val response = plexHttpClient.newCall(request).execute()
                val body = response.body?.string()
                    ?: return@withContext Result.success(null)
                val jsonElement = jsonSerializer.parseToJsonElement(body).jsonObject
                // authToken is null until the user completes login in the browser
                val authToken = jsonElement["authToken"]?.jsonPrimitive?.contentOrNull
                Result.success(authToken)
            } catch (e: Exception) {
                Result.failure(e)
            }
        }

    suspend fun resolvePlexServerForToken(
        userToken: String,
        clientId: String,
        appName: String,
    ): Result<PlexResolvedServer> = withContext(Dispatchers.IO) {
        try {
            val encodedAppName = appName.replace(" ", "%20")
            val url = "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1" +
                "&X-Plex-Product=$encodedAppName" +
                "&X-Plex-Client-Identifier=$clientId"

            val request = Request.Builder()
                .url(url)
                .get()
                .header("Accept", "application/json")
                .header("X-Plex-Token", userToken)
                .build()

            val response = plexHttpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                return@withContext Result.failure(Exception("Plex resources failed: ${response.code} ${response.message}"))
            }

            val body = response.body?.string()
                ?: return@withContext Result.failure(Exception("Empty Plex resources response"))

            // Same response-shape handling as resolveAllPlexServers — see the
            // comment there for the four variants plex.tv returns.
            val parsed = jsonSerializer.parseToJsonElement(body)
            val devices: JsonArray = when (parsed) {
                is JsonArray -> parsed
                is JsonObject -> when {
                    parsed["MediaContainer"] is JsonObject -> {
                        (parsed["MediaContainer"] as JsonObject).optArray("Device")
                            ?: (parsed["MediaContainer"] as JsonObject).optArray("devices")
                            ?: JsonArray(emptyList())
                    }
                    parsed["Device"] is JsonArray -> parsed.optArray("Device") ?: JsonArray(emptyList())
                    parsed["devices"] is JsonArray -> parsed.optArray("devices") ?: JsonArray(emptyList())
                    else -> JsonArray(emptyList())
                }
                else -> JsonArray(emptyList())
            }

            val serverDevices = devices.mapNotNull { it.asObjectOrNull() }
                .filter { dev ->
                    val provides = dev.optString("provides")?.lowercase().orEmpty()
                    provides.contains("server")
                }

            if (serverDevices.isEmpty()) {
                return@withContext Result.failure(Exception("No Plex servers found for this account"))
            }

            val candidates = serverDevices.flatMap { server ->
                val serverToken = server.optString("accessToken").takeUnless { it.isNullOrBlank() } ?: userToken
                val machineId = server.optString("clientIdentifier")
                val name = server.optString("name")
                val connections = server.optArray("connections")
                    ?: server.optArray("Connection")
                    ?: server.optArray("Connections")
                    ?: JsonArray(emptyList())
                connections.mapNotNull { connEl ->
                    val conn = connEl.asObjectOrNull() ?: return@mapNotNull null
                    val uri = conn.optString("uri") ?: return@mapNotNull null
                    val local = conn.optBoolean("local") ?: false
                    val relay = conn.optBoolean("relay") ?: false
                    val secure = uri.startsWith("https://", ignoreCase = true)
                    PlexCandidate(
                        url = uri.trimEnd('/'),
                        local = local,
                        secure = secure,
                        relay = relay,
                        token = serverToken,
                        machineId = machineId,
                        name = name,
                    )
                }
            }

            if (candidates.isEmpty()) {
                return@withContext Result.failure(Exception("No Plex server connections found"))
            }

            val sorted = candidates.sortedWith(
                // Remote HTTPS first, then local HTTPS, then HTTP variants,
                // relay last. See resolveAllPlexServers for the rationale.
                compareByDescending<PlexCandidate> { it.secure }
                    .thenBy { it.local }
                    .thenBy { it.relay }
            )

            val best = sorted.firstOrNull {
                isPlexConnectionReachable(
                    baseUrl = it.url,
                    token = it.token,
                    clientId = clientId,
                    appName = appName,
                )
            } ?: sorted.first()

            Result.success(
                PlexResolvedServer(
                    url = best.url,
                    accessToken = best.token,
                    machineIdentifier = best.machineId,
                    name = best.name,
                )
            )
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    /**
     * Discovers every Plex server the user has access to (including shared
     * servers) and returns one [PlexResolvedServer] per server, with the URL
     * already resolved through the local > secure > relay-last fallback chain.
     *
     * Used after PIN OAuth when the user opted to register every server as
     * its own ConnectionRegistry entry.
     */
    suspend fun resolveAllPlexServers(
        userToken: String,
        clientId: String,
        appName: String,
    ): Result<List<PlexResolvedServer>> = withContext(Dispatchers.IO) {
        try {
            val encodedAppName = appName.replace(" ", "%20")
            val url = "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1" +
                "&X-Plex-Product=$encodedAppName" +
                "&X-Plex-Client-Identifier=$clientId"
            val request = Request.Builder()
                .url(url)
                .get()
                .header("Accept", "application/json")
                .header("X-Plex-Token", userToken)
                .build()
            val response = plexHttpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                return@withContext Result.failure(Exception("Plex resources failed: ${response.code}"))
            }
            val body = response.body?.string()
                ?: return@withContext Result.failure(Exception("Empty Plex resources response"))
            // plex.tv/api/v2/resources returns ONE OF:
            //   - bare JSON array: [{...server...}, {...server...}]  (modern)
            //   - {"MediaContainer": {"Device": [...]}} (XML-mirror)
            //   - {"MediaContainer": {"devices": [...]}}
            //   - {"Device": [...]} | {"devices": [...]} (no container)
            // The modern response is what observed real accounts get (logcat
            // confirmed devices=0 with a body that started with `[{`).
            val parsed = jsonSerializer.parseToJsonElement(body)
            val devices: JsonArray = when (parsed) {
                is JsonArray -> parsed
                is JsonObject -> when {
                    parsed["MediaContainer"] is JsonObject -> {
                        (parsed["MediaContainer"] as JsonObject).optArray("Device")
                            ?: (parsed["MediaContainer"] as JsonObject).optArray("devices")
                            ?: JsonArray(emptyList())
                    }
                    parsed["Device"] is JsonArray -> parsed.optArray("Device") ?: JsonArray(emptyList())
                    parsed["devices"] is JsonArray -> parsed.optArray("devices") ?: JsonArray(emptyList())
                    else -> JsonArray(emptyList())
                }
                else -> JsonArray(emptyList())
            }
            val resolved = devices.mapNotNull { it.asObjectOrNull() }
                .filter { (it.optString("provides") ?: "").lowercase().contains("server") }
                .mapNotNull { server ->
                    val serverToken = server.optString("accessToken").takeUnless { it.isNullOrBlank() } ?: userToken
                    val machineId = server.optString("clientIdentifier")
                    val name = server.optString("name")
                    // plex.tv returns the connections array under one of three keys
                    // depending on the response shape (modern lowercase, XML-mirror
                    // PascalCase, or the singular variant). Check all three so we
                    // don't drop the device just because we picked the wrong case.
                    val connections = server.optArray("connections")
                        ?: server.optArray("Connection")
                        ?: server.optArray("Connections")
                        ?: JsonArray(emptyList())
                    if (connections.isEmpty()) {
                        android.util.Log.w(
                            "PlexPinAuth",
                            "Server '${name ?: machineId ?: "?"}' returned no connections; keys=${server.keys}",
                        )
                    }
                    val candidates = connections.mapNotNull { connEl ->
                        val conn = connEl.asObjectOrNull() ?: return@mapNotNull null
                        val uri = conn.optString("uri") ?: return@mapNotNull null
                        PlexCandidate(
                            url = uri.trimEnd('/'),
                            local = conn.optBoolean("local") ?: false,
                            secure = uri.startsWith("https://", ignoreCase = true),
                            relay = conn.optBoolean("relay") ?: false,
                            token = serverToken,
                            machineId = machineId,
                            name = name,
                        )
                    }.sortedWith(
                        // Mirror iOS PlexService.findBestConnection ordering:
                        // remote HTTPS → local HTTPS → remote HTTP → local HTTP →
                        // relay. Remote first because LAN URLs are unreachable
                        // when the phone isn't on the server's network and we
                        // can't know that ahead of time. The reachability probe
                        // below still gets to override.
                        compareByDescending<PlexCandidate> { it.secure }
                            .thenBy { it.local }
                            .thenBy { it.relay }
                    )
                    android.util.Log.i(
                        "PlexPinAuth",
                        "Server '$name' candidates: ${candidates.map { "${it.url} (local=${it.local} relay=${it.relay})" }}",
                    )
                    val best = candidates.firstOrNull {
                        val reachable = isPlexConnectionReachable(it.url, it.token, clientId, appName)
                        android.util.Log.i("PlexPinAuth", "  probe ${it.url} → reachable=$reachable")
                        reachable
                    }
                    if (best == null) {
                        android.util.Log.w(
                            "PlexPinAuth",
                            "Server '$name' has ${candidates.size} candidate(s) but none are reachable from this device — dropping.",
                        )
                        null
                    } else {
                        PlexResolvedServer(
                            url = best.url,
                            accessToken = best.token,
                            machineIdentifier = best.machineId,
                            name = best.name,
                        )
                    }
                }
            if (resolved.isEmpty()) {
                android.util.Log.w(
                    "PlexPinAuth",
                    "resolveAllPlexServers: 0 servers; devices=${devices.size}, body head: ${body.take(400)}",
                )
            } else {
                android.util.Log.i(
                    "PlexPinAuth",
                    "resolveAllPlexServers: found ${resolved.size} server(s): ${resolved.map { it.url }}",
                )
            }
            Result.success(resolved)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    // ── Plex Home users ──────────────────────────────────────────────────────

    /**
     * Plex Home: a shared account where multiple users live under one owner.
     * Each user can have their own listening history, watched/finished state,
     * and (optionally) a 4-digit PIN. The owner's auth token can enumerate the
     * Home users; switching to one returns a user-scoped token that should be
     * stored in CredentialVault as that connection's access token.
     */
    suspend fun getHomeUsers(ownerToken: String, clientId: String): Result<List<PlexHomeUser>> =
        withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder()
                    .url("https://plex.tv/api/v2/home/users?X-Plex-Client-Identifier=$clientId")
                    .get()
                    .header("Accept", "application/json")
                    .header("X-Plex-Token", ownerToken)
                    .build()
                val response = plexHttpClient.newCall(request).execute()
                if (!response.isSuccessful) {
                    return@withContext Result.failure(Exception("Plex home users HTTP ${response.code}"))
                }
                val body = response.body?.string() ?: return@withContext Result.success(emptyList())
                val root = jsonSerializer.parseToJsonElement(body).jsonObject
                val users = root["users"] as? JsonArray
                    ?: (root["MediaContainer"] as? JsonObject)?.optArray("User")
                    ?: JsonArray(emptyList())
                val parsed = users.mapNotNull { el ->
                    val obj = el.asObjectOrNull() ?: return@mapNotNull null
                    val id = obj.optString("id")?.toLongOrNull() ?: return@mapNotNull null
                    PlexHomeUser(
                        id = id,
                        uuid = obj.optString("uuid"),
                        title = obj.optString("title") ?: obj.optString("username") ?: "User",
                        username = obj.optString("username"),
                        email = obj.optString("email"),
                        admin = obj.optBoolean("admin") ?: false,
                        restricted = obj.optBoolean("restricted") ?: false,
                        protected = obj.optBoolean("protected") ?: false,
                        guest = obj.optBoolean("guest") ?: false,
                        thumb = obj.optString("thumb"),
                    )
                }
                Result.success(parsed)
            } catch (e: Exception) {
                Result.failure(e)
            }
        }

    /**
     * Switches the Plex auth to a different Home user. Returns a token scoped
     * to that user — caller persists it in CredentialVault for the connection.
     * A 4-digit PIN is required only for users with `protected = true`.
     */
    suspend fun switchHomeUser(
        ownerToken: String,
        clientId: String,
        userId: Long,
        pin: String? = null,
    ): Result<String> = withContext(Dispatchers.IO) {
        try {
            val pinSuffix = pin?.takeUnless { it.isBlank() }?.let { "&pin=$it" }.orEmpty()
            val url = "https://plex.tv/api/home/users/$userId/switch?X-Plex-Client-Identifier=$clientId$pinSuffix"
            val request = Request.Builder()
                .url(url)
                .post("".toRequestBody("application/x-www-form-urlencoded".toMediaType()))
                .header("Accept", "application/json")
                .header("X-Plex-Token", ownerToken)
                .build()
            val response = plexHttpClient.newCall(request).execute()
            if (!response.isSuccessful) {
                return@withContext Result.failure(Exception("Plex switch HTTP ${response.code}"))
            }
            val body = response.body?.string()
                ?: return@withContext Result.failure(Exception("Empty switch response"))
            val token = parseSwitchUserToken(body)
                ?: return@withContext Result.failure(Exception("No authToken in switch response"))
            Result.success(token)
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun parseSwitchUserToken(body: String): String? {
        // Switch endpoint returns either JSON (modern) or XML (legacy). Try
        // JSON first since we set Accept: application/json.
        return runCatching {
            val obj = jsonSerializer.parseToJsonElement(body).jsonObject
            obj.optString("authToken")
                ?: (obj["user"] as? JsonObject)?.optString("authToken")
        }.getOrNull() ?: run {
            // XML fallback. We only need the authToken attribute on <user>.
            Regex("""authToken="([^"]+)"""").find(body)?.groupValues?.getOrNull(1)
        }
    }

    private fun isPlexConnectionReachable(
        baseUrl: String,
        token: String,
        clientId: String,
        appName: String,
    ): Boolean {
        return runCatching {
            val url = "${baseUrl.trimEnd('/')}/identity"
            val request = Request.Builder()
                .url(url)
                .get()
                .header("Accept", "application/xml")
                .header("X-Plex-Token", token)
                .header("X-Plex-Product", appName)
                .header("X-Plex-Client-Identifier", clientId)
                .header("X-Plex-Device", "Android")
                .header("X-Plex-Platform", "Android")
                .header("X-Plex-Platform-Version", android.os.Build.VERSION.RELEASE ?: "")
                .header("X-Plex-Version", "1.0")
                .build()

            plexHttpClient.newBuilder()
                .connectTimeout(4, TimeUnit.SECONDS)
                .readTimeout(4, TimeUnit.SECONDS)
                .build()
                .newCall(request)
                .execute()
                .use { resp ->
                    resp.isSuccessful
                }
        }.getOrDefault(false)
    }
}

private data class PlexCandidate(
    val url: String,
    val local: Boolean,
    val secure: Boolean,
    val relay: Boolean,
    val token: String,
    val machineId: String?,
    val name: String?,
)

/**
 * A Plex Home user. `protected = true` means a PIN is required to switch.
 * `admin = true` is the account owner.
 */
data class PlexHomeUser(
    val id: Long,
    val uuid: String? = null,
    val title: String,
    val username: String? = null,
    val email: String? = null,
    val admin: Boolean = false,
    val restricted: Boolean = false,
    val protected: Boolean = false,
    val guest: Boolean = false,
    val thumb: String? = null,
)
