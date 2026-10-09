package com.enve.wear.listening

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import kotlinx.serialization.json.*
import java.io.IOException
import java.util.concurrent.TimeUnit

class WatchRequestException(message: String) : IOException(message)

class WatchAbsClient(private val vault: CredentialVault) : WatchAudiobookProvider {
    override val source: WatchSource = WatchSource.AUDIOBOOKSHELF
    override val capabilities = WatchProviderCapabilities(progress = true)
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .connectTimeout(20, TimeUnit.SECONDS).readTimeout(45, TimeUnit.SECONDS).build()

    override suspend fun libraries(account: WatchAccount): List<WatchLibraryChoice> = withContext(Dispatchers.IO) {
        val data = get(account, "api/libraries")
        data["libraries"]?.jsonArray.orEmpty().map { it.jsonObject }.filter { it.string("mediaType") == "book" }
            .map { WatchLibraryChoice(it.string("id"), it.string("name")) }
    }

    override suspend fun books(account: WatchAccount, libraryId: String, page: Int): WatchBookPage = withContext(Dispatchers.IO) {
        val url = endpoint(account, "api/libraries/${segment(libraryId)}/items").newBuilder()
            .addQueryParameter("page", "$page").addQueryParameter("limit", "30")
            .addQueryParameter("sort", "media.metadata.title").build()
        val data = request(account, url).use(::parse)
        val items = data["results"]?.jsonArray.orEmpty().map { book(account, it.jsonObject) }.filter { it.durationMs > 0 }
        WatchBookPage(items, (page + 1) * 30 < (data["total"]?.jsonPrimitive?.intOrNull ?: 0))
    }

    override suspend fun download(account: WatchAccount, bookId: String): WatchBookDownload = withContext(Dispatchers.IO) {
        val data = request(account, endpoint(account, "api/items/${segment(bookId)}").newBuilder().addQueryParameter("expanded", "1").build()).use(::parse)
        val media = data["media"]?.jsonObject ?: throw WatchRequestException("Server returned no book audio.")
        val files = media["tracks"]?.jsonArray.orEmpty().map { it.jsonObject }.sortedBy { it["index"]?.jsonPrimitive?.intOrNull ?: 0 }
            .map { WatchAudioFile(it.string("contentUrl"), it.milliseconds("startOffset"), it.milliseconds("duration")) }
        if (files.isEmpty()) throw WatchRequestException("This book has no downloadable audio.")
        WatchBookDownload(book(account, data), files)
    }

    override fun audio(account: WatchAccount, path: String, offset: Long, etag: String?): Response {
        val base = account.server.toHttpUrl()
        val url = resolveAudioUrl(base, path)
        if (url.scheme != base.scheme || url.host != base.host || url.port != base.port || url.username.isNotEmpty() || url.password.isNotEmpty()) {
            throw WatchRequestException("Audio must come from the connected server.")
        }
        return request(account, url) {
            if (offset > 0 && etag != null) { header("Range", "bytes=$offset-"); header("If-Range", etag) }
        }
    }

    override suspend fun fetchProgress(account: WatchAccount, bookId: String): WatchRemoteProgress? = withContext(Dispatchers.IO) {
        val response = request(account, endpoint(account, "api/me/progress/${segment(bookId)}"))
        if (response.code == 404) {
            response.close()
            return@withContext null
        }
        response.use { result ->
            val data = parse(result)
            WatchRemoteProgress(
                positionMs = data.milliseconds("currentTime"),
                durationMs = data.milliseconds("duration"),
                updatedAt = maxOf(data.long("lastUpdate"), data.long("updatedAt")),
            )
        }
    }

    override suspend fun pushProgress(account: WatchAccount, book: WatchBook, positionMs: Long) = withContext(Dispatchers.IO) {
        val durationMs = book.durationMs.coerceAtLeast(1L)
        val body = buildJsonObject {
            put("currentTime", positionMs.coerceIn(0L, durationMs) / 1000.0)
            put("duration", durationMs / 1000.0)
        }
        request(account, endpoint(account, "api/me/progress/${segment(book.id)}")) {
            patch(body.toString().toRequestBody(JSON))
        }.use(::requireSuccess)
    }

    private fun get(account: WatchAccount, path: String): JsonObject = request(account, endpoint(account, path)).use(::parse)

