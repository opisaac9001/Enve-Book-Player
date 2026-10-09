package com.enve.wear.listening

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.time.Instant
import java.time.OffsetDateTime
import java.util.concurrent.TimeUnit

class WatchGrimmoryClient(private val vault: CredentialVault) : WatchAudiobookProvider {
    override val source = WatchSource.GRIMMORY
    override val capabilities = WatchProviderCapabilities(progress = true)
    private val client = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(45, TimeUnit.SECONDS)
        .build()

    override suspend fun libraries(account: WatchAccount): List<WatchLibraryChoice> = withContext(Dispatchers.IO) {
        get(account, "api/v1/app/libraries").jsonArray.map { library ->
            library.jsonObject.let { WatchLibraryChoice(it.gString("id"), it.gString("name")) }
        }
    }

    override suspend fun books(account: WatchAccount, libraryId: String, page: Int): WatchBookPage = withContext(Dispatchers.IO) {
        val url = endpoint(account, "api/v1/app/books").newBuilder()
            .addQueryParameter("libraryId", libraryId)
            .addQueryParameter("page", page.toString())
            .addQueryParameter("size", "30")
            .addQueryParameter("sort", "addedOn")
            .addQueryParameter("dir", "desc")
            .build()
        val data = request(account, url).use(::parse).jsonObject
        val books = data["content"]?.jsonArray.orEmpty()
            .map { it.jsonObject }
            .filter { it.hasAudio() }
            .map { summary ->
                WatchBook(
                    account = account.key,
                    id = summary.gString("id"),
                    title = summary.gString("title"),
                    author = summary["authors"]?.jsonArray.orEmpty().joinToString(", ") { it.jsonPrimitive.content },
                )
            }
        WatchBookPage(books, data.gBoolean("hasNext"))
    }

    override suspend fun download(account: WatchAccount, bookId: String): WatchBookDownload = withContext(Dispatchers.IO) {
        val info = get(account, "api/v1/audiobooks/${segment(bookId)}/info").jsonObject
        var runningStart = 0L
        val tracks = info["tracks"]?.jsonArray.orEmpty().mapIndexed { position, element ->
            val track = element.jsonObject
            val index = track.gInt("index", position)
            val duration = track.gLongOrNull("durationMs") ?: 0L
            val start = track.gLongOrNull("cumulativeStartMs") ?: runningStart
            runningStart = start + duration
            WatchAudioFile(
                url = "api/v1/audiobooks/${segment(bookId)}/track/$index/stream",
                startMs = start,
                durationMs = duration,
            )
        }
        val duration = info.gLong("durationMs").takeIf { it > 0L }
            ?: tracks.maxOfOrNull { it.startMs + it.durationMs }
            ?: 0L
        val files = tracks.ifEmpty {
            listOf(WatchAudioFile("api/v1/audiobooks/${segment(bookId)}/stream", 0L, duration))
        }
        val chapters = info["chapters"]?.jsonArray.orEmpty().mapIndexed { position, element ->
            val chapter = element.jsonObject
            WatchChapter(
                title = chapter.gString("title").ifBlank { "Chapter ${position + 1}" },
                startMs = chapter.gLong("startTimeMs"),
                endMs = chapter.gLong("endTimeMs"),
            )
        }
        val book = WatchBook(
            account = account.key,
            id = bookId,
            title = info.gString("title").ifBlank { "Audiobook" },
            author = info.gString("author"),
            durationMs = duration,
            chapters = chapters,
        )
        WatchBookDownload(book, files)
    }

    override fun audio(account: WatchAccount, path: String, offset: Long, etag: String?): Response {
        val base = account.server.toHttpUrl()
        val url = base.resolve(path) ?: throw WatchRequestException("Invalid audio address.")
        if (url.scheme != base.scheme || url.host != base.host || url.port != base.port || url.username.isNotEmpty() || url.password.isNotEmpty()) {
            throw WatchRequestException("Audio must come from the connected server.")
        }
        return request(account, url) {
            if (offset > 0 && etag != null) {
                header("Range", "bytes=$offset-")
                header("If-Range", etag)
            }
        }
    }

    override suspend fun fetchProgress(account: WatchAccount, bookId: String): WatchRemoteProgress? = withContext(Dispatchers.IO) {
        val response = request(account, endpoint(account, "api/v1/app/books/${segment(bookId)}/progress"))
        if (response.code == 404) {
            response.close()
            return@withContext null
        }
        val progress = response.use(::parse).jsonObject["audiobookProgress"]?.takeUnless { it is JsonNull }?.jsonObject
            ?: return@withContext null
        val info = get(account, "api/v1/audiobooks/${segment(bookId)}/info").jsonObject
        var runningStart = 0L
        val starts = info["tracks"]?.jsonArray.orEmpty().associate { element ->
            val track = element.jsonObject
            val start = track.gLongOrNull("cumulativeStartMs") ?: runningStart
            runningStart = start + (track.gLongOrNull("durationMs") ?: 0L)
            track.gInt("index", 0) to start
        }
        val trackIndex = progress.gInt("trackIndex", 0)
        val localPosition = progress.gLongOrNull("positionMs") ?: return@withContext null
        val trackStart = if (trackIndex > 0) starts[trackIndex] ?: return@withContext null else 0L
        val position = localPosition + trackStart
        WatchRemoteProgress(position, info.gLong("durationMs"), progress.gEpochMillis("updatedAt"))
    }

