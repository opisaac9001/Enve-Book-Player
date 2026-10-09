package com.enve.app.data.podcasts

import com.enve.app.di.PublicMetadataHttpClient
import com.enve.engine.podcasts.PodcastDirectoryShow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PodcastDirectoryClient @Inject constructor(
    @PublicMetadataHttpClient private val client: OkHttpClient,
) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun search(query: String): List<PodcastDirectoryShow> {
        if (query.isBlank()) return emptyList()
        val url = "https://itunes.apple.com/search".toHttpUrl().newBuilder()
            .addQueryParameter("media", "podcast")
            .addQueryParameter("entity", "podcast")
            .addQueryParameter("term", query.trim())
            .addQueryParameter("limit", "25")
            .build().toString()
        return results(request(url))
    }

    suspend fun top(genreId: Int?): List<PodcastDirectoryShow> {
        val country = Locale.getDefault().country.ifBlank { "US" }.lowercase(Locale.ROOT)
        val genre = genreId?.let { "/genre=$it" }.orEmpty()
        val chart = request("https://itunes.apple.com/$country/rss/toppodcasts/limit=40$genre/json")
        val entries = chart["feed"] as? JsonObject ?: return emptyList()
        val ids = (entries["entry"] as? JsonArray).orEmpty().mapNotNull { element ->
            ((element as? JsonObject)?.get("id") as? JsonObject)
                ?.get("attributes")?.let { it as? JsonObject }
                ?.string("im:id")
        }
        if (ids.isEmpty()) return emptyList()
        val lookup = "https://itunes.apple.com/lookup".toHttpUrl().newBuilder()
            .addQueryParameter("id", ids.joinToString(","))
            .addQueryParameter("entity", "podcast")
            .addQueryParameter("country", country)
            .build().toString()
        val byId = results(request(lookup)).associateBy { it.id }
        return ids.mapNotNull(byId::get)
    }

    private suspend fun request(url: String): JsonObject = withContext(Dispatchers.IO) {
        client.newCall(Request.Builder().url(url).build()).execute().use { response ->
            if (!response.isSuccessful) error("Podcast directory request failed: HTTP ${response.code}")
            val body = response.body?.string() ?: error("Podcast directory returned an empty response")
            json.parseToJsonElement(body) as JsonObject
        }
    }

    private fun results(response: JsonObject): List<PodcastDirectoryShow> =
        (response["results"] as? JsonArray).orEmpty().mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val feedUrl = item.string("feedUrl")?.takeIf(String::isNotBlank) ?: return@mapNotNull null
            PodcastDirectoryShow(
                id = item["collectionId"]?.let { (it as? JsonPrimitive)?.contentOrNull }
                    ?: item["trackId"]?.let { (it as? JsonPrimitive)?.contentOrNull }
                    ?: feedUrl,
                title = item.string("collectionName") ?: item.string("trackName") ?: "Unknown",
                author = item.string("artistName"),
                feedUrl = feedUrl,
                coverUrl = item.string("artworkUrl600") ?: item.string("artworkUrl100"),
                genres = (item["genres"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.contentOrNull },
                episodeCount = (item["trackCount"] as? JsonPrimitive)?.intOrNull ?: 0,
            )
        }

    private fun JsonObject.string(key: String): String? = (get(key) as? JsonPrimitive)?.contentOrNull
}
