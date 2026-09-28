package com.enve.app.hearth

import com.enve.app.data.podcasts.PodcastFeedClient
import com.enve.app.data.podcasts.feedOnlyEpisodes
import com.enve.app.data.podcasts.toFeedOnlyBook
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.PodcastFeedProgressStore
import com.enve.core.data.model.Book
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.core.data.model.PodcastShow
import com.enve.core.data.util.runSuspendCatching
import com.enve.engine.podcasts.PodcastsFacade
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PodcastsFacadeImpl @Inject constructor(
    private val repository: AggregatorRepository,
    private val feedClient: PodcastFeedClient,
    private val feedProgress: PodcastFeedProgressStore,
) : PodcastsFacade {
    override suspend fun show(show: Book): Result<PodcastShow> = repository.getPodcastShow(show)

    override suspend fun feed(show: PodcastShow): Result<List<PodcastFeedEpisode>> = runSuspendCatching {
        show.feedUrl?.let { feedClient.episodes(it) }.orEmpty()
    }

    override suspend fun withFeedEpisodes(showBook: Book, show: PodcastShow, feed: List<PodcastFeedEpisode>): PodcastShow {
        val progress = feedProgress.all()
        val feedOnly = feedOnlyEpisodes(show.storedFeedKeys, feed).map { episode ->
            val book = episode.toFeedOnlyBook(show, showBook)
            progress[book.uniqueKey]?.let { saved ->
                val duration = saved.durationSec.takeIf { it > 0L } ?: book.duration
                book.copy(
                    duration = duration,
                    currentTime = saved.positionSec,
                    readProgress = if (duration > 0L) (saved.positionSec.toFloat() / duration).coerceIn(0f, 1f) else 0f,
                    isFinished = saved.isFinished,
                    lastReadTime = saved.updatedAtMs,
                )
            } ?: book
        }
        return show.copy(episodes = show.episodes + feedOnly)
    }
}
