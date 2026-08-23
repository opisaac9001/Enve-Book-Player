package com.enve.storyteller

import android.util.Log
import com.enve.storyteller.api.StorytellerApi
import com.enve.storyteller.dto.StorytellerAlignmentFacetsDto
import com.enve.storyteller.dto.StorytellerAlignmentReportDto
import com.enve.storyteller.dto.StorytellerBookDto
import com.enve.storyteller.dto.StorytellerReadaloudDto
import com.enve.storyteller.dto.StorytellerShelfDto
import kotlinx.coroutines.CancellationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import retrofit2.Response
import javax.inject.Inject
import javax.inject.Singleton

enum class StorytellerProcessRestart(val value: String) {
    FULL("full"),
    TRANSCRIPTION("transcription"),
    SYNC("sync"),
}

@Singleton
class StorytellerHubRepository @Inject constructor(
    private val api: StorytellerApi,
) {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
    }

    suspend fun getShelves(): Result<List<StorytellerShelfDto>> = hubResult {
        val response = api.getShelves()
        if (!response.isSuccessful) error(hubError("Storyteller shelves", response))
        val decoded = decodeLenientStorytellerArray<StorytellerShelfDto>(
            json = json,
            payload = response.body()?.string()?.takeIf { it.isNotBlank() } ?: "[]",
        )
        if (decoded.skippedCount > 0) {
            Log.w(TAG, "Storyteller shelves skipped ${decoded.skippedCount} malformed record(s)")
        }
        decoded.values.filter { it.uuid.isNotBlank() }
    }

    suspend fun createShelf(name: String, description: String?): Result<Unit> = hubResult {
        val response = api.createShelf(storytellerShelfBody(name, description).asJsonRequestBody())
        if (!response.isSuccessful) error(hubError("Storyteller shelf create", response))
    }

    suspend fun updateShelf(shelf: StorytellerShelfDto, name: String): Result<Unit> = hubResult {
        val body = storytellerShelfBody(
            name = name,
            description = shelf.description,
            icon = shelf.icon,
            color = shelf.color,
        )
        val response = api.updateShelf(shelf.uuid, body.asJsonRequestBody())
        if (!response.isSuccessful) error(hubError("Storyteller shelf update", response))
    }

    suspend fun deleteShelf(uuid: String): Result<Unit> = hubResult {
        val response = api.deleteShelf(uuid)
        if (!response.isSuccessful) error(hubError("Storyteller shelf delete", response))
    }

    suspend fun updateShelfBooks(uuid: String, bookIds: List<String>): Result<Unit> = hubResult {
        val response = api.updateShelf(uuid, storytellerShelfBooksBody(bookIds).asJsonRequestBody())
        if (!response.isSuccessful) error(hubError("Storyteller shelf books update", response))
    }

    suspend fun getAlignmentFacets(): Result<StorytellerAlignmentFacetsDto> = hubResult {
        val response = api.getAlignmentFacets()
        if (!response.isSuccessful) error(hubError("Storyteller alignment facets", response))
        response.body() ?: error("Storyteller alignment facets response was empty")
    }

    suspend fun getAlignmentReport(bookId: String): Result<StorytellerAlignmentReportDto> = hubResult {
        val response = api.getAlignmentReport(bookId)
        if (!response.isSuccessful) error(hubError("Storyteller alignment report", response))
        response.body() ?: error("Storyteller alignment report response was empty")
    }

    suspend fun getBooks(): Result<List<StorytellerBookDto>> = hubResult {
        val response = api.getBooks()
        if (!response.isSuccessful) error(hubError("Storyteller books", response))
        val decoded = decodeLenientStorytellerArray<StorytellerBookDto>(
            json = json,
            payload = response.body()?.string()?.takeIf { it.isNotBlank() } ?: "[]",
        )
        if (decoded.skippedCount > 0) {
            Log.w(TAG, "Storyteller books skipped ${decoded.skippedCount} malformed record(s)")
        }
        decoded.values.filter { it.uuid.isNotBlank() }
    }

    suspend fun startProcessing(bookId: String, restart: StorytellerProcessRestart?): Result<Unit> = hubResult {
        val response = api.startProcessing(bookId, restart?.value, "{}".toRequestBody(JSON_MEDIA_TYPE))
        if (!response.isSuccessful) {
            error(hubError("Storyteller processing request", response))
        }
    }

    suspend fun cancelProcessing(bookId: String): Result<Unit> = hubResult {
        val response = api.cancelProcessing(bookId)
        if (!response.isSuccessful) {
            error(hubError("Storyteller processing cancel", response))
        }
    }

    private suspend fun <T> hubResult(block: suspend () -> T): Result<T> = try {
        Result.success(block())
    } catch (error: CancellationException) {
        throw error
    } catch (error: Exception) {
        Result.failure(error)
    }

    private fun hubError(prefix: String, response: Response<*>): String {
        val parts = mutableListOf("$prefix failed: HTTP ${response.code()}")
        when (response.code()) {
            403 -> parts += "your account is missing the required permission"
            404 -> parts += "the server does not offer this endpoint"
            409 -> parts += "the server rejected the request in its current state"
        }
        response.errorBody()?.string()?.let { raw ->
            runCatching { json.parseToJsonElement(raw).jsonObject["message"]?.jsonPrimitive?.content }
                .getOrNull()
                ?.trim()
                ?.takeIf { it.isNotBlank() }
                ?.let { parts += it }
        }
        return parts.joinToString(" · ")
    }

    private fun JsonObject.asJsonRequestBody(): RequestBody = toString().toRequestBody(JSON_MEDIA_TYPE)

    companion object {
        private const val TAG = "StorytellerHub"
        private val JSON_MEDIA_TYPE = "application/json".toMediaType()
    }
}

internal fun storytellerShelfBody(
    name: String,
    description: String? = null,
    icon: String? = null,
    color: String? = null,
): JsonObject {
    val fields = buildMap {
        put("name", JsonPrimitive(name))
        description?.takeIf { it.isNotBlank() }?.let { put("description", JsonPrimitive(it)) }
        icon?.takeIf { it.isNotBlank() }?.let { put("icon", JsonPrimitive(it)) }
        color?.takeIf { it.isNotBlank() }?.let { put("color", JsonPrimitive(it)) }
    }
    return JsonObject(fields)
}

internal fun storytellerShelfBooksBody(bookIds: List<String>): JsonObject = JsonObject(
    mapOf("books" to JsonArray(bookIds.map(::JsonPrimitive))),
)

fun storytellerProcessCandidates(books: List<StorytellerBookDto>): List<StorytellerBookDto> =
    books.filter { book ->
        book.uuid.isNotBlank() &&
            book.ebook != null && (book.ebook.missing ?: 0) == 0 &&
            book.audiobook != null && (book.audiobook.missing ?: 0) == 0
    }.sortedWith(
        compareByDescending<StorytellerBookDto> { storytellerProcessingActive(it.readaloud) }
            .thenBy { it.title.lowercase() },
    )

fun storytellerProcessingActive(readaloud: StorytellerReadaloudDto?): Boolean {
    val status = readaloud?.status?.uppercase() ?: return false
    return status == "PROCESSING" || status == "QUEUED"
}
