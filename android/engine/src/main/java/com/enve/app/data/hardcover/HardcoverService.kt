package com.enve.app.data.hardcover

import com.enve.core.auth.CredentialVault
import com.enve.core.data.util.optArray
import com.enve.core.data.util.optBoolean
import com.enve.core.data.util.optDouble
import com.enve.core.data.util.optInt
import com.enve.core.data.util.optObject
import com.enve.core.data.util.optString
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.security.MessageDigest
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Calendar
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

data class HardcoverProfile(
    val id: Int,
    val username: String,
)

data class HardcoverBookResult(
    val id: Int,
    val title: String,
    val author: String?,
    val coverUrl: String?,
    val releaseYear: Int?,
    val usersCount: Int? = null,
    val authorNames: List<String> = emptyList(),
)

data class HardcoverLibraryBook(
    val id: Int,
    val bookId: Int,
    val title: String,
    val author: String?,
    val coverUrl: String?,
    val statusId: Int,
    val rating: Double?,
    val progress: Float,
) {
    val statusLabel: String = hardcoverStatusLabel(statusId)
}

data class HardcoverUserList(
    val id: Int,
    val name: String,
    val description: String?,
    val booksCount: Int,
    val likesCount: Int?,
)

data class HardcoverActivity(
    val id: Int,
    val action: String,
    val createdAt: String,
    val bookTitle: String?,
    val author: String?,
    val coverUrl: String?,
)

data class HardcoverReadingGoal(
    val year: Int,
    val target: Int,
    val current: Int,
) {
    val progress: Float = if (target > 0) current.toFloat() / target.toFloat() else 0f
}

data class HardcoverHubData(
    val profile: HardcoverProfile,
    val library: List<HardcoverLibraryBook>,
    val lists: List<HardcoverUserList>,
    val activity: List<HardcoverActivity>,
    val readingGoal: HardcoverReadingGoal?,
    val listsError: String? = null,
    val activityError: String? = null,
    val goalError: String? = null,
)

data class HardcoverEdition(
    val id: Int,
    val pages: Int?,
    val audioSeconds: Int?,
)

data class HardcoverRead(
    val id: Int,
    val finishedAt: String?,
    val progressPages: Int?,
    val progressSeconds: Int?,
    val edition: HardcoverEdition?,
    val startedAt: String? = null,
)

data class HardcoverUserBookState(
    val id: Int,
    val statusId: Int,
    val edition: HardcoverEdition?,
    val reads: List<HardcoverRead>,
) {
    val activeRead: HardcoverRead? get() = reads.firstOrNull()?.takeIf { it.finishedAt == null }
}

data class HardcoverBookState(
    val userBook: HardcoverUserBookState?,
    val defaultAudioEdition: HardcoverEdition?,
    val defaultEbookEdition: HardcoverEdition?,
    val defaultPhysicalEdition: HardcoverEdition?,
    val selectedEdition: HardcoverEdition? = null,
)

class HardcoverSession internal constructor(internal val token: String, val userId: Int) {
    val accountKey: String = hardcoverAccountKey(token)
}

open class HardcoverException(message: String) : Exception(message)

open class HardcoverTransientException(message: String, val retryAfterMs: Long? = null) : HardcoverException(message)

class HardcoverRateLimitedException(retryAfterMs: Long) : HardcoverTransientException(
    "Hardcover is rate limiting requests. Try again in ${hardcoverWaitText(retryAfterMs)}.",
    retryAfterMs,
)

class HardcoverAccountChangedException : HardcoverException("The Hardcover account changed.")

class HardcoverMatchRequiredException(message: String) : HardcoverException(message)

internal fun hardcoverWaitText(ms: Long): String {
    val seconds = (ms + 999) / 1_000
    return when {
        seconds < 90 -> "$seconds seconds"
        seconds < 90 * 60 -> "${(seconds + 59) / 60} minutes"
        else -> "${(seconds + 3_599) / 3_600} hours"
    }
}

