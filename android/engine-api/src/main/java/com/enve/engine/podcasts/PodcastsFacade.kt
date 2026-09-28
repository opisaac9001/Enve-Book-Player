package com.enve.engine.podcasts

import com.enve.core.data.model.Book
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.core.data.model.PodcastShow

interface PodcastsFacade {
    suspend fun show(show: Book): Result<PodcastShow>

    suspend fun feed(show: PodcastShow): Result<List<PodcastFeedEpisode>>

    suspend fun withFeedEpisodes(showBook: Book, show: PodcastShow, feed: List<PodcastFeedEpisode>): PodcastShow
}
