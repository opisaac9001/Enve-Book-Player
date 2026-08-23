package com.enve.komga

import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.provider.ProviderMetadataUpdate
import com.enve.core.data.util.runSuspendCatching
import com.enve.komga.api.KomgaApi
import com.enve.komga.dto.KomgaBookDto
import com.enve.komga.dto.KomgaReadProgressUpdateDto
import com.enve.komga.dto.displayMetadata
import com.enve.core.di.RefreshClient
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import javax.inject.Inject
import javax.inject.Singleton
import java.time.LocalDate
import java.time.OffsetDateTime
import kotlin.math.ceil
import java.io.File

@Singleton
class KomgaRepository @Inject constructor(
    private val api: KomgaApi,
    private val prefs: PreferencesManager,
    private val connectionRegistry: ConnectionRegistry,
    @ApplicationContext private val context: android.content.Context,
    @RefreshClient private val plainHttpClient: OkHttpClient,
) {
    suspend fun getComicPageCount(bookId: String): Result<Int> = runSuspendCatching {
        val response = api.getBook(bookId)
        if (!response.isSuccessful) error("getBook HTTP ${response.code()}")
        response.body()?.media?.pagesCount?.takeIf { it > 0 }
            ?: error("Komga did not return a page count")
    }

    suspend fun downloadComicPage(bookId: String, pageIndex: Int, destination: File): Result<Unit> = runSuspendCatching {
        val response = api.getBookPage(bookId, pageIndex + 1)
        if (!response.isSuccessful) error("getBookPage HTTP ${response.code()}")
        val body = response.body() ?: error("Komga returned an empty page")
        body.use { responseBody ->
            destination.outputStream().buffered().use { output ->
                responseBody.byteStream().use { input -> input.copyTo(output) }
            }
        }
    }

    private fun scopedServerUrl(): String {
        connectionRegistry.getScopedConnectionSync()?.let { return it.serverUrl }
        return prefs.getServerUrlSync() ?: ""
    }
    private val jsonSerializer = Json {
        ignoreUnknownKeys = true
        coerceInputValues = true
        encodeDefaults = true
    }

    @Serializable
    private data class KomgaBookCachePayload(
        val serverUrl: String,
        val savedAt: Long,
        val libraryId: String? = null,
        val books: List<Book> = emptyList(),
    )

    @Serializable
    private data class KomgaLibraryCachePayload(
        val serverUrl: String,
        val savedAt: Long,
        val libraries: List<Library> = emptyList(),
    )

    @Serializable
    private data class KomgaLaneCachePayload(
        val serverUrl: String,
        val lane: String,
        val savedAt: Long,
        val books: List<Book> = emptyList(),
    )

    private fun cacheFileForBooks(serverUrl: String, libraryId: String?): java.io.File {
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val safeLibrary = (libraryId ?: "all").replace(Regex("[^a-zA-Z0-9._-]"), "_")
        val name = "books_komga_${safeServer}_${safeLibrary}.json"
        return java.io.File(cacheDir, name)
    }

    private fun cacheFileForLibraries(serverUrl: String): java.io.File {
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "libraries_komga_${safeServer}.json"
        return java.io.File(cacheDir, name)
    }

    private fun cacheFileForLane(serverUrl: String, lane: String): java.io.File {
        val cacheDir = java.io.File(context.cacheDir, "book-index-cache").also { it.mkdirs() }
        val safeServer = serverUrl.lowercase().replace(Regex("[^a-z0-9._-]"), "_")
        val name = "lane_komga_${safeServer}_${lane}.json"
        return java.io.File(cacheDir, name)
    }

    suspend fun fetchCurrentUser(): Result<com.enve.komga.dto.KomgaUserDto> = runSuspendCatching {
        val resp = api.getCurrentUser()
        if (!resp.isSuccessful) error("getCurrentUser HTTP ${resp.code()}")
        resp.body() ?: error("Empty body for /users/me")
    }

    suspend fun fetchLibrariesRaw(): Result<List<com.enve.komga.dto.KomgaLibraryDto>> = runSuspendCatching {
        val resp = api.getLibraries()
        if (!resp.isSuccessful) error("getLibraries HTTP ${resp.code()}")
        resp.body() ?: emptyList()
    }

    suspend fun fetchCollectionsRaw(): Result<List<com.enve.komga.dto.KomgaCollectionDto>> = runSuspendCatching {
        val resp = api.getCollections(page = 0, size = 500)
        if (!resp.isSuccessful) error("getCollections HTTP ${resp.code()}")
        resp.body()?.content.orEmpty()
    }

    suspend fun fetchReadListsRaw(): Result<List<com.enve.komga.dto.KomgaReadListDto>> = runSuspendCatching {
        val resp = api.getReadLists(page = 0, size = 500)
        if (!resp.isSuccessful) error("getReadLists HTTP ${resp.code()}")
        resp.body()?.content.orEmpty()
    }

    private inline fun <T> wrap(call: () -> retrofit2.Response<T>): Result<T> = try {
        val response = call()
        if (!response.isSuccessful) error("HTTP ${response.code()}: ${response.message()}")
        Result.success(response.body() ?: error("Empty body"))
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }

    private inline fun wrapUnit(call: () -> retrofit2.Response<Unit>): Result<Unit> = try {
        val response = call()
        if (!response.isSuccessful) error("HTTP ${response.code()}: ${response.message()}")
        Result.success(Unit)
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        Result.failure(e)
    }

    suspend fun adminListUsers(): Result<List<com.enve.komga.dto.KomgaUserDto>> = wrap { api.adminListUsers() }
    suspend fun adminCreateUser(body: com.enve.komga.dto.KomgaUserCreationDto) = wrap { api.adminCreateUser(body) }
    suspend fun adminDeleteUser(id: String) = wrapUnit { api.adminDeleteUser(id) }
    suspend fun adminUpdateUser(id: String, body: com.enve.komga.dto.KomgaUserUpdateDto) = wrapUnit { api.adminUpdateUser(id, body) }
    suspend fun adminUpdateUserPassword(id: String, password: String) = wrapUnit {
        api.adminUpdateUserPassword(id, com.enve.komga.dto.KomgaPasswordUpdateDto(password))
    }

    suspend fun adminCreateLibrary(body: com.enve.komga.dto.KomgaLibraryCreationDto) = wrap { api.adminCreateLibrary(body) }
    suspend fun adminUpdateLibrary(id: String, body: com.enve.komga.dto.KomgaLibraryUpdateDto) = wrapUnit { api.adminUpdateLibrary(id, body) }
    suspend fun adminDeleteLibrary(id: String) = wrapUnit { api.adminDeleteLibrary(id) }
    suspend fun adminScanLibrary(id: String, deep: Boolean) = wrapUnit { api.adminScanLibrary(id, deep) }
    suspend fun adminAnalyzeLibrary(id: String) = wrapUnit { api.adminAnalyzeLibrary(id) }
    suspend fun adminRefreshLibraryMetadata(id: String) = wrapUnit { api.adminRefreshLibraryMetadata(id) }
    suspend fun adminEmptyLibraryTrash(id: String) = wrapUnit { api.adminEmptyLibraryTrash(id) }

    suspend fun adminCreateCollection(body: com.enve.komga.dto.KomgaCollectionCreationDto) = wrap { api.adminCreateCollection(body) }
    suspend fun adminUpdateCollection(id: String, body: com.enve.komga.dto.KomgaCollectionUpdateDto) = wrapUnit { api.adminUpdateCollection(id, body) }
    suspend fun adminDeleteCollection(id: String) = wrapUnit { api.adminDeleteCollection(id) }

    suspend fun adminCreateReadList(body: com.enve.komga.dto.KomgaReadListCreationDto) = wrap { api.adminCreateReadList(body) }
    suspend fun adminUpdateReadList(id: String, body: com.enve.komga.dto.KomgaReadListUpdateDto) = wrapUnit { api.adminUpdateReadList(id, body) }
    suspend fun adminDeleteReadList(id: String) = wrapUnit { api.adminDeleteReadList(id) }

    suspend fun adminServerInfo() = wrap { api.adminServerInfo() }
    suspend fun adminListTasks() = wrap { api.adminListTasks() }
    suspend fun adminListAnnouncements() = wrap { api.adminListAnnouncements() }
    suspend fun adminMarkAnnouncementsRead(ids: List<String>) = wrapUnit { api.adminMarkAnnouncementsRead(ids) }
    suspend fun adminListHistory(page: Int = 0, size: Int = 100) = wrap { api.adminListHistory(page, size) }
    suspend fun adminListApiKeys() = wrap { api.adminListApiKeys() }
    suspend fun adminCreateApiKey(comment: String) = wrap {
        api.adminCreateApiKey(com.enve.komga.dto.KomgaApiKeyCreationDto(comment))
    }
    suspend fun adminDeleteApiKey(id: String) = wrapUnit { api.adminDeleteApiKey(id) }

    private suspend fun loadBooksFromDisk(serverUrl: String, libraryId: String?): List<Book>? = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val file = cacheFileForBooks(normalizedUrl, libraryId)
            if (!file.exists() || file.length() == 0L) {
                android.util.Log.d("KomgaRepository", "Book cache not found for $normalizedUrl (lib: $libraryId)")
                return@runCatching null
            }
            val payload = jsonSerializer.decodeFromString<KomgaBookCachePayload>(file.readText())
            if (payload.serverUrl.trimEnd('/') != normalizedUrl || payload.libraryId != libraryId) {
                android.util.Log.d("KomgaRepository", "Book cache mismatch: ${payload.serverUrl} vs $normalizedUrl")
                return@runCatching null
            }

            if (System.currentTimeMillis() - payload.savedAt > 3600_000) {
                android.util.Log.d("KomgaRepository", "Book cache expired for $normalizedUrl")
                return@runCatching null
            }
            android.util.Log.d("KomgaRepository", "Loading ${payload.books.size} books from cache for $normalizedUrl")
            payload.books
        }.onFailure {
            android.util.Log.e("KomgaRepository", "Failed to load book cache", it)
        }.getOrNull()
    }

    private suspend fun saveBooksToDisk(serverUrl: String, libraryId: String?, books: List<Book>) = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val payload = KomgaBookCachePayload(
                serverUrl = normalizedUrl,
                libraryId = libraryId,
                savedAt = System.currentTimeMillis(),
                books = books,
            )
            cacheFileForBooks(normalizedUrl, libraryId).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    private suspend fun loadLibrariesFromDisk(serverUrl: String): List<Library>? = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val file = cacheFileForLibraries(normalizedUrl)
            if (!file.exists() || file.length() == 0L) return@runCatching null
            val payload = jsonSerializer.decodeFromString<KomgaLibraryCachePayload>(file.readText())
            if (payload.serverUrl.trimEnd('/') != normalizedUrl) return@runCatching null

            if (System.currentTimeMillis() - payload.savedAt > 86400_000) return@runCatching null
            payload.libraries
        }.getOrNull()
    }

    private suspend fun saveLibrariesToDisk(serverUrl: String, libraries: List<Library>) = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val payload = KomgaLibraryCachePayload(
                serverUrl = normalizedUrl,
                savedAt = System.currentTimeMillis(),
                libraries = libraries,
            )
            cacheFileForLibraries(normalizedUrl).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    private suspend fun loadLaneFromDisk(serverUrl: String, lane: String): List<Book>? = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val file = cacheFileForLane(normalizedUrl, lane)
            if (!file.exists() || file.length() == 0L) {
                android.util.Log.d("KomgaRepository", "Lane cache not found for $normalizedUrl ($lane)")
                return@runCatching null
            }
            val text = file.readText()
            val payload = jsonSerializer.decodeFromString<KomgaLaneCachePayload>(text)
            if (payload.serverUrl.trimEnd('/') != normalizedUrl || payload.lane != lane) {
                android.util.Log.d("KomgaRepository", "Lane cache mismatch: ${payload.serverUrl} vs $normalizedUrl")
                return@runCatching null
            }

            if (System.currentTimeMillis() - payload.savedAt > 1800_000) {
                android.util.Log.d("KomgaRepository", "Lane cache expired for $normalizedUrl ($lane)")
                return@runCatching null
            }
            android.util.Log.d("KomgaRepository", "Loading lane $lane from cache for $normalizedUrl")
            payload.books
        }.onFailure {
            android.util.Log.e("KomgaRepository", "Failed to load lane cache", it)
        }.getOrNull()
    }

    private suspend fun saveLaneToDisk(serverUrl: String, lane: String, books: List<Book>) = withContext(Dispatchers.IO) {
        runCatching {
            val normalizedUrl = serverUrl.trimEnd('/')
            val payload = KomgaLaneCachePayload(
                serverUrl = normalizedUrl,
                lane = lane,
                savedAt = System.currentTimeMillis(),
                books = books,
            )
            cacheFileForLane(normalizedUrl, lane).writeText(jsonSerializer.encodeToString(payload))
        }
    }

    suspend fun getLibraries(): Result<List<Library>> {
        return try {
            val serverUrl = scopedServerUrl()
            val normalizedUrl = serverUrl.trimEnd('/')

            val cached = loadLibrariesFromDisk(normalizedUrl)
            if (!cached.isNullOrEmpty()) {
                return Result.success(cached)
            }

            val response = api.getLibraries()
            if (response.code() == 401) {
                return Result.failure(Exception("Unauthorized: Please check your Komga username and password."))
            }
            if (!response.isSuccessful) {
                return Result.failure(Exception("Failed to fetch Komga libraries: HTTP ${response.code()}"))
            }
            val body = response.body() ?: return Result.success(emptyList())

            val libs = body.map { dto ->
                Library(
                    id = dto.id,
                    name = dto.name,
                    bookCount = 0
                )
            }

            saveLibrariesToDisk(normalizedUrl, libs)
            Result.success(libs)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun verifyCredentials(
        serverUrl: String,
        username: String,
        password: String,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val url = serverUrl.trimEnd('/') + "/api/v1/libraries"
            val credential = okhttp3.Credentials.basic(username, password)
            val request = Request.Builder()
                .url(url)
                .header("Authorization", credential)
                .header("Accept", "application/json")
                .get()
                .build()
            val response = plainHttpClient.newCall(request).execute()
            response.body?.close()
            if (response.isSuccessful) {
                Result.success(Unit)
            } else {
                val msg = when (response.code) {
                    401 -> "Invalid username or password"
                    403 -> "Access denied - check Komga user permissions"
                    404 -> "Komga API not found - verify the server URL"
                    else -> "Server returned HTTP ${response.code}"
                }
                Result.failure(Exception(msg))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: java.net.ConnectException) {
            Result.failure(Exception("Could not connect to Komga - check the server URL and port"))
        } catch (e: java.net.UnknownHostException) {
            Result.failure(Exception("Unknown host - check the server URL"))
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getBooks(
        libraryId: String? = null,
        page: Int = 0,
        size: Int = 100,
        sort: String = "addedOn",
        dir: String = "desc",
    ): Result<List<Book>> {
        return try {
            val serverUrl = scopedServerUrl()
            val normalizedUrl = serverUrl.trimEnd('/')

            val cached = loadBooksFromDisk(normalizedUrl, libraryId)
            if (!cached.isNullOrEmpty()) {
                return Result.success(cached)
            }

            val targetLibraryId = libraryId

            val allBooks = mutableListOf<Book>()
            var currentPage = 0
            val limit = 500

            while (true) {
                val response = api.getBooks(libraryId = targetLibraryId, page = currentPage, size = limit)
                if (response.code() == 401) {
                    return Result.failure(Exception("Unauthorized: Please check your Komga username and password."))
                }
                if (!response.isSuccessful) break
                val body = response.body() ?: break

                if (body.content.isEmpty()) break

                allBooks += body.content.mapNotNull { dto ->
                    mapKomgaBook(dto, dto.libraryId, normalizedUrl)
                }

                val totalPages = body.totalPages ?: 1
                val isLast = body.last ?: (currentPage >= totalPages - 1)
                if (isLast) break

                currentPage++

                if (currentPage > 1000) break
            }

            val sorted = allBooks.distinctBy { it.id }.sortedByDescending { it.addedOn }

            saveBooksToDisk(normalizedUrl, libraryId, sorted)

            Result.success(sorted)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getBooksPage(
        connectionId: String,
        libraryId: String? = null,
        page: Int = 0,
        size: Int = 50,
        sort: String = "metadata.title",
        dir: String = "asc",
        readStatus: List<String>? = null,
        search: String? = null,
    ): Result<com.enve.core.data.model.BookSummaryPage> {
        return try {
            val serverUrl = scopedServerUrl().trimEnd('/')
            val sortList = listOf("$sort,$dir")
            val response = api.getBooks(
                libraryId = libraryId,
                readStatus = readStatus,
                page = page,
                size = size,
                sort = sortList,
                search = search?.takeIf { it.isNotBlank() },
            )
            if (!response.isSuccessful) return Result.failure(Exception("HTTP ${response.code()}"))
            val body = response.body() ?: return Result.failure(Exception("Empty body"))
            val items = body.content.mapNotNull { dto -> mapKomgaBookSummary(dto, connectionId, serverUrl) }
            val totalPages = body.totalPages ?: 1
            val isLast = body.last ?: (page >= totalPages - 1)
            Result.success(com.enve.core.data.model.BookSummaryPage(
                items = items,
                page = page,
                totalPages = totalPages,
                totalElements = (body.totalElements ?: items.size).toLong(),
                hasNext = !isLast,
            ))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun mapKomgaBookSummary(dto: KomgaBookDto, connectionId: String, serverUrl: String): com.enve.core.data.model.BookSummary {
        val displayMetadata = dto.displayMetadata()
        val authors = dto.metadata?.authors?.map { it.name }.orEmpty()
        val mediaTypeStr = dto.media?.mediaType?.lowercase(java.util.Locale.US).orEmpty()
        val mediaType = if (mediaTypeStr.contains("audio")) AppMediaType.AUDIOBOOK else AppMediaType.EBOOK
        val primaryFileType = when {
            mediaTypeStr.contains("epub") -> "EPUB"
            mediaTypeStr.contains("pdf") -> "PDF"
            mediaTypeStr.contains("cbz") || mediaTypeStr.contains("zip") -> "CBZ"
            mediaTypeStr.contains("cbr") || mediaTypeStr.contains("rar") -> "CBR"
            else -> null
        }
        val addedOn = runCatching {
            dto.created?.let { OffsetDateTime.parse(it).toInstant().toEpochMilli() } ?: 0L
        }.getOrDefault(0L)
        val progress = dto.readProgress?.let { rp ->
            val total = dto.media?.pagesCount ?: 0
            if (total > 0) (rp.page.toFloat() / total).coerceIn(0f, 1f) else 0f
        } ?: 0f
        val readStatus = when {
            dto.readProgress?.completed == true -> com.enve.core.data.model.ReadStatus.COMPLETED
            progress > 0f -> com.enve.core.data.model.ReadStatus.IN_PROGRESS
            else -> com.enve.core.data.model.ReadStatus.UNREAD
        }
        val lastReadTime = dto.readProgress?.let { rp ->
            listOfNotNull(rp.lastModified, rp.readDate, rp.created)
                .firstNotNullOfOrNull { raw ->
                    runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
                }
        } ?: 0L
        return com.enve.core.data.model.BookSummary(
            id = dto.id,
            connectionId = connectionId,
            source = BookSource.KOMGA,
            title = displayMetadata.title,
            authors = authors,
            thumbnailUrl = "$serverUrl/api/v1/books/${dto.id}/thumbnail",
            seriesName = displayMetadata.seriesName,
            seriesNumber = displayMetadata.seriesNumber,
            readProgress = progress,
            readStatus = readStatus,
            primaryFileType = primaryFileType,
            mediaType = mediaType,
            addedOn = addedOn,
            lastReadTime = lastReadTime,
            libraryId = dto.libraryId,
        )
    }

    private fun mapKomgaBook(dto: KomgaBookDto, libraryId: String, serverUrl: String): Book? {
        val id = dto.id
        val displayMetadata = dto.displayMetadata()

        val authorList = dto.metadata?.authors?.map { it.name } ?: emptyList()
        val author = authorList.joinToString(", ").takeIf { it.isNotBlank() } ?: "Unknown Author"

        val mediaTypeStr = dto.media?.mediaType?.lowercase(java.util.Locale.US) ?: ""
        val mediaType = if (mediaTypeStr.contains("audio")) {
            AppMediaType.AUDIOBOOK
        } else {
            AppMediaType.EBOOK
        }

        val primaryFileType = when {
            mediaTypeStr.contains("epub") -> "EPUB"
            mediaTypeStr.contains("pdf") -> "PDF"
            mediaTypeStr.contains("cbz") || mediaTypeStr.contains("zip") -> "CBZ"
            mediaTypeStr.contains("cbr") || mediaTypeStr.contains("rar") -> "CBR"
            else -> null
        }

        val addedOn = runCatching {
            dto.created?.let { OffsetDateTime.parse(it).toInstant().toEpochMilli() } ?: 0L
        }.getOrDefault(0L)

        val progress = dto.readProgress?.let { rp ->
            val total = dto.media?.pagesCount ?: 0
            if (total > 0) (rp.page.toFloat() / total).coerceIn(0f, 1f) else 0f
        } ?: 0f
        val lastReadTime = dto.readProgress?.let { rp ->
            listOfNotNull(rp.lastModified, rp.readDate, rp.created)
                .firstNotNullOfOrNull { raw ->
                    runCatching { OffsetDateTime.parse(raw).toInstant().toEpochMilli() }.getOrNull()
                }
        } ?: 0L
        val savedPage = dto.readProgress?.page?.takeIf { it > 0 }

        return Book(
            id = id,
            title = displayMetadata.title,
            author = author,
            description = dto.metadata?.summary,
            coverUrl = "${serverUrl.trimEnd('/')}/api/v1/books/$id/thumbnail",
            mediaType = mediaType,
            primaryFileType = primaryFileType,
            pageCount = dto.media?.pagesCount,
            libraryId = libraryId,
            seriesName = displayMetadata.seriesName,
            seriesNumber = displayMetadata.seriesNumber,
            source = BookSource.KOMGA,
            addedOn = addedOn,
            lastReadTime = lastReadTime,
            readProgress = progress,
            isFinished = dto.readProgress?.completed == true || progress >= 0.99f,
            epubLocator = savedPage?.let { "{\"page\":$it}" },
        )
    }

    suspend fun getContinueListening(): Result<List<Book>> {
        return try {
            val serverUrl = scopedServerUrl()
            val normalizedUrl = serverUrl.trimEnd('/')

            val response = api.getBooks(readStatus = listOf("IN_PROGRESS"), sort = listOf("readProgress.lastModified,desc"), size = 50)
            if (!response.isSuccessful) return Result.success(emptyList())

            val books = response.body()?.content.orEmpty().mapNotNull { mapKomgaBook(it, it.libraryId, normalizedUrl) }
                .filter { it.mediaType == AppMediaType.AUDIOBOOK || it.mediaType == AppMediaType.PODCAST }
                .filter { !it.isFinished && !it.hideFromContinue }
                .take(20)

            saveLaneToDisk(normalizedUrl, "continue-listening", books)
            Result.success(books)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val cached = runSuspendCatching { loadLaneFromDisk(scopedServerUrl().trimEnd('/'), "continue-listening") }.getOrNull()
            if (cached != null) Result.success(cached) else Result.failure(e)
        }
    }

    suspend fun getContinueReading(): Result<List<Book>> {
        return try {
            val serverUrl = scopedServerUrl()
            val normalizedUrl = serverUrl.trimEnd('/')

            val inProgressResp = api.getBooks(readStatus = listOf("IN_PROGRESS"), sort = listOf("readProgress.lastModified,desc"), size = 20)
            val inProgress = if (inProgressResp.isSuccessful) {
                inProgressResp.body()?.content.orEmpty().mapNotNull { mapKomgaBook(it, it.libraryId, normalizedUrl) }
            } else emptyList()

            val merged = inProgress
                .distinctBy { it.id }
                .filter { it.mediaType == AppMediaType.EBOOK }
                .filter { !it.isFinished && !it.hideFromContinue }
                .take(20)

            saveLaneToDisk(normalizedUrl, "continue-reading", merged)
            Result.success(merged)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            val cached = runSuspendCatching { loadLaneFromDisk(scopedServerUrl().trimEnd('/'), "continue-reading") }.getOrNull()
            if (cached != null) Result.success(cached) else Result.failure(e)
        }
    }

    suspend fun getRecentlyAdded(): Result<List<Book>> {
        return try {
            val serverUrl = scopedServerUrl()
            val normalizedUrl = serverUrl.trimEnd('/')
            loadLaneFromDisk(normalizedUrl, "recently-added")?.let { return Result.success(it) }

            val response = runSuspendCatching { api.getBooksLatest(libraryId = null, page = 0, size = 40) }.getOrNull()
                ?: api.getBooks(sort = listOf("created,desc"), size = 40)
            if (!response.isSuccessful) return Result.success(emptyList())

            val books = response.body()?.content.orEmpty().mapNotNull { mapKomgaBook(it, it.libraryId, normalizedUrl) }
                .take(20)

            saveLaneToDisk(normalizedUrl, "recently-added", books)
            Result.success(books)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    fun invalidateListCaches() {
        val cacheDir = File(context.cacheDir, "book-index-cache")
        cacheDir.listFiles()?.forEach { file ->
            if (
                file.name.startsWith("books_komga_") ||
                file.name.startsWith("libraries_komga_") ||
                file.name.startsWith("lane_komga_")
            ) {
                runCatching { file.delete() }
            }
        }
    }

    suspend fun getSeriesReadingDirection(seriesId: String): String? = runSuspendCatching {
        val response = api.getSeriesDetail(seriesId)
        if (!response.isSuccessful) return@runSuspendCatching null
        response.body()?.metadata?.readingDirection
    }.getOrNull()

    suspend fun getSeriesIdForBook(bookId: String): String? = runSuspendCatching {
        val resp = api.getBook(bookId)
        if (!resp.isSuccessful) return@runSuspendCatching null
        resp.body()?.seriesId
    }.getOrNull()

    suspend fun getReadingDirectionForBook(bookId: String): String? = runSuspendCatching {
        val response = api.getBook(bookId)
        if (!response.isSuccessful) return@runSuspendCatching null
        val book = response.body() ?: return@runSuspendCatching null
        val explicit = getSeriesReadingDirection(book.seriesId)?.takeIf { it.isNotBlank() }
        if (explicit != null) return@runSuspendCatching explicit

        val libraries = api.getLibraries().takeIf { it.isSuccessful }?.body().orEmpty()
        val library = libraries.firstOrNull { it.id == book.libraryId }
        inferReadingDirectionFromLibrary(library?.name, library?.root)
    }.getOrNull()

    private fun inferReadingDirectionFromLibrary(name: String?, root: String?): String? {
        val value = listOfNotNull(name, root).joinToString(" ").lowercase()
        return when {
            value.contains("webtoon") || value.contains("vertical") -> "WEBTOON"
            value.contains("manga") || value.contains("マンガ") || value.contains("漫画") -> "RIGHT_TO_LEFT"
            else -> null
        }
    }

    suspend fun markBookUnread(bookId: String): Result<Unit> = runSuspendCatching {
        val resp = api.deleteReadProgress(bookId)
        if (!resp.isSuccessful && resp.code() != 404) {
            error("Komga delete read-progress failed: HTTP ${resp.code()}")
        }
    }

    suspend fun markBookCompleted(bookId: String): Result<Unit> = runSuspendCatching {
        val resp = api.updateReadProgress(
            bookId = bookId,
            request = com.enve.komga.dto.KomgaReadProgressUpdateDto(completed = true),
        )
        if (!resp.isSuccessful) error("Komga mark-completed failed: HTTP ${resp.code()}")
    }

    suspend fun markSeriesRead(seriesId: String): Result<Unit> = runSuspendCatching {
        val resp = api.markSeriesAsRead(seriesId)
        if (!resp.isSuccessful) error("Komga mark-series-read failed: HTTP ${resp.code()}")
    }

    suspend fun markSeriesUnread(seriesId: String): Result<Unit> = runSuspendCatching {
        val resp = api.deleteSeriesReadProgress(seriesId)
        if (!resp.isSuccessful && resp.code() != 404) {
            error("Komga mark-series-unread failed: HTTP ${resp.code()}")
        }
    }

    suspend fun getReadLists(): Result<List<com.enve.komga.dto.KomgaReadListDto>> = runSuspendCatching {
        val resp = api.getReadLists(libraryId = null, page = 0, size = 200)
        if (!resp.isSuccessful) return@runSuspendCatching emptyList()
        resp.body()?.content.orEmpty()
    }

    suspend fun getReadListBooks(readListId: String): Result<List<Book>> = runSuspendCatching {
        val resp = api.getReadListBooks(readListId, page = 0, size = 500)
        if (!resp.isSuccessful) return@runSuspendCatching emptyList()
        val serverUrl = scopedServerUrl().trimEnd('/')
        resp.body()?.content.orEmpty().mapNotNull { mapKomgaBook(it, it.libraryId, serverUrl) }
    }

    suspend fun getCollections(): Result<List<com.enve.komga.dto.KomgaCollectionDto>> = runSuspendCatching {
        val resp = api.getCollections(libraryId = null, page = 0, size = 200)
        if (!resp.isSuccessful) return@runSuspendCatching emptyList()
        resp.body()?.content.orEmpty()
    }

    suspend fun getCollectionSeries(collectionId: String): Result<List<com.enve.komga.dto.KomgaSeriesDto>> = runSuspendCatching {
        val resp = api.getCollectionSeries(collectionId, page = 0, size = 200)
        if (!resp.isSuccessful) return@runSuspendCatching emptyList()
        resp.body()?.content.orEmpty()
    }

    suspend fun getSeriesBooks(seriesId: String): Result<List<Book>> = runSuspendCatching {
        val resp = api.getSeriesBooks(seriesId, page = 0, size = 200, sort = listOf("metadata.numberSort,asc"))
        if (!resp.isSuccessful) return@runSuspendCatching emptyList()
        val serverUrl = scopedServerUrl().trimEnd('/')
        resp.body()?.content.orEmpty().mapNotNull { mapKomgaBook(it, it.libraryId, serverUrl) }
    }

    fun oauth2AuthorizationUrl(serverUrl: String, registrationId: String): String {
        val base = serverUrl.trimEnd('/')
        return "$base/oauth2/authorization/$registrationId"
    }

    suspend fun verifyOauthSession(serverUrl: String, cookieHeader: String): Result<String> = withContext(Dispatchers.IO) {
        runSuspendCatching {
            val base = serverUrl.trimEnd('/')
            val request = Request.Builder()
                .url("$base/api/v2/users/me")
                .header("Cookie", cookieHeader)
                .header("Accept", "application/json")
                .get()
                .build()
            plainHttpClient.newCall(request).execute().use { resp ->
                val body = resp.body?.string().orEmpty()
                if (!resp.isSuccessful) {
                    error("Komga session verification failed: HTTP ${resp.code}")
                }
                runCatching {
                    val json = jsonSerializer.parseToJsonElement(body).jsonObject
                    json["email"]?.jsonPrimitive?.contentOrNull
                        ?: json["username"]?.jsonPrimitive?.contentOrNull
                        ?: ""
                }.getOrDefault("")
            }
        }
    }

    suspend fun getEbookDownloadUrl(bookId: String): String? {
        val serverUrl = scopedServerUrl().takeIf { it.isNotBlank() } ?: return null
        return "${serverUrl.trimEnd('/')}/api/v1/books/$bookId/file"
    }

    suspend fun updateBookMetadata(book: Book, metadata: ProviderMetadataUpdate): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val body = jsonSerializer.encodeToString(metadata.toKomgaBookMetadataPatchJson())
                .toRequestBody("application/json".toMediaType())
            val response = api.updateBookMetadata(book.id, body)
            if (response.isSuccessful) {
                Result.success(Unit)
            } else {
                Result.failure(Exception("Komga metadata update failed: HTTP ${response.code()}"))
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> {
        return try {
            val url = getEbookDownloadUrl(book.id)
                ?: return Result.failure(Exception("Komga server URL is not configured"))
            Result.success(
                listOf(
                    AudioTrack(
                        index = 0,
                        fileName = book.title,
                        title = book.title,
                        durationMs = book.duration * 1000,
                        contentUrl = url,
                    )
                )
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun fetchEbookProgress(book: com.enve.core.data.model.Book): Result<com.enve.core.data.sync.SyncSnapshot?> {
        return try {
            val response = api.getBook(book.id)
            val dto = response.body() ?: return Result.success(null)
            val readProgress = dto.readProgress ?: return Result.success(null)
            if (readProgress.completed) {
                return Result.success(com.enve.core.data.sync.SyncSnapshot(percentage = 1f, source = "Komga"))
            }
            val totalPages = dto.media?.pagesCount?.takeIf { it > 0 } ?: return Result.success(null)
            val pct = readProgress.page.toFloat() / totalPages
            if (pct <= 0f) return Result.success(null)

            Result.success(
                com.enve.core.data.sync.SyncSnapshot(
                    percentage = pct,
                    locatorJson = "{\"page\":${readProgress.page}}",
                    source = "Komga",
                )
            )
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun syncEbookProgress(
        bookId: String,
        percentage: Float,
        page: Int? = null,
        pageCount: Int? = null,
    ): Result<Unit> {
        return try {
            val normalized = percentage.coerceIn(0f, 1f)
            val completed = normalized >= 0.99f
            val resolvedPageCount = pageCount?.takeIf { it > 0 }
                ?: api.getBook(bookId).body()?.media?.pagesCount?.takeIf { it > 0 }
                ?: 1
            val resolvedPage = page?.takeIf { it > 0 }
                ?: ceil(normalized * resolvedPageCount.toFloat()).toInt().coerceIn(1, resolvedPageCount)

            val response = api.updateReadProgress(
                bookId = bookId,
                request = if (completed) {
                    KomgaReadProgressUpdateDto(completed = true)
                } else {
                    KomgaReadProgressUpdateDto(page = resolvedPage, completed = false)
                }
            )
            if (response.isSuccessful) Result.success(Unit)
            else Result.failure(Exception("Komga read-progress sync failed: HTTP ${response.code()}"))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getSeries(): Result<List<com.enve.core.data.remote.dto.SeriesSummaryDto>> {
        return try {
            val serverUrl = scopedServerUrl().trimEnd('/')
            val merged = mutableListOf<com.enve.core.data.remote.dto.SeriesSummaryDto>()
            var page = 0
            val pageSize = 500
            while (true) {
                val response = api.getSeries(page = page, size = pageSize)
                if (!response.isSuccessful) break
                val body = response.body() ?: break
                merged += body.content.map {
                    com.enve.core.data.remote.dto.SeriesSummaryDto(
                        name = it.name,
                        bookCount = it.booksCount,
                        id = it.id,
                        coverUrl = "$serverUrl/api/v1/series/${it.id}/thumbnail",
                    )
                }
                val totalPages = body.totalPages ?: (page + 1)
                if (page + 1 >= totalPages || body.content.isEmpty()) break
                page++
            }
            Result.success(merged)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun getSeriesBooksByName(seriesName: String): Result<List<Book>> = runSuspendCatching {
        val searchResp = api.getSeries(search = seriesName, size = 50)
        if (!searchResp.isSuccessful) return@runSuspendCatching emptyList()
        val match = searchResp.body()?.content
            ?.firstOrNull { it.name.equals(seriesName, ignoreCase = true) }
            ?: return@runSuspendCatching emptyList()
        getSeriesBooks(match.id).getOrDefault(emptyList())
    }

    suspend fun getAuthors(): Result<List<com.enve.core.data.remote.dto.AuthorSummaryDto>> {

        return try {
            val response = api.getAuthors()
            if (!response.isSuccessful) return Result.success(emptyList())
            val authors = response.body().orEmpty().map {
                com.enve.core.data.remote.dto.AuthorSummaryDto(
                    id = it.name,
                    name = it.name,
                )
            }
            Result.success(authors)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }
}

internal fun ProviderMetadataUpdate.toKomgaBookMetadataPatchJson(): JsonObject {
    val titleValue = title.clean()
        ?: throw IllegalArgumentException("Komga title cannot be blank")
    val number = seriesNumber.clean()
    return buildJsonObject {
        put("title", JsonPrimitive(titleValue))
        putNullable("summary", description.clean())
        putNullable("number", number)
        if (number == null) {
            put("numberSort", JsonNull)
        } else {
            number.toFloatOrNull()?.let { put("numberSort", JsonPrimitive(it)) }
        }
        putNullable("releaseDate", publishedDate.toKomgaReleaseDate())
        put("authors", author.toKomgaAuthorsJson())
        putNullable("isbn", isbn13.clean())
    }
}

private fun JsonObjectBuilder.putNullable(
    key: String,
    value: String?,
) {
    put(key, value?.let { JsonPrimitive(it) } ?: JsonNull)
}

private fun String?.toKomgaAuthorsJson() = buildJsonArray {
    clean()
        ?.split(",")
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        .orEmpty()
        .forEach { name ->
            add(
                buildJsonObject {
                    put("name", JsonPrimitive(name))
                    put("role", JsonPrimitive("writer"))
                }
            )
        }
}

private fun String?.toKomgaReleaseDate(): String? {
    val value = clean() ?: return null
    val candidate = when {
        value.matches(Regex("""\d{4}""")) -> "$value-01-01"
        value.matches(Regex("""\d{4}-\d{2}""")) -> "$value-01"
        value.matches(Regex("""\d{4}-\d{2}-\d{2}""")) -> value
        else -> throw IllegalArgumentException("Komga release date must be YYYY, YYYY-MM, or YYYY-MM-DD")
    }
    return runCatching { LocalDate.parse(candidate).toString() }
        .getOrElse { throw IllegalArgumentException("Komga release date must be YYYY, YYYY-MM, or YYYY-MM-DD") }
}

private fun String?.clean(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
