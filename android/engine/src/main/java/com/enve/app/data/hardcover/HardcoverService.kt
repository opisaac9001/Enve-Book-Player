package com.enve.app.data.hardcover

import com.enve.core.auth.CredentialVault
import com.enve.core.data.util.optArray
import com.enve.core.data.util.optDouble
import com.enve.core.data.util.optInt
import com.enve.core.data.util.optObject
import com.enve.core.data.util.optString
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.Calendar
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
)

class HardcoverException(message: String) : Exception(message)

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
        )
    }

@Singleton
class HardcoverService @Inject constructor(
    @RefreshClient private val client: OkHttpClient,
    private val vault: CredentialVault,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    fun hasToken(): Boolean = !vault.get(CredentialVault.HARDCOVER_API_KEY).isNullOrBlank()

    fun clearToken() {
        vault.remove(CredentialVault.HARDCOVER_API_KEY)
    }

    suspend fun saveToken(token: String): HardcoverProfile {
        val trimmed = token.trim()
        if (trimmed.isBlank()) throw HardcoverException("Paste a Hardcover API token.")
        vault.put(CredentialVault.HARDCOVER_API_KEY, trimmed)
        return runCatching { getCurrentUser() }
            .onFailure { clearToken() }
            .getOrThrow()
    }

    suspend fun loadHubData(): HardcoverHubData {
        val profile = getCurrentUser()
        val userId = profile.id
        val year = Calendar.getInstance().get(Calendar.YEAR)
        val startDate = "$year-01-01"
        val endDate = "$year-12-31"

        val library = getUserBooks(limit = 50)
        val lists = getUserLists(userId)
        val activity = getActivityFeed(userId, profile.username, limit = 10)
        val goal = getReadingGoal(userId, year, startDate, endDate)

        return HardcoverHubData(profile, library, lists, activity, goal)
    }

    suspend fun searchBooks(query: String, limit: Int = 20): List<HardcoverBookResult> {
        val trimmed = query.trim()
        if (trimmed.isBlank()) return emptyList()
        val data = performQuery(
            """
            query {
                search(query: "${trimmed.graphQLEscaped()}", query_type: "Book", per_page: $limit, page: 1) {
                    results
                }
            }
            """.trimIndent()
        )
        val results = data.optObject("search")?.get("results") ?: return emptyList()
        return hardcoverBookSearchResults(results)
    }

    suspend fun addBookToLibrary(bookId: Int, startReading: Boolean = false): Int {
        val statusId = if (startReading) 2 else 1
        val today = todayString()
        val data = performQuery(
            """
            mutation {
                insert_user_book(object: {book_id: $bookId, status_id: $statusId, date_added: "$today"}) {
                    error
                    user_book { id }
                }
            }
            """.trimIndent()
        )
        data.optObject("insert_user_book")?.optObject("user_book")?.optInt("id")?.let { return it }
        data.optObject("insert_user_book")?.optString("error")?.let { throw HardcoverException(it) }
        throw HardcoverException("Hardcover did not return a library row.")
    }

    suspend fun setReadingGoal(target: Int) {
        if (target <= 0) throw HardcoverException("Goal must be greater than zero.")
        val year = Calendar.getInstance().get(Calendar.YEAR)
        performQuery(
            """
            mutation {
                insert_reading_goals(
                    objects: {year: $year, target: $target},
                    on_conflict: {constraint: reading_goals_user_id_year_key, update_columns: [target]}
                ) {
                    returning { id target }
                }
            }
            """.trimIndent()
        )
    }

    private suspend fun getCurrentUser(): HardcoverProfile {
        val data = performQuery("""query { me { id username } }""")
        val user = data.optArray("me")?.firstOrNull()?.jsonObject
            ?: throw HardcoverException("Hardcover account not found.")
        return HardcoverProfile(
            id = user.optInt("id") ?: throw HardcoverException("Hardcover account id missing."),
            username = user.optString("username").orEmpty(),
        )
    }

    private suspend fun getUserBooks(limit: Int): List<HardcoverLibraryBook> {
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
                        }
                    }
                }
            }
            """.trimIndent()
        )
        val rows = data.optArray("me")?.firstOrNull()?.jsonObject?.optArray("user_books").orEmpty()
        return rows.mapNotNull { element ->
            val row = element.jsonObject
            val book = row.optObject("book") ?: return@mapNotNull null
            val edition = row.optObject("edition")
            val read = row.optArray("user_book_reads")?.firstOrNull()?.jsonObject
            val pageProgress = progressFraction(read?.optInt("progress_pages"), edition?.optInt("pages"))
            HardcoverLibraryBook(
                id = row.optInt("id") ?: return@mapNotNull null,
                bookId = row.optInt("book_id") ?: book.optInt("id") ?: return@mapNotNull null,
                title = book.optString("title") ?: return@mapNotNull null,
                author = book.get("cached_contributors").contributors(),
                coverUrl = book.optObject("image")?.optString("url"),
                statusId = row.optInt("status_id") ?: 1,
                rating = row.optDouble("rating"),
                progress = pageProgress,
            )
        }
    }

    private suspend fun getUserLists(userId: Int): List<HardcoverUserList> {
        val data = performQuery(
            """
            query {
                lists(where: {user_id: {_eq: $userId}}, order_by: {id: desc}) {
                    id name description slug books_count likes_count
                }
            }
            """.trimIndent()
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

    private suspend fun getActivityFeed(userId: Int, username: String, limit: Int): List<HardcoverActivity> {
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
            """.trimIndent()
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

    private suspend fun getReadingGoal(
        userId: Int,
        year: Int,
        startDate: String,
        endDate: String,
    ): HardcoverReadingGoal? {
        val data = performQuery(
            """
            query {
                me {
                    goals(where: {start_date: {_lte: "$endDate"}, end_date: {_gte: "$startDate"}}) {
                        id goal metric start_date end_date
                    }
                }
            }
            """.trimIndent()
        )
        val goal = data.optArray("me")?.firstOrNull()?.jsonObject?.optArray("goals")?.firstOrNull()?.jsonObject
            ?: return null
        val finished = countFinishedBooks(userId, startDate, endDate)
        return HardcoverReadingGoal(
            year = year,
            target = goal.optInt("goal") ?: return null,
            current = finished,
        )
    }

    private suspend fun countFinishedBooks(userId: Int, startDate: String, endDate: String): Int {
        val data = performQuery(
            """
            query {
                user_book_reads_aggregate(
                    where: {
                        finished_at: {_gte: "$startDate", _lte: "$endDate"},
                        user_book: {user_id: {_eq: $userId}}
                    }
                ) {
                    aggregate { count }
                }
            }
            """.trimIndent()
        )
        return data.optObject("user_book_reads_aggregate")?.optObject("aggregate")?.optInt("count") ?: 0
    }

    private suspend fun performQuery(query: String): JsonObject = withContext(Dispatchers.IO) {
        val token = vault.get(CredentialVault.HARDCOVER_API_KEY)
            ?: throw HardcoverException("Connect Hardcover with an API token first.")
        val body = JSONObject().put("query", query).toString().toRequestBody(JSON_MEDIA_TYPE)
        val request = Request.Builder()
            .url(BASE_URL)
            .post(body)
            .header("Content-Type", "application/json")
            .header("Accept", "application/json")
            .header("Authorization", "Bearer $token")
            .build()

        client.newCall(request).execute().use { response ->
            val responseText = response.body?.string().orEmpty()
            if (!response.isSuccessful) {
                if (response.code == 401 || response.code == 403) clearToken()
                throw HardcoverException("Hardcover returned HTTP ${response.code}.")
            }
            val root = json.parseToJsonElement(responseText).jsonObject
            root.optString("error")?.let { error ->
                if (error.contains("token", ignoreCase = true)) clearToken()
                throw HardcoverException(error)
            }
            root.optArray("errors")?.firstOrNull()?.jsonObject?.optString("message")?.let { message ->
                if (message.contains("token", ignoreCase = true) || message.contains("unauthorized", ignoreCase = true)) {
                    clearToken()
                }
                throw HardcoverException(message)
            }
            root.optObject("data") ?: throw HardcoverException("Hardcover response did not include data.")
        }
    }

    private fun progressFraction(progressPages: Int?, pages: Int?): Float {
        if (progressPages == null || pages == null || pages <= 0) return 0f
        return (progressPages.toFloat() / pages.toFloat()).coerceIn(0f, 1f)
    }

    private fun todayString(): String {
        val calendar = Calendar.getInstance()
        val year = calendar.get(Calendar.YEAR)
        val month = calendar.get(Calendar.MONTH) + 1
        val day = calendar.get(Calendar.DAY_OF_MONTH)
        return "%04d-%02d-%02d".format(year, month, day)
    }

    private fun String.graphQLEscaped(): String =
        replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ")

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
    3 -> "Finished"
    5 -> "Did Not Finish"
    else -> "Reading"
}

private fun hardcoverActivityText(statusId: Int?): String = when (statusId) {
    1 -> "wants to read"
    2 -> "started reading"
    3 -> "finished"
    5 -> "did not finish"
    else -> "updated"
}
