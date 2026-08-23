package com.enve.app.data.librarian

import android.content.Context
import com.enve.core.auth.CredentialVault
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.File
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
data class LibrarianRemoteServerSettings(
    val serverUrl: String = "",
    val model: String = "",
) {
    val normalizedBaseUrl: String get() = normalizeLlmBaseUrl(serverUrl)
    val isConfigured: Boolean get() = normalizedBaseUrl.isNotBlank() && model.isNotBlank()
}

@Singleton
class LibrarianRemoteServerStore @Inject constructor(
    @ApplicationContext context: Context,
    private val vault: CredentialVault,
) {
    private val file = File(context.filesDir, "enve-librarian/remote-server.json")
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    suspend fun load(): LibrarianRemoteServerSettings = withContext(Dispatchers.IO) {
        file.takeIf { it.isFile }
            ?.let { runCatching { json.decodeFromString(LibrarianRemoteServerSettings.serializer(), it.readText()) }.getOrNull() }
            ?: LibrarianRemoteServerSettings()
    }

    suspend fun save(settings: LibrarianRemoteServerSettings) = withContext(Dispatchers.IO) {
        file.parentFile?.mkdirs()
        file.writeText(json.encodeToString(LibrarianRemoteServerSettings.serializer(), settings))
    }

    fun apiKey(): String? = vault.get(API_KEY_VAULT_KEY)?.takeIf { it.isNotBlank() }

    fun saveApiKey(value: String?) {
        if (value.isNullOrBlank()) vault.remove(API_KEY_VAULT_KEY) else vault.put(API_KEY_VAULT_KEY, value)
    }

    private companion object {
        const val API_KEY_VAULT_KEY = "librarian_remote_api_key"
    }
}

@Singleton
class RemoteServerLibrarianEngine @Inject constructor(
    private val store: LibrarianRemoteServerStore,
) : LibrarianGenerationEngine {
    override val preference = LibrarianEnginePreference.REMOTE_SERVER
    override val title = "Local Server"

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(300, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    override suspend fun status(): LibrarianEngineStatus {
        val settings = store.load()
        return if (settings.isConfigured) {
            LibrarianEngineStatus(
                preference = preference,
                availability = LibrarianEngineAvailability.AVAILABLE,
                title = title,
                detail = "${settings.model} @ ${settings.normalizedBaseUrl}",
                isUsable = true,
            )
        } else {
            LibrarianEngineStatus(
                preference = preference,
                availability = LibrarianEngineAvailability.MODEL_MISSING,
                title = title,
                detail = "Add a server URL and model to use your own LLM server",
                isUsable = false,
            )
        }
    }

    override suspend fun answer(question: String, book: LibrarianBookRef, context: BookContextResult): LibrarianAnswer {
        val settings = store.load()
        if (!settings.isConfigured) throw EnveLibrarianException("Set up the local server in model settings first.")
        val request = ChatRequestDto(
            model = settings.model,
            messages = listOf(
                ChatMessageDto(role = "system", content = LIBRARIAN_SYSTEM_INSTRUCTION),
                ChatMessageDto(role = "user", content = buildRemotePrompt(question, book, context)),
            ),
        )
        val response = withContext(Dispatchers.IO) {
            execute(
                Request.Builder()
                    .url("${settings.normalizedBaseUrl}/chat/completions")
                    .post(json.encodeToString(ChatRequestDto.serializer(), request).toRequestBody(JSON_MEDIA_TYPE))
                    .authorized()
                    .build()
            ) { body -> json.decodeFromString(ChatResponseDto.serializer(), body) }
        }
        val text = response.choices.firstOrNull()?.message?.content?.trim().orEmpty()
        if (text.isBlank()) throw EnveLibrarianException("The local server did not return an answer.")
        return LibrarianAnswer(text = text, engineTitle = title)
    }

    suspend fun availableModels(): List<String> = withContext(Dispatchers.IO) {
        val settings = store.load()
        val base = settings.normalizedBaseUrl
        if (base.isBlank()) throw EnveLibrarianException("Enter a server URL first.")
        val response = execute(
            Request.Builder().url("$base/models").get().authorized().build()
        ) { body -> json.decodeFromString(ModelListDto.serializer(), body) }
        response.data.map { it.id }.filter { it.isNotBlank() }
    }

    private fun <T> execute(request: Request, parse: (String) -> T): T {
        val response = try {
            client.newCall(request).execute()
        } catch (e: Exception) {
            throw EnveLibrarianException("Could not reach the local server (${e.message ?: "connection failed"}).")
        }
        response.use {
            if (!it.isSuccessful) throw EnveLibrarianException("The local server returned HTTP ${it.code}.")
            val body = it.body?.string().orEmpty()
            return runCatching { parse(body) }
                .getOrElse { throw EnveLibrarianException("The local server returned an unexpected response.") }
        }
    }

    private fun Request.Builder.authorized(): Request.Builder = apply {
        store.apiKey()?.let { header("Authorization", "Bearer $it") }
    }

    @Serializable
    private data class ChatMessageDto(val role: String, val content: String)

    @Serializable
    private data class ChatRequestDto(
        val model: String,
        val messages: List<ChatMessageDto>,
        val temperature: Double = 0.2,
        @SerialName("max_tokens") val maxTokens: Int = 800,
        val stream: Boolean = false,

        @SerialName("reasoning_effort") val reasoningEffort: String = "none",
    )

    @Serializable
    private data class ChatResponseDto(val choices: List<Choice> = emptyList()) {
        @Serializable
        data class Choice(val message: Message? = null)

        @Serializable
        data class Message(val content: String? = null)
    }

    @Serializable
    private data class ModelListDto(val data: List<Entry> = emptyList()) {
        @Serializable
        data class Entry(val id: String = "")
    }

    private companion object {
        val JSON_MEDIA_TYPE = "application/json".toMediaType()
    }
}

private fun buildRemotePrompt(question: String, book: LibrarianBookRef, context: BookContextResult): String =
    """
    Book: ${book.title}
    Author: ${book.author.orEmpty()}
    Scope: ${context.scope.promptName}

    Relevant ebook context:
    ${context.text.replace(Regex("\\s+"), " ").trim().takeLast(REMOTE_PROMPT_CONTEXT_CHARS)}

    Question:
    $question
    """.trimIndent()

internal fun normalizeLlmBaseUrl(raw: String): String {
    var url = raw.trim()
    if (url.isBlank()) return ""
    if (!url.contains("://")) url = "http://$url"
    url = url.trimEnd('/')
    if (!url.endsWith("/v1")) url = "$url/v1"
    return url
}

private const val REMOTE_PROMPT_CONTEXT_CHARS = 24_000
