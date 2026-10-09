package com.enve.app.hearth

import com.enve.app.data.podcasts.PodcastFeedClient
import com.enve.app.data.podcasts.PodcastDirectoryClient
import com.enve.app.data.podcasts.PodcastSubscriptionStore
import com.enve.app.data.podcasts.feedOnlyEpisodes
import com.enve.app.data.podcasts.toFeedOnlyBook
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.PodcastFeedProgressStore
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.core.data.model.PodcastShow
import com.enve.core.data.util.runSuspendCatching
import com.enve.engine.podcasts.PodcastsFacade
import com.enve.engine.podcasts.PodcastDirectoryShow
import com.enve.engine.podcasts.PodcastHome
import com.enve.engine.podcasts.PodcastSubscription
import com.enve.engine.library.LibraryFacade
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PodcastsFacadeImpl @Inject constructor(
    private val repository: AggregatorRepository,
    private val feedClient: PodcastFeedClient,
    private val feedProgress: PodcastFeedProgressStore,
    private val subscriptionsStore: PodcastSubscriptionStore,
    private val directory: PodcastDirectoryClient,
    private val library: LibraryFacade,
) : PodcastsFacade {
    override val subscriptions: StateFlow<List<PodcastSubscription>> = subscriptionsStore.subscriptions

    override suspend fun show(show: Book): Result<PodcastShow> = if (show.source == BookSource.LOCAL) {
        runSuspendCatching { feedClient.show(
            if (show.id.startsWith("https://") || show.id.startsWith("http://")) show.id else subscriptions.value.first {
                UUID.nameUUIDFromBytes(it.feedUrl.toByteArray()).toString() == show.id
            }.feedUrl,
        ).let { directoryShow ->
            PodcastShow(
                id = show.id,
                title = directoryShow.title,
                author = directoryShow.author,
                description = null,
                coverUrl = directoryShow.coverUrl,
                genres = directoryShow.genres,
                episodes = emptyList(),
                feedUrl = directoryShow.feedUrl,
                storedFeedKeys = emptyList(),
            )
        } }
    } else repository.getPodcastShow(show)

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

    override suspend fun home(): PodcastHome {
        val serverBooks = library.allBooks.first().filter {
            it.mediaType == AppMediaType.PODCAST && it.episodeId == null
        }
        val shows = mutableListOf<PodcastShow>()
        val showBooks = mutableListOf<Book>()
        for (book in serverBooks) {
            val stored = show(book).getOrNull() ?: continue
            val episodes = feed(stored).getOrNull()
            shows += if (episodes == null) stored else withFeedEpisodes(book, stored, episodes)
            showBooks += book
        }
        val serverFeeds = shows.mapNotNull(PodcastShow::feedUrl).toSet()
        for (subscription in subscriptions.value) {
            if (subscription.feedUrl in serverFeeds) continue
            val show = PodcastShow(
                id = UUID.nameUUIDFromBytes(subscription.feedUrl.toByteArray()).toString(),
                title = subscription.title,
                author = subscription.author,
                description = null,
                coverUrl = subscription.coverUrl,
                genres = emptyList(),
                episodes = emptyList(),
                feedUrl = subscription.feedUrl,
                storedFeedKeys = emptyList(),
            )
            val showBook = Book(
                id = show.id,
                title = show.title,
                author = show.author,
                coverUrl = show.coverUrl,
                source = BookSource.LOCAL,
                mediaType = AppMediaType.PODCAST,
                podcastLibraryItemId = show.id,
                podcastName = show.title,
            )
            try {
                shows += withFeedEpisodes(showBook, show, feedClient.episodes(subscription.feedUrl))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                shows += show
            }
            showBooks += showBook
        }
        val episodes = shows.flatMap(PodcastShow::episodes)
        val inProgress = episodes.filter {
            !it.isFinished && (it.currentTime > 0L || it.readProgress > 0f)
        }.sortedByDescending(Book::lastReadTime)
        val unplayed = episodes.filter {
            !it.isFinished && it.currentTime == 0L && it.readProgress == 0f
        }.sortedByDescending(Book::addedOn)
        return PodcastHome(
            shows = shows,
            showBooks = showBooks,
            upNext = inProgress,
            newEpisodes = unplayed.distinctBy { it.podcastLibraryItemId ?: it.podcastName }.take(8),
            unplayedCount = unplayed.size,
        )
    }

    override suspend fun topPodcasts(genreId: Int?): List<PodcastDirectoryShow> = directory.top(genreId)

    override suspend fun searchPodcasts(query: String): List<PodcastDirectoryShow> = directory.search(query)

    override suspend fun subscribe(show: PodcastDirectoryShow) {
        subscriptionsStore.save(
            PodcastSubscription(show.feedUrl, show.title, show.author, show.coverUrl, System.currentTimeMillis()),
        )
    }

    override suspend fun subscribeToFeed(feedUrl: String) {
        val show = feedClient.show(feedUrl)
        subscribe(show)
    }

    override suspend fun unsubscribe(feedUrl: String) {
        subscriptionsStore.remove(feedUrl)
    }
}
