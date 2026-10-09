package com.enve.engine.podcasts

import com.enve.core.data.model.Book
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.core.data.model.PodcastShow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

data class PodcastDirectoryShow(
    val id: String,
    val title: String,
    val author: String?,
    val feedUrl: String,
    val coverUrl: String?,
    val genres: List<String>,
    val episodeCount: Int,
)

@Serializable
data class PodcastSubscription(
    val feedUrl: String,
    val title: String,
    val author: String?,
    val coverUrl: String?,
    val subscribedAtMs: Long,
)

data class PodcastHome(
    val shows: List<PodcastShow>,
    val showBooks: List<Book>,
    val upNext: List<Book>,
    val newEpisodes: List<Book>,
    val unplayedCount: Int,
)

interface PodcastsFacade {
    val subscriptions: StateFlow<List<PodcastSubscription>>

    suspend fun show(show: Book): Result<PodcastShow>

    suspend fun feed(show: PodcastShow): Result<List<PodcastFeedEpisode>>

    suspend fun withFeedEpisodes(showBook: Book, show: PodcastShow, feed: List<PodcastFeedEpisode>): PodcastShow

    suspend fun home(): PodcastHome

    suspend fun topPodcasts(genreId: Int?): List<PodcastDirectoryShow>

    suspend fun searchPodcasts(query: String): List<PodcastDirectoryShow>

    suspend fun subscribe(show: PodcastDirectoryShow)

    suspend fun subscribeToFeed(feedUrl: String)

    suspend fun unsubscribe(feedUrl: String)
}
