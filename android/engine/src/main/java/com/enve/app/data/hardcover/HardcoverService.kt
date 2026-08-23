package com.enve.app.data.hardcover

import com.enve.core.auth.CredentialVault
import com.enve.core.di.RefreshClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
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
        val hits = data.obj("search")
            ?.get("results")
            ?.let(::normalizeJsonObject)
            ?.array("hits")
            .orEmpty()

        return hits.mapNotNull { hit ->
            val doc = hit.jsonObject.obj("document") ?: return@mapNotNull null
            HardcoverBookResult(
                id = doc.string("id")?.toIntOrNull() ?: doc.int("id") ?: return@mapNotNull null,
                title = doc.string("title") ?: return@mapNotNull null,
                author = doc.array("author_names")?.mapNotNull { it.jsonPrimitive.contentOrNull }?.joinToString(", "),
                coverUrl = doc.obj("image")?.string("url"),
                releaseYear = doc.int("release_year"),
            )
        }
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
        data.obj("insert_user_book")?.obj("user_book")?.int("id")?.let { return it }
        data.obj("insert_user_book")?.string("error")?.let { throw HardcoverException(it) }
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
        val user = data.array("me")?.firstOrNull()?.jsonObject
            ?: throw HardcoverException("Hardcover account not found.")
        return HardcoverProfile(
            id = user.int("id") ?: throw HardcoverException("Hardcover account id missing."),
            username = user.string("username").orEmpty(),
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
        val rows = data.array("me")?.firstOrNull()?.jsonObject?.array("user_books").orEmpty()
        return rows.mapNotNull { element ->
            val row = element.jsonObject
            val book = row.obj("book") ?: return@mapNotNull null
            val edition = row.obj("edition")
            val read = row.array("user_book_reads")?.firstOrNull()?.jsonObject
            val pageProgress = progressFraction(read?.int("progress_pages"), edition?.int("pages"))
            HardcoverLibraryBook(
                id = row.int("id") ?: return@mapNotNull null,
                bookId = row.int("book_id") ?: book.int("id") ?: return@mapNotNull null,
                title = book.string("title") ?: return@mapNotNull null,
                author = book.get("cached_contributors").contributors(),
                coverUrl = book.obj("image")?.string("url"),
                statusId = row.int("status_id") ?: 1,
                rating = row.double("rating"),
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
        return data.array("lists").orEmpty().mapNotNull { element ->
            val row = element.jsonObject
            HardcoverUserList(
                id = row.int("id") ?: return@mapNotNull null,
                name = row.string("name") ?: return@mapNotNull null,
                description = row.string("description"),
                booksCount = row.int("books_count") ?: 0,
                likesCount = row.int("likes_count"),
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
        return data.array("user_books").orEmpty().mapNotNull { element ->
            val row = element.jsonObject
            val book = row.obj("book")
            HardcoverActivity(
                id = row.int("id") ?: return@mapNotNull null,
                action = "${username.ifBlank { "You" }} ${hardcoverActivityText(row.int("status_id"))}",
                createdAt = row.string("updated_at").orEmpty(),
                bookTitle = book?.string("title"),
                author = book?.get("cached_contributors").contributors(),
                coverUrl = book?.obj("image")?.string("url"),
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
        val goal = data.array("me")?.firstOrNull()?.jsonObject?.array("goals")?.firstOrNull()?.jsonObject
            ?: return null
        val finished = countFinishedBooks(userId, startDate, endDate)
        return HardcoverReadingGoal(
            year = year,
            target = goal.int("goal") ?: return null,
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
        return data.obj("user_book_reads_aggregate")?.obj("aggregate")?.int("count") ?: 0
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
            root.string("error")?.let { error ->
                if (error.contains("token", ignoreCase = true)) clearToken()
                throw HardcoverException(error)
            }
            root.array("errors")?.firstOrNull()?.jsonObject?.string("message")?.let { message ->
                if (message.contains("token", ignoreCase = true) || message.contains("unauthorized", ignoreCase = true)) {
                    clearToken()
                }
                throw HardcoverException(message)
            }
            root.obj("data") ?: throw HardcoverException("Hardcover response did not include data.")
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

    private fun normalizeJsonObject(element: JsonElement): JsonObject? {
        if (element is JsonObject) return element
        val raw = element.jsonPrimitive.contentOrNull ?: return null
        return runCatching { json.parseToJsonElement(raw).jsonObject }.getOrNull()
    }

    private fun String.graphQLEscaped(): String =
        replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", " ")

    private fun JsonObject.obj(key: String): JsonObject? = get(key) as? JsonObject
    private fun JsonObject.array(key: String): JsonArray? = get(key) as? JsonArray
    private fun JsonObject.string(key: String): String? = get(key)?.jsonPrimitive?.contentOrNull
    private fun JsonObject.int(key: String): Int? = get(key)?.jsonPrimitive?.intOrNull
    private fun JsonObject.double(key: String): Double? = get(key)?.jsonPrimitive?.doubleOrNull

    private fun JsonElement?.contributors(): String? {
        val element = this ?: return null
        return when (element) {
            is JsonArray -> element.mapNotNull { item ->
                when (item) {
                    is JsonObject -> item.obj("author")?.string("name") ?: item.string("name")
                    else -> item.jsonPrimitive.contentOrNull
                }
            }.joinToString(", ").takeIf { it.isNotBlank() }
            is JsonObject -> element.obj("author")?.string("name") ?: element.string("name")
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
