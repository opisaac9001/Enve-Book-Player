package com.enve.silo.auth

import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.di.RefreshClient
import com.enve.silo.dto.SiloCollection
import com.enve.silo.dto.SiloProfileDto
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.Json
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject
import javax.inject.Provider

data class SiloProfileChoice(val id: String, val pin: String)

class SiloProfileLogin @Inject constructor(
    @RefreshClient clientProvider: Provider<OkHttpClient>,
    private val vault: CredentialVault,
    private val connections: ConnectionRegistry,
) {
    private val client = clientProvider.get().newBuilder().followRedirects(false).build()
    private val json = Json { ignoreUnknownKeys = true }
    private val choices = MutableStateFlow<List<SiloProfileDto>>(emptyList())
    val state = choices.asStateFlow()
    private var selection: CompletableDeferred<SiloProfileChoice?>? = null

    fun choose(choice: SiloProfileChoice?) { selection?.complete(choice) }

    suspend fun prepare(serverUrl: String, headers: Map<String, String>, existingId: String?): String {
        val token = vault.get(CredentialVault.KEY_ACCESS_TOKEN)?.takeIf { it.isNotBlank() }
            ?: error("Sign in to Silo first.")
        val base = serverUrl.trimEnd('/')
        val account = json.decodeFromString<com.enve.silo.dto.SiloUserDto>(request(base + "/api/v2/account/me", token, headers))
        val profiles = json.decodeFromString<SiloCollection<SiloProfileDto>>(request(base + "/api/v2/profiles", token, headers)).items
        val existing = existingId?.let { id -> connections.getConnectionsSync().firstOrNull { it.id == id } }
        if (existing != null && existing.username != account.username) {
            error("Sign in to the same Silo account to preserve this connection’s downloads and progress.")
        }
        val savedId = existingId?.let { vault.get("silo_profile_id_$it") }
        val available = if (savedId == null) profiles else profiles.filter { it.id == savedId }
        if (available.isEmpty()) error("This Silo profile is unavailable. Add a separate connection for another profile.")
        val choice = if (available.size == 1 && !available.single().hasPin) {
            SiloProfileChoice(available.single().id, "")
        } else {
            val pending = CompletableDeferred<SiloProfileChoice?>()
            selection = pending
            choices.value = available
            try { pending.await() ?: error("Silo profile selection cancelled.") }
            finally { choices.value = emptyList(); selection = null }
        }
        val profile = available.firstOrNull { it.id == choice.id } ?: error("Select an available Silo profile.")
        val proof = if (profile.hasPin) {
            val body = json.encodeToString(PinRequest.serializer(), PinRequest(choice.pin))
            json.decodeFromString<PinResponse>(request(base.toHttpUrl().newBuilder().addPathSegments("api/v2/profiles").addPathSegment(profile.id).addPathSegment("verify-pin").build().toString(), token, headers, body))
                .also { if (!it.valid || it.profileToken.isNullOrBlank()) error("Incorrect Silo profile PIN.") }.profileToken
        } else null
        val connectionId = existingId ?: "${"SILO|$base|${account.username}".lowercase()}|${profile.id}"
        vault.put("silo_profile_id_$connectionId", profile.id)
        vault.put("silo_profile_user_id_$connectionId", account.username)
        vault.put("silo_profile_token_$connectionId", proof.orEmpty())
        return connectionId
    }

    private suspend fun request(url: String, token: String, headers: Map<String, String>, body: String? = null): String = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(url).apply {
            headers.forEach { (name, value) -> header(name, value) }
            removeHeader("X-Profile-Id")
            removeHeader("X-Profile-Token")
            header("Authorization", "Bearer $token")
            header("Accept", "application/json")
            if (body != null) post(body.toRequestBody("application/json".toMediaType()))
        }.build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) error("Silo profile request failed: HTTP ${response.code}")
            response.body?.string() ?: error("Silo returned no profiles.")
        }
    }

    @Serializable private data class PinRequest(val pin: String)
    @Serializable private data class PinResponse(val valid: Boolean, @SerialName("profile_token") val profileToken: String? = null)
}