    override suspend fun pushProgress(account: WatchAccount, book: WatchBook, positionMs: Long) = withContext(Dispatchers.IO) {
        val info = get(account, "api/v1/audiobooks/${segment(book.id)}/info").jsonObject
        val bookFileId = info.gString("bookFileId").toLongOrNull()
            ?: throw WatchRequestException("Server did not return an audiobook file ID.")
        val starts = info["tracks"]?.jsonArray.orEmpty().mapIndexed { position, element ->
            val track = element.jsonObject
            track.gInt("index", position) to track.gLong("cumulativeStartMs")
        }
        val global = positionMs.coerceAtLeast(0L)
        val selected = starts.filter { it.second <= global }.maxByOrNull { it.second }
        val body = buildJsonObject {
            put("bookId", book.id.toLongOrNull() ?: throw WatchRequestException("Grimmory returned an invalid book ID."))
            put("fileProgress", buildJsonObject {
                put("bookFileId", bookFileId)
                put("positionData", (global - (selected?.second ?: 0L)).toString())
                selected?.let { put("positionHref", it.first.toString()) }
                put("progressPercent", global.toDouble() / book.durationMs.coerceAtLeast(1L) * 100.0)
            })
        }
        request(account, endpoint(account, "api/v1/books/progress")) {
            post(body.toString().toRequestBody(JSON))
        }.use(::requireSuccess)
    }

    private fun get(account: WatchAccount, path: String) = request(account, endpoint(account, path)).use(::parse)

    private fun request(account: WatchAccount, url: HttpUrl, configure: Request.Builder.() -> Unit = {}): Response {
        val active = vault.read(account.key) ?: throw WatchRequestException("Sign in to this account again.")
        fun send(session: WatchAccount) = client.newCall(Request.Builder()
            .url(url)
            .header("Authorization", "Bearer ${session.token}")
            .apply(configure)
            .build()).execute()
        val response = send(active)
        if (response.code != 401) return response
        response.close()
        val updated = synchronized(refreshLock) {
            val latest = vault.read(account.key) ?: throw WatchRequestException("Sign in to this account again.")
            if (latest.token != active.token) latest else {
                val refresh = latest.refreshToken ?: throw WatchRequestException("Session expired. Sign in again; downloads still work.")
                val body = buildJsonObject { put("refreshToken", refresh) }
                val renewedJson = client.newCall(Request.Builder()
                    .url(endpoint(latest, "api/v1/auth/refresh"))
                    .post(body.toString().toRequestBody(JSON))
                    .build()).execute().use(::parse).jsonObject
                val renewed = latest.copy(
                    token = renewedJson.gString("accessToken"),
                    refreshToken = renewedJson.gString("refreshToken").ifBlank { latest.refreshToken },
                )
                if (renewed.token.isBlank() || !vault.updateIfCurrent(latest, renewed)) {
                    throw WatchRequestException("Account changed. Try again.")
                }
                renewed
            }
        }
        return send(updated)
    }

    private fun parse(response: Response): kotlinx.serialization.json.JsonElement {
        requireSuccess(response)
        return Json.parseToJsonElement(response.body?.string() ?: throw WatchRequestException("Empty server response."))
    }

    private fun requireSuccess(response: Response) {
        if (!response.isSuccessful) throw WatchRequestException(when (response.code) {
            401, 403 -> "Sign-in was rejected. Check your account."
            else -> "Server request failed (${response.code})."
        })
    }

    private fun endpoint(account: WatchAccount, path: String) = account.server.toHttpUrl().resolve(path)!!
    private fun segment(value: String) = HttpUrl.Builder().scheme("https").host("localhost").addPathSegment(value).build().encodedPath.drop(1)

    companion object {
        private val JSON = "application/json".toMediaType()
        private val refreshLock = Any()

        fun normalizeServer(value: String): HttpUrl {
            val url = (value.trim().trimEnd('/') + "/").toHttpUrl()
            require(url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null) {
                "Use a server address without credentials or a query."
            }
            return url
        }
    }
}

private fun JsonObject.hasAudio(): Boolean {
    val types = buildList {
        add(gString("primaryFileType"))
        addAll(this@hasAudio["fileTypes"]?.jsonArray.orEmpty().map { it.jsonPrimitive.content })
    }
    return types.any { it.uppercase() in setOf("AUDIOBOOK", "MP3", "M4A", "M4B", "FLAC", "OGG", "OPUS", "WAV") }
}

private fun JsonObject.gString(key: String) = this[key]?.jsonPrimitive?.contentOrNull.orEmpty()
private fun JsonObject.gLong(key: String) = gLongOrNull(key) ?: 0L
private fun JsonObject.gLongOrNull(key: String) = this[key]?.jsonPrimitive?.longOrNull
    ?: this[key]?.jsonPrimitive?.doubleOrNull?.toLong()
private fun JsonObject.gInt(key: String, fallback: Int) = gLongOrNull(key)?.toInt() ?: fallback
private fun JsonObject.gBoolean(key: String) = (this[key] as? JsonPrimitive)?.content?.toBooleanStrictOrNull() ?: false
private fun JsonObject.gEpochMillis(key: String): Long {
    val primitive = this[key]?.jsonPrimitive ?: return 0L
    primitive.longOrNull?.let { return it }
    val value = primitive.contentOrNull ?: return 0L
    return runCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }
        .recoverCatching { Instant.parse(value).toEpochMilli() }
        .getOrDefault(0L)
}