internal fun hardcoverAccountKey(token: String): String =
    MessageDigest.getInstance("SHA-256").digest(token.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

internal fun hardcoverDate(epochMs: Long, zone: ZoneId = ZoneId.systemDefault()): String =
    Instant.ofEpochMilli(epochMs).atZone(zone).toLocalDate().toString()

internal fun hardcoverTimestamp(epochMs: Long, zone: ZoneId = ZoneId.systemDefault()): String =
    Instant.ofEpochMilli(epochMs).atZone(zone).toOffsetDateTime().format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

internal fun hardcoverHttpError(status: Int, body: String, retryAfterMs: Long? = null): HardcoverException {
    val code = runCatching { Json.parseToJsonElement(body).jsonObject.optString("error") }.getOrDefault("").orEmpty()
    val capacity = body.contains("request_exceeds_capacity")
    val message = when {
        status == 401 -> "Hardcover token is invalid or expired."
        status == 403 && code == "insufficient_scope" -> "This Hardcover token needs additional permissions for this section."
        status == 403 && capacity -> "This Hardcover request exceeds the account's burst capacity."
        status == 403 && code == "unsupported_operation" -> "Hardcover does not allow this operation for API tokens."
        status == 403 -> "Hardcover denied access to this section."
        status == 429 -> "Hardcover is rate limiting requests. Try again shortly."
        status == 408 -> "Hardcover timed out. Retrying later."
        status >= 500 -> "Hardcover is temporarily unavailable (HTTP $status)."
        else -> "Hardcover returned HTTP $status."
    }
    return if (status == 408 || status == 429 || status >= 500) HardcoverTransientException(message, retryAfterMs)
    else HardcoverException(message)
}

internal fun hardcoverInvalidTokenMessage(message: String): Boolean =
    listOf("invalid_token", "invalid api key", "jwtexpired", "invalid-jwt", "unable to verify token")
        .any { message.contains(it, ignoreCase = true) }

internal fun normalizedHardcoverToken(raw: String): String =
    raw.trim().replaceFirst(Regex("^bearer\\s+", RegexOption.IGNORE_CASE), "").trim()

internal fun hardcoverMutationResult(data: JsonObject, field: String): JsonObject {
    val result = data.optObject(field) ?: throw HardcoverException("Hardcover did not return a result for $field.")
    result.optString("error")?.takeIf { it.isNotBlank() }?.let { throw HardcoverException(it) }
    result.optArray("errors")
        ?.mapNotNull { (it as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank) }
        ?.takeIf { it.isNotEmpty() }
        ?.let { throw HardcoverException(it.joinToString("; ")) }
    if ((result.optInt("id") ?: 0) <= 0) throw HardcoverException("Hardcover did not confirm the change.")
    return result
}

internal fun hardcoverReadProgress(read: JsonObject?, fallbackEdition: JsonObject?): Float {
    if (read?.optString("finished_at") != null) return 1f
    val edition = read?.optObject("edition") ?: fallbackEdition
    val seconds = read?.optInt("progress_seconds")
    val audioSeconds = edition?.optInt("audio_seconds")
    if (seconds != null && audioSeconds != null && audioSeconds > 0) {
        return (seconds.toFloat() / audioSeconds).coerceIn(0f, 1f)
    }
    val pages = read?.optInt("progress_pages")
    val totalPages = edition?.optInt("pages")
    if (pages != null && totalPages != null && totalPages > 0) {
        return (pages.toFloat() / totalPages).coerceIn(0f, 1f)
    }
    return 0f
}

internal fun hardcoverAnnualBookGoal(goals: JsonArray, year: Int): JsonObject? =
    goals.mapNotNull { it as? JsonObject }.firstOrNull { goal ->
        goal.optString("metric") == "book" &&
            goal.optBoolean("archived") != true &&
            goal.optString("start_date") == "$year-01-01" &&
            goal.optString("end_date") == "$year-12-31"
    }

private val goalConditionKeys = setOf("authorBipoc", "authorGenderIds", "authorLgbtqia", "bookCategoryIds", "readingFormatId")

internal fun hardcoverGoalInput(existing: JsonObject?, target: Int, year: Int): JsonObject {
    val conditions = existing?.optObject("conditions") ?: JsonObject(emptyMap())
    if (conditions.keys.any { it !in goalConditionKeys }) {
        throw HardcoverException("This goal has conditions Enve can't preserve. Edit it on Hardcover.")
    }
    return buildJsonObject {
        put("goal", target)
        put("metric", "book")
        put("description", existing?.optString("description") ?: "$year Reading Goal")
        put("start_date", "$year-01-01")
        put("end_date", "$year-12-31")
        put("conditions", JsonObject(conditions.filterValues { it !is JsonNull }))
        existing?.optInt("privacy_setting_id")?.let { put("privacy_setting_id", it) }
        existing?.optBoolean("archived")?.let { put("archived", it) }
    }
}

@Serializable
private data class HardcoverSearchResultsDto(val hits: List<HardcoverSearchHitDto>)

@Serializable
private data class HardcoverSearchHitDto(val document: HardcoverBookDocumentDto)

@Serializable
private data class HardcoverBookDocumentDto(
    val id: String,
    val title: String,
    @SerialName("author_names") val authorNames: List<String> = emptyList(),
    val image: HardcoverImageDto? = null,
    @SerialName("release_year") val releaseYear: Int? = null,
)

@Serializable
private data class HardcoverImageDto(val url: String? = null)

private val hardcoverSearchJson = Json { ignoreUnknownKeys = true }

internal fun hardcoverBookSearchResults(results: JsonElement): List<HardcoverBookResult> =
    hardcoverSearchJson.decodeFromJsonElement<HardcoverSearchResultsDto>(results).hits.map { hit ->
        val document = hit.document
        HardcoverBookResult(
            id = document.id.toInt(),
            title = document.title,
            author = document.authorNames.takeIf { it.isNotEmpty() }?.joinToString(", "),
            coverUrl = document.image?.url,
            releaseYear = document.releaseYear,
            authorNames = document.authorNames,
        )
    }

internal fun hardcoverIdentifiedEditions(editions: List<JsonElement>): List<HardcoverIdentifiedEdition> =
    editions.mapNotNull { element ->
        val row = element as? JsonObject ?: return@mapNotNull null
        HardcoverIdentifiedEdition(
            edition = HardcoverEdition(
                id = row.optInt("id") ?: return@mapNotNull null,
                pages = row.optInt("pages"),
                audioSeconds = row.optInt("audio_seconds"),
            ),
            bookId = row.optInt("book_id") ?: return@mapNotNull null,
            bookTitle = row.optObject("book")?.optString("title").orEmpty(),
            isbn10 = row.optString("isbn_10"),
            isbn13 = row.optString("isbn_13"),
            asin = row.optString("asin"),
        )
    }

@Singleton
class HardcoverService @Inject constructor(
    @RefreshClient private val client: OkHttpClient,
    private val vault: CredentialVault,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val pacers = ConcurrentHashMap<String, HardcoverRequestPacer>()

    @Volatile private var session: HardcoverSession? = null

    fun hasToken(): Boolean = activeToken() != null

    fun activeAccountKey(): String? = activeToken()?.let(::hardcoverAccountKey)

    fun clearToken() {
        session = null
        vault.remove(CredentialVault.HARDCOVER_API_KEY)
    }

    suspend fun saveToken(token: String): HardcoverProfile {
        val normalized = normalizedHardcoverToken(token)
        if (normalized.isBlank()) throw HardcoverException("Paste a Hardcover API token.")
        val profile = getCurrentUser(normalized, requireActive = false)
        currentCoroutineContext().ensureActive()
        vault.put(CredentialVault.HARDCOVER_API_KEY, normalized)
        session = HardcoverSession(normalized, profile.id)
        return profile
    }

    suspend fun currentSession(): HardcoverSession? {
        val token = activeToken() ?: return null
        session?.takeIf { it.token == token }?.let { return it }
        val profile = getCurrentUser(token)
        return HardcoverSession(token, profile.id).also { if (activeToken() == token) session = it }
    }

    suspend fun loadHubData(): HardcoverHubData {
        val token = requireActiveToken()
        val profile = getCurrentUser(token)
        val userId = profile.id
        val year = Calendar.getInstance().get(Calendar.YEAR)

        val library = getUserBooks(token, limit = 50)
        var listsError: String? = null
        val lists = try { getUserLists(token, userId) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: HardcoverAccountChangedException) { throw e } catch (e: Exception) {
            listsError = e.message
            emptyList()
        }
        var activityError: String? = null
        val activity = try { getActivityFeed(token, userId, profile.username, limit = 10) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: HardcoverAccountChangedException) { throw e } catch (e: Exception) {
            activityError = e.message
            emptyList()
        }
        var goalError: String? = null
        val goal = try { getReadingGoal(token, year) } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (e: HardcoverAccountChangedException) { throw e } catch (e: Exception) {
            goalError = e.message
            null
        }

        return HardcoverHubData(profile, library, lists, activity, goal, listsError, activityError, goalError)
    }

    suspend fun searchBooks(query: String, limit: Int = 20, session: HardcoverSession? = null): List<HardcoverBookResult> {
        val trimmed = query.trim()
        if (trimmed.isBlank()) return emptyList()
        val data = performQuery(
            """
            query HardcoverSearch(${'$'}query: String!, ${'$'}perPage: Int!) {
                search(query: ${'$'}query, query_type: "Book", per_page: ${'$'}perPage, page: 1) {
                    results
                }
            }
            """.trimIndent(),
            session?.token ?: requireActiveToken(),
            buildJsonObject {
                put("query", trimmed)
                put("perPage", limit)
            },
        )
        val results = data.optObject("search")?.get("results") ?: return emptyList()
        return hardcoverBookSearchResults(results)
    }

    suspend fun addBookToLibrary(bookId: Int, startReading: Boolean = false): Int {
        val session = currentSession() ?: throw HardcoverException("Connect Hardcover first.")
        val existing = bookState(session, bookId).userBook
        if (existing != null) {
            if (startReading && existing.statusId != 2) updateUserBookStatus(session, existing.id, 2)
            return existing.id
        }
        return insertUserBook(session.token, bookId, statusId = if (startReading) 2 else 1, editionId = null, occurredAt = null)
    }

    suspend fun setReadingGoal(target: Int) {
        if (target <= 0) throw HardcoverException("Goal must be greater than zero.")
        val token = requireActiveToken()
        val year = Calendar.getInstance().get(Calendar.YEAR)
        val existing = annualGoal(token, year)
        val input = hardcoverGoalInput(existing, target, year)
        val existingId = existing?.optInt("id")
        if (existingId != null) {
            val data = performQuery(
                """
                mutation HardcoverUpdateGoal(${'$'}id: Int!, ${'$'}object: GoalInput!) {
                    update_goal(id: ${'$'}id, object: ${'$'}object) { id errors }
                }
                """.trimIndent(),
                token,
                buildJsonObject {
                    put("id", existingId)
                    put("object", input)
                },
            )
            hardcoverMutationResult(data, "update_goal")
        } else {
            val data = performQuery(
                """
                mutation HardcoverInsertGoal(${'$'}object: GoalInput!) {
                    insert_goal(object: ${'$'}object) { id errors }
                }
                """.trimIndent(),
                token,
                buildJsonObject { put("object", input) },
            )
            hardcoverMutationResult(data, "insert_goal")
        }
    }

    suspend fun editionsByIdentifiers(session: HardcoverSession, identifiers: HardcoverIdentifiers): List<HardcoverIdentifiedEdition> {
        if (identifiers.isEmpty) return emptyList()
        val data = performQuery(
            """
            query HardcoverEditionsByIdentifier(${'$'}isbn10: [String!]!, ${'$'}isbn13: [String!]!, ${'$'}asin: [String!]!) {
                editions(
                    where: {_or: [{isbn_10: {_in: ${'$'}isbn10}}, {isbn_13: {_in: ${'$'}isbn13}}, {asin: {_in: ${'$'}asin}}]},
                    limit: 20
                ) {
                    id book_id isbn_10 isbn_13 asin pages audio_seconds
                    book { title }
                }
            }
            """.trimIndent(),
            session.token,
            buildJsonObject {
                put("isbn10", JsonArray(listOfNotNull(identifiers.isbn10).map { JsonPrimitive(it) }))
                put("isbn13", JsonArray(listOfNotNull(identifiers.isbn13).map { JsonPrimitive(it) }))
                put("asin", JsonArray(listOfNotNull(identifiers.asin).map { JsonPrimitive(it) }))
            },
        )
        return hardcoverIdentifiedEditions(data.optArray("editions").orEmpty())
    }

    suspend fun bookState(session: HardcoverSession, bookId: Int, editionId: Int? = null): HardcoverBookState {
        val editionVariable = if (editionId != null) ", ${'$'}editionId: Int!" else ""
        val selectedEdition = if (editionId != null) "selected_edition: editions_by_pk(id: ${'$'}editionId) { id pages audio_seconds }" else ""
        val data = performQuery(
            """
            query HardcoverBookState(${'$'}bookId: Int!$editionVariable) {
                me {
                    user_books(where: {book_id: {_eq: ${'$'}bookId}}, limit: 1) {
                        id status_id
                        edition { id pages audio_seconds }
                        user_book_reads(order_by: {id: desc}) {
                            id started_at finished_at progress_pages progress_seconds
                            edition { id pages audio_seconds }
                        }
                    }
                }
                books_by_pk(id: ${'$'}bookId) {
                    default_audio_edition { id pages audio_seconds }
                    default_ebook_edition { id pages audio_seconds }
                    default_physical_edition { id pages audio_seconds }
                }
                $selectedEdition
            }
            """.trimIndent(),
            session.token,
            buildJsonObject {
                put("bookId", bookId)
                editionId?.let { put("editionId", it) }
            },
        )
        val row = data.optArray("me")?.firstOrNull()?.jsonObject?.optArray("user_books")?.firstOrNull()?.jsonObject
        val userBook = row?.let {
            HardcoverUserBookState(
                id = it.optInt("id") ?: throw HardcoverException("Hardcover library row id missing."),
                statusId = it.optInt("status_id") ?: 0,
                edition = it.optObject("edition").toEdition(),
                reads = it.optArray("user_book_reads").orEmpty().mapNotNull { element ->
                    val read = element.jsonObject
                    HardcoverRead(
                        id = read.optInt("id") ?: return@mapNotNull null,
                        finishedAt = read.optString("finished_at"),
                        progressPages = read.optInt("progress_pages"),
                        progressSeconds = read.optInt("progress_seconds"),
                        edition = read.optObject("edition").toEdition(),
                        startedAt = read.optString("started_at"),
                    )
                },
            )
        }
        val book = data.optObject("books_by_pk")
        return HardcoverBookState(
            userBook = userBook,
            defaultAudioEdition = book?.optObject("default_audio_edition").toEdition(),
            defaultEbookEdition = book?.optObject("default_ebook_edition").toEdition(),
            defaultPhysicalEdition = book?.optObject("default_physical_edition").toEdition(),
            selectedEdition = data.optObject("selected_edition").toEdition(),
        )
    }

    suspend fun insertUserBook(session: HardcoverSession, bookId: Int, statusId: Int, editionId: Int?, occurredAt: Long): Int =
        insertUserBook(session.token, bookId, statusId, editionId, occurredAt)

    suspend fun updateUserBookStatus(session: HardcoverSession, userBookId: Int, statusId: Int, occurredAt: Long? = null) {
        val data = performQuery(
            """
            mutation HardcoverUpdateUserBook(${'$'}id: Int!, ${'$'}object: UserBookUpdateInput!) {
                update_user_book(id: ${'$'}id, object: ${'$'}object) { id error }
            }
            """.trimIndent(),
            session.token,
            buildJsonObject {
                put("id", userBookId)
                put("object", buildJsonObject {
                    put("status_id", statusId)
                    occurredAt?.let {
                        put("action_at", hardcoverTimestamp(it))
                        put("user_date", hardcoverDate(it))
                    }
                })
            },
        )
        hardcoverMutationResult(data, "update_user_book")
    }

    suspend fun insertUserBookRead(session: HardcoverSession, userBookId: Int, editionId: Int?, occurredAt: Long) {
        val data = performQuery(
            """
            mutation HardcoverInsertRead(${'$'}userBookId: Int!, ${'$'}read: DatesReadInput!) {
                insert_user_book_read(user_book_id: ${'$'}userBookId, user_book_read: ${'$'}read) { id error }
            }
            """.trimIndent(),
            session.token,
            buildJsonObject {
                put("userBookId", userBookId)
                put("read", buildJsonObject {
                    put("started_at", hardcoverDate(occurredAt))
                    put("action_at", hardcoverTimestamp(occurredAt))
                    editionId?.let { put("edition_id", it) }
                })
            },
        )
        hardcoverMutationResult(data, "insert_user_book_read")
    }

    suspend fun updateReadProgress(
        session: HardcoverSession,
        readId: Int,
        editionId: Int,
        progressPages: Int?,
        progressSeconds: Int?,
        occurredAt: Long,
        startedAt: String?,
    ) {
        val data = performQuery(
            """
            mutation HardcoverUpdateRead(${'$'}id: Int!, ${'$'}object: DatesReadInput!) {
                update_user_book_read(id: ${'$'}id, object: ${'$'}object) { id error }
            }
            """.trimIndent(),
            session.token,
            buildJsonObject {
                put("id", readId)
                put("object", buildJsonObject {
                    put("edition_id", editionId)
                    progressPages?.let { put("progress_pages", it) }
                    progressSeconds?.let { put("progress_seconds", it) }
                    put("action_at", hardcoverTimestamp(occurredAt))
                    startedAt?.let { put("started_at", it) }
                })
            },
        )
        hardcoverMutationResult(data, "update_user_book_read")
    }

    suspend fun updateReadFinishedDate(session: HardcoverSession, readId: Int, finishedAt: String, occurredAt: Long) {
        val data = performQuery(
            """
            mutation HardcoverUpdateReadFinish(${'$'}id: Int!, ${'$'}object: DatesReadInput!) {
                update_user_book_read(id: ${'$'}id, object: ${'$'}object) { id error }
            }
            """.trimIndent(),
            session.token,
            buildJsonObject {
                put("id", readId)
                put("object", buildJsonObject {
                    put("finished_at", finishedAt)
                    put("action_at", hardcoverTimestamp(occurredAt))
                })
            },
        )
        hardcoverMutationResult(data, "update_user_book_read")
    }

    private fun activeToken(): String? = vault.get(CredentialVault.HARDCOVER_API_KEY)?.takeIf { it.isNotBlank() }

    private fun requireActiveToken(): String =
        activeToken() ?: throw HardcoverException("Connect Hardcover with an API token first.")

    private suspend fun insertUserBook(token: String, bookId: Int, statusId: Int, editionId: Int?, occurredAt: Long?): Int {
        val data = performQuery(
            """
            mutation HardcoverInsertUserBook(${'$'}object: UserBookCreateInput!) {
                insert_user_book(object: ${'$'}object) { id error }
            }
            """.trimIndent(),
            token,
            buildJsonObject {
                put("object", buildJsonObject {
                    put("book_id", bookId)
                    put("status_id", statusId)
                    put("date_added", hardcoverDate(occurredAt ?: System.currentTimeMillis()))
                    occurredAt?.let {
                        put("action_at", hardcoverTimestamp(it))
                        put("user_date", hardcoverDate(it))
                    }
                    editionId?.let { put("edition_id", it) }
                })
            },
        )
        return hardcoverMutationResult(data, "insert_user_book").optInt("id")
            ?: throw HardcoverException("Hardcover did not return a library row.")
    }

    private suspend fun getCurrentUser(token: String, requireActive: Boolean = true): HardcoverProfile {
        val data = performQuery("""query { me { id username } }""", token, requireActive = requireActive)
        val user = data.optArray("me")?.firstOrNull()?.jsonObject
            ?: throw HardcoverException("Hardcover account not found.")
        return HardcoverProfile(
            id = user.optInt("id") ?: throw HardcoverException("Hardcover account id missing."),
            username = user.optString("username").orEmpty(),
        )
    }

    private suspend fun getUserBooks(token: String, limit: Int): List<HardcoverLibraryBook> {
        val data = performQuery(
            """
            query {
                me {
                    user_books(
                        limit: $limit,
                        order_by: {updated_at: desc},
                        where: {status_id: {_is_null: false}}
                    ) {
                        id book_id rating status_id edition_id
                        book {
                            id title cached_contributors
                            image { url }
                        }
                        edition { pages audio_seconds }
                        user_book_reads(order_by: {id: desc}, limit: 1) {
                            progress_pages progress_seconds finished_at
                            edition { pages audio_seconds }
                        }
                    }
                }
            }
            """.trimIndent(),
            token,
        )
        val rows = data.optArray("me")?.firstOrNull()?.jsonObject?.optArray("user_books").orEmpty()
        return rows.mapNotNull { element ->
            val row = element.jsonObject
            val book = row.optObject("book") ?: return@mapNotNull null
            val read = row.optArray("user_book_reads")?.firstOrNull()?.jsonObject
            HardcoverLibraryBook(
                id = row.optInt("id") ?: return@mapNotNull null,
                bookId = row.optInt("book_id") ?: book.optInt("id") ?: return@mapNotNull null,
                title = book.optString("title") ?: return@mapNotNull null,
                author = book.get("cached_contributors").contributors(),
                coverUrl = book.optObject("image")?.optString("url"),
                statusId = row.optInt("status_id") ?: 1,
                rating = row.optDouble("rating"),
                progress = hardcoverReadProgress(read, row.optObject("edition")),
            )
        }
    }

    private suspend fun getUserLists(token: String, userId: Int): List<HardcoverUserList> {
        val data = performQuery(
            """
            query {
                lists(where: {user_id: {_eq: $userId}}, order_by: {id: desc}) {
                    id name description slug books_count likes_count
                }
            }
            """.trimIndent(),
            token,
        )
        return data.optArray("lists").orEmpty().mapNotNull { element ->
            val row = element.jsonObject
            HardcoverUserList(
                id = row.optInt("id") ?: return@mapNotNull null,
                name = row.optString("name") ?: return@mapNotNull null,
                description = row.optString("description"),
                booksCount = row.optInt("books_count") ?: 0,
                likesCount = row.optInt("likes_count"),
            )
        }
    }

    private suspend fun getActivityFeed(token: String, userId: Int, username: String, limit: Int): List<HardcoverActivity> {
        val data = performQuery(
            """
            query {
                user_books(
                    where: {user_id: {_eq: $userId}, status_id: {_is_null: false}},
                    order_by: {updated_at: desc},
                    limit: $limit
                ) {
                    id updated_at status_id rating
                    book { id title cached_contributors image { url } }
                }
            }
            """.trimIndent(),
            token,
        )
        return data.optArray("user_books").orEmpty().mapNotNull { element ->
            val row = element.jsonObject
            val book = row.optObject("book")
            HardcoverActivity(
                id = row.optInt("id") ?: return@mapNotNull null,
                action = "${username.ifBlank { "You" }} ${hardcoverActivityText(row.optInt("status_id"))}",
                createdAt = row.optString("updated_at").orEmpty(),
                bookTitle = book?.optString("title"),
                author = book?.get("cached_contributors").contributors(),
                coverUrl = book?.optObject("image")?.optString("url"),
            )
        }
    }

    private suspend fun annualGoal(token: String, year: Int): JsonObject? {
        val data = performQuery(
            """
            query HardcoverAnnualGoal(${'$'}start: date!, ${'$'}end: date!) {
                me {
                    goals(where: {metric: {_eq: "book"}, start_date: {_eq: ${'$'}start}, end_date: {_eq: ${'$'}end}}, order_by: {id: desc}) {
                        id goal metric description start_date end_date privacy_setting_id archived conditions progress
                    }
                }
            }
            """.trimIndent(),
            token,
            buildJsonObject {
                put("start", "$year-01-01")
                put("end", "$year-12-31")
            },
        )
        val goals = data.optArray("me")?.firstOrNull()?.jsonObject?.optArray("goals") ?: return null
        return hardcoverAnnualBookGoal(goals, year)
    }

    private suspend fun getReadingGoal(token: String, year: Int): HardcoverReadingGoal? {
        val goal = annualGoal(token, year) ?: return null
        return HardcoverReadingGoal(
            year = year,
            target = goal.optInt("goal") ?: return null,
            current = goal.optDouble("progress")?.toInt() ?: 0,
        )
    }

    private suspend fun performQuery(
        query: String,
        token: String,
        variables: JsonObject? = null,
        requireActive: Boolean = true,
    ): JsonObject = withContext(Dispatchers.IO) {
        val ensureAccount = { if (requireActive && activeToken() != token) throw HardcoverAccountChangedException() }
        ensureAccount()
        val payload = buildJsonObject {
            put("query", query)
            variables?.let { put("variables", it) }
        }
        val request = Request.Builder()
            .url(BASE_URL)
            .post(payload.toString().toRequestBody(JSON_MEDIA_TYPE))
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .header("Authorization", "Bearer $token")
            .build()

        val pacer = pacers.computeIfAbsent(hardcoverAccountKey(token)) { HardcoverRequestPacer() }
        val result = hardcoverPacedExchange(pacer, hardcoverRootFieldCount(query), ensureAccount) {
            hardcoverExchange(client, request)
        }
        currentCoroutineContext().ensureActive()
        if (result.code !in 200..299) {
            if (result.code == 401 && requireActive && activeToken() == token) clearToken()
            throw hardcoverHttpError(result.code, result.body, result.rate.retryAfterMs)
        }
        val root = try {
            json.parseToJsonElement(result.body).jsonObject
        } catch (_: IllegalArgumentException) {
            throw HardcoverTransientException("Hardcover returned an unreadable response.")
        }
        root.optString("error")?.let { error ->
            if (requireActive && hardcoverInvalidTokenMessage(error) && activeToken() == token) clearToken()
            throw HardcoverException(error)
        }
        root.optArray("errors")?.firstOrNull()?.jsonObject?.optString("message")?.let { message ->
            if (requireActive && hardcoverInvalidTokenMessage(message) && activeToken() == token) clearToken()
            throw HardcoverException(message)
        }
        ensureAccount()
        root.optObject("data") ?: throw HardcoverException("Hardcover response did not include data.")
    }

    private fun JsonObject?.toEdition(): HardcoverEdition? {
        val edition = this ?: return null
        return HardcoverEdition(
            id = edition.optInt("id") ?: return null,
            pages = edition.optInt("pages"),
            audioSeconds = edition.optInt("audio_seconds"),
        )
    }

    private fun JsonElement?.contributors(): String? {
        val element = this ?: return null
        return when (element) {
            is JsonArray -> element.mapNotNull { item ->
                when (item) {
                    is JsonObject -> item.optObject("author")?.optString("name") ?: item.optString("name")
                    else -> item.jsonPrimitive.contentOrNull
                }
            }.joinToString(", ").takeIf { it.isNotBlank() }
            is JsonObject -> element.optObject("author")?.optString("name") ?: element.optString("name")
            else -> element.jsonPrimitive.contentOrNull
        }
    }

    companion object {
        private const val BASE_URL = "https://api.hardcover.app/v1/graphql"
        private val JSON_MEDIA_TYPE = "application/json".toMediaType()
    }
}

fun hardcoverStatusLabel(statusId: Int): String = when (statusId) {
    1 -> "Want to Read"
    2 -> "Currently Reading"
    3 -> "Read"
    4 -> "Paused"
    6 -> "Ignored"
    5 -> "Did Not Finish"
    else -> "Reading"
}

private fun hardcoverActivityText(statusId: Int?): String = when (statusId) {
    1 -> "wants to read"
    2 -> "started reading"
    3 -> "finished"
    4 -> "paused"
    6 -> "ignored"
    5 -> "did not finish"
    else -> "updated"
}
