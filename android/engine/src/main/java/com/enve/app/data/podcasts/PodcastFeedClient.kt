package com.enve.app.data.podcasts

import com.enve.app.di.PublicMetadataHttpClient
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.engine.podcasts.PodcastDirectoryShow
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.jsoup.Jsoup
import org.jsoup.parser.Parser
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PodcastFeedClient @Inject constructor(
    @PublicMetadataHttpClient publicClient: OkHttpClient,
) {
    private val httpClient = publicClient.newBuilder()
        .addInterceptor { chain ->
            chain.proceed(
                chain.request().newBuilder()
                    .header("Accept", "application/rss+xml, application/xml;q=0.9, text/xml;q=0.8, */*;q=0.5")
                    .build(),
            )
        }
        .build()

    suspend fun episodes(feedUrl: String): List<PodcastFeedEpisode> = withContext(Dispatchers.IO) {
        httpClient.newCall(Request.Builder().url(feedUrl).build()).execute().use { response ->
            if (!response.isSuccessful) error("Podcast feed request failed: HTTP ${response.code}")
            checkNotNull(response.body).byteStream().use(PodcastFeedParser::parse)
        }
    }

    suspend fun show(feedUrl: String): PodcastDirectoryShow = withContext(Dispatchers.IO) {
        httpClient.newCall(Request.Builder().url(feedUrl.trim()).build()).execute().use { response ->
            if (!response.isSuccessful) error("Podcast feed request failed: HTTP ${response.code}")
            val document = Jsoup.parse(response.body?.string() ?: error("Podcast feed is empty"), "", Parser.xmlParser())
            val channel = document.getElementsByTag("channel").firstOrNull() ?: error("This URL is not a podcast feed")
            val title = channel.getElementsByTag("title").firstOrNull()?.text()?.takeIf(String::isNotBlank)
                ?: error("Podcast feed has no title")
            val cover = channel.getElementsByTag("itunes:image").firstOrNull()?.attr("href")?.takeIf(String::isNotBlank)
                ?: channel.getElementsByTag("image").firstOrNull()?.getElementsByTag("url")?.firstOrNull()?.text()
            PodcastDirectoryShow(
                id = feedUrl,
                title = title,
                author = channel.getElementsByTag("itunes:author").firstOrNull()?.text(),
                feedUrl = feedUrl,
                coverUrl = cover,
                genres = emptyList(),
                episodeCount = channel.getElementsByTag("item").size,
            )
        }
    }
}
