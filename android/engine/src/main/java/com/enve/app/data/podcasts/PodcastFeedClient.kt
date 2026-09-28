package com.enve.app.data.podcasts

import com.enve.app.di.PublicMetadataHttpClient
import com.enve.core.data.model.PodcastFeedEpisode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
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
}