    private fun request(account: WatchAccount, url: HttpUrl, configure: Request.Builder.() -> Unit = {}): Response {
        val active = vault.read(account.key) ?: throw WatchRequestException("Sign in to download this book.")
        fun send(session: WatchAccount) = client.newCall(Request.Builder().url(url).header("Authorization", "Bearer ${session.token}").apply(configure).build()).execute()
        val response = send(active)
        if (response.code != 401) return response
        response.close()
        val updated = synchronized(refreshLock) {
            val latest = vault.read(account.key) ?: throw WatchRequestException("Sign in again to download.")
            if (latest.token != active.token) latest else {
                val refresh = latest.refreshToken ?: throw WatchRequestException("Session expired. Sign in again; downloads still work.")
                val refreshRequest = Request.Builder().url(endpoint(latest, "auth/refresh"))
                    .header("x-refresh-token", refresh).post("{}".toRequestBody(JSON)).build()
                val user = client.newCall(refreshRequest).execute().use { parse(it)["user"]!!.jsonObject }
                val renewed = account(latest.server, user).copy(
                    userId = latest.userId,
                    refreshToken = user.string("refreshToken").ifBlank { latest.refreshToken },
                )
                if (!vault.updateIfCurrent(latest, renewed)) throw WatchRequestException("Account changed. Try the download again.")
                renewed
            }
        }
        return send(updated)
    }

    private fun book(account: WatchAccount, data: JsonObject): WatchBook {
        val media = data["media"]?.jsonObject ?: throw WatchRequestException("Server returned no book audio.")
        val metadata = media["metadata"]?.jsonObject ?: throw WatchRequestException("Server returned no book details.")
        return WatchBook(account.key, data.string("id"), metadata.string("title"), metadata.string("authorName"), media.milliseconds("duration"),
            media["chapters"]?.takeUnless { it is JsonNull }?.jsonArray.orEmpty().map { chapter ->
                chapter.jsonObject.let { WatchChapter(it.string("title"), it.milliseconds("start"), it.milliseconds("end")) }
            })
    }

    private fun account(server: String, user: JsonObject): WatchAccount {
        val token = user.string("accessToken").ifBlank { user.string("token") }
        if (token.isBlank() || user.string("id").isBlank()) throw WatchRequestException("Server did not return a session.")
        return WatchAccount(server, user.string("id"), user.string("username"), token, user.string("refreshToken").ifBlank { null })
    }

    private fun parse(response: Response): JsonObject {
        requireSuccess(response)
        return Json.parseToJsonElement(response.body?.string() ?: throw WatchRequestException("Empty server response.")).jsonObject
    }

    private fun requireSuccess(response: Response) {
        if (!response.isSuccessful) throw WatchRequestException(when (response.code) {
            401, 403 -> "Sign-in was rejected. Check your account."
            else -> "Server request failed (${response.code})."
        })
    }

    private fun endpoint(account: WatchAccount, path: String): HttpUrl = account.server.toHttpUrl().resolve(path)!!
    private fun segment(value: String): String = HttpUrl.Builder().scheme("https").host("localhost").addPathSegment(value).build().encodedPath.drop(1)

    companion object {
        private val JSON = "application/json".toMediaType()
        private val refreshLock = Any()
        fun resolveAudioUrl(base: HttpUrl, path: String): HttpUrl = base.resolve(
            if (path.startsWith("/api/")) path.drop(1) else path
        ) ?: throw WatchRequestException("Invalid audio address.")

        fun normalizeServer(value: String): HttpUrl {
            val url = (value.trim().trimEnd('/') + "/").toHttpUrl()
            require(url.username.isEmpty() && url.password.isEmpty() && url.query == null && url.fragment == null) { "Use a server address without credentials or a query." }
            return url
        }
    }
}

private fun JsonObject.string(key: String): String = this[key]?.jsonPrimitive?.contentOrNull.orEmpty()
private fun JsonObject.milliseconds(key: String): Long = kotlin.math.round((this[key]?.jsonPrimitive?.doubleOrNull ?: 0.0) * 1000).toLong().coerceAtLeast(0)
private fun JsonObject.long(key: String): Long = this[key]?.jsonPrimitive?.longOrNull ?: 0L
