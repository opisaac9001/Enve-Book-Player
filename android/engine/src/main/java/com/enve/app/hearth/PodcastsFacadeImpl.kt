package com.enve.app.hearth

import com.enve.app.data.NetworkStateProvider
import com.enve.app.data.offline.OfflineDownloadManager
import com.enve.app.data.offline.offlineDownloadKey
import com.enve.app.data.podcasts.PodcastFeedClient
import com.enve.app.data.podcasts.PodcastDirectoryClient
import com.enve.app.data.podcasts.PodcastOpmlParser
import com.enve.app.data.podcasts.PodcastOpmlWriter
import com.enve.app.data.podcasts.PodcastRoutineFeed
import com.enve.app.data.podcasts.PodcastRoutineSelector
import com.enve.app.data.podcasts.PodcastRoutineStore
import com.enve.app.data.podcasts.PodcastSubscriptionStore
import com.enve.app.data.podcasts.applyImportedPodcastStates
import com.enve.app.data.podcasts.matchPodcastFeed
import com.enve.app.data.podcasts.podcastExportPlan
import com.enve.app.data.podcasts.podcastImportPreview
import com.enve.app.data.podcasts.toFeedOnlyBook
import com.enve.app.data.repository.AggregatorRepository
import com.enve.core.data.local.PodcastFeedProgress
import com.enve.core.data.local.PodcastFeedProgressStore
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.core.data.model.PodcastShow
import com.enve.core.data.util.runSuspendCatching
import com.enve.engine.podcasts.PodcastsFacade
import com.enve.engine.podcasts.PodcastDirectoryShow
import com.enve.engine.podcasts.PodcastExportResult
import com.enve.engine.podcasts.PodcastFeedUrl
import com.enve.engine.podcasts.PodcastHome
import com.enve.engine.podcasts.PodcastImportPreview
import com.enve.engine.podcasts.PodcastImportReport
import com.enve.engine.podcasts.PodcastRoutine
import com.enve.engine.podcasts.PodcastRoutineRule
import com.enve.engine.podcasts.PodcastRoutineRuleOutcome
import com.enve.engine.podcasts.PodcastRoutineRun
import com.enve.engine.podcasts.PodcastSubscription
import com.enve.engine.library.LibraryFacade
import com.enve.engine.playback.PlaybackFacade
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap
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
    private val routineStore: PodcastRoutineStore,
    private val playback: PlaybackFacade,
    private val downloads: OfflineDownloadManager,
    private val network: NetworkStateProvider,
) : PodcastsFacade {
    private val loadedEpisodes = ConcurrentHashMap<String, List<Book>>()

    override val subscriptions: StateFlow<List<PodcastSubscription>> = subscriptionsStore.subscriptions

    override suspend fun show(show: Book): Result<PodcastShow> = if (show.source == BookSource.LOCAL) {
        runSuspendCatching { feedClient.show(
            if (show.id.startsWith("https://") || show.id.startsWith("http://")) show.id else subscriptions.value.first {
                PodcastFeedUrl.showId(it.feedUrl) == show.id
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
        val match = matchPodcastFeed(show.storedFeedKeys, feed)
        val stored = show.episodes.map { episode ->
            val shareUrl = match.linksByStoredId[episode.episodeId]
            if (shareUrl == null) episode else episode.copy(podcastShareUrl = shareUrl)
        }
        val feedOnly = match.feedOnly.map { episode ->
            val book = episode.toFeedOnlyBook(show, showBook)
            progress[book.uniqueKey]?.let(book::withFeedProgress) ?: book
        }
        return show.copy(episodes = stored + feedOnly)
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
            val (show, showBook) = subscriptionShow(subscription)
            try {
                shows += loadSubscriptionEpisodes(subscription, show, showBook)
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

    override val routines: StateFlow<List<PodcastRoutine>> = routineStore.routines

    override fun createRoutine(name: String, rules: List<PodcastRoutineRule>): PodcastRoutine? = routineStore.create(name, rules)

    override fun saveRoutine(routine: PodcastRoutine) = routineStore.save(routine)

    override fun deleteRoutine(id: String) = routineStore.delete(id)

    override fun moveRoutine(id: String, delta: Int) = routineStore.move(id, delta)

    override suspend fun runRoutine(routine: PodcastRoutine): PodcastRoutineRun {
        val online = network.hasActiveNetwork()
        val subscribed = subscriptions.value.associateBy { PodcastFeedUrl.key(it.feedUrl) }
        val ruleKeys = routine.rules.map { PodcastFeedUrl.key(it.feedUrl) }.distinct().filter(subscribed::containsKey)
        var downloaded: List<Book>? = null
        val feeds = ruleKeys.associateWith { key ->
            val subscription = subscribed.getValue(key)
            val cached = loadedEpisodes[key]
            if (online) {
                try {
                    PodcastRoutineFeed.Fresh(subscriptionEpisodes(subscription))
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    cached?.let(PodcastRoutineFeed::Stale)
                        ?: downloadedEpisodes(subscription, downloaded ?: downloadedPodcastBooks().also { downloaded = it })
                            .takeIf(List<Book>::isNotEmpty)?.let(PodcastRoutineFeed::DownloadedOnly)
                        ?: PodcastRoutineFeed.Failed
                }
            } else {
                val offline = downloadedEpisodes(subscription, downloaded ?: downloadedPodcastBooks().also { downloaded = it })
                when {
                    cached != null -> PodcastRoutineFeed.Stale(cached + offline)
                    offline.isNotEmpty() -> PodcastRoutineFeed.DownloadedOnly(offline)
                    else -> PodcastRoutineFeed.Failed
                }
            }
        }
        val outcomes = PodcastRoutineSelector.resolve(routine.rules, feeds, subscribed.keys, !online) {
            downloads.isDownloaded(it.offlineDownloadKey)
        }
        val queue = outcomes.flatMap(PodcastRoutineRuleOutcome::episodes)
        if (queue.isNotEmpty()) playback.playAll(queue, "podcast-routine:${routine.id}")
        return PodcastRoutineRun(routine.id, routine.name, outcomes, queue.size, wasOffline = !online)
    }

    override suspend fun previewPodcastImport(opml: ByteArray): PodcastImportPreview = withContext(Dispatchers.Default) {
        podcastImportPreview(PodcastOpmlParser.parse(opml), subscriptions.value.map(PodcastSubscription::feedUrl))
    }

    override suspend fun importPodcasts(
        preview: PodcastImportPreview,
        selection: Set<String>,
        onProgress: (completed: Int, total: Int) -> Unit,
    ): PodcastImportReport {
        val selected = preview.candidates.filter { it.key in selection }
        val existingKeys = subscriptions.value.mapTo(mutableSetOf()) { PodcastFeedUrl.key(it.feedUrl) }
        val added = selected.filterNot { it.key in existingKeys }
        val subscribedAt = System.currentTimeMillis()
        var report = PodcastImportReport(
            subscribed = subscriptionsStore.saveAll(added.map { PodcastSubscription(it.feedUrl, it.title, null, null, subscribedAt) }),
            alreadySubscribed = selected.size - added.size,
        )
        val subscribed = subscriptions.value.associateBy { PodcastFeedUrl.key(it.feedUrl) }
        val withStates = selected.filter { it.listeningStateCount > 0 }
        for ((index, candidate) in withStates.withIndex()) {
            onProgress(index, withStates.size)
            currentCoroutineContext().ensureActive()
            val subscription = subscribed[candidate.key]
                ?: PodcastSubscription(candidate.feedUrl, candidate.title, null, null, subscribedAt)
            val episodes = loadedEpisodes[candidate.key] ?: try {
                subscriptionEpisodes(subscription)
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                report = report.copy(
                    unloadedFeeds = report.unloadedFeeds + candidate.title,
                    unloadedStates = report.unloadedStates + candidate.listeningStateCount,
                )
                continue
            }
            val existingProgress = feedProgress.all()
            val application = applyImportedPodcastStates(candidate.episodes, episodes, existingProgress, System.currentTimeMillis())
            val applied = feedProgress.saveImported(existingProgress, application.writes)
            report = report.copy(
                applied = report.applied + applied,
                keptExisting = report.keptExisting + application.keptExisting + application.applied - applied,
                alreadyFinished = report.alreadyFinished + application.alreadyFinished,
                unmatched = report.unmatched + application.unmatched,
            )
            if (application.writes.isNotEmpty()) loadedEpisodes.remove(candidate.key)
        }
        onProgress(withStates.size, withStates.size)
        return report
    }

    override suspend fun exportPodcasts(
        includePrivateFeeds: Boolean,
        includeProgress: Boolean,
        onProgress: (completed: Int, total: Int) -> Unit,
    ): PodcastExportResult {
        val current = subscriptions.value
        val episodesByKey = HashMap<String, List<Book>>()
        val withoutProgress = mutableListOf<String>()
        if (includeProgress) {
            val outline = podcastExportPlan(current, emptyMap(), includePrivateFeeds).feeds
            val bySubscriptionKey = current.associateBy { PodcastFeedUrl.key(it.feedUrl) }
            val progress = feedProgress.all()
            for ((index, feed) in outline.withIndex()) {
                onProgress(index, outline.size)
                currentCoroutineContext().ensureActive()
                val key = PodcastFeedUrl.key(feed.feedUrl)
                val episodes = loadedEpisodes[key]?.map { book -> progress[book.uniqueKey]?.let(book::withFeedProgress) ?: book } ?: try {
                    subscriptionEpisodes(bySubscriptionKey.getValue(key))
                } catch (e: CancellationException) {
                    throw e
                } catch (_: Exception) {
                    withoutProgress += feed.title
                    continue
                }
                episodesByKey[key] = episodes
            }
            onProgress(outline.size, outline.size)
        }
        val plan = podcastExportPlan(current, episodesByKey, includePrivateFeeds)
        return PodcastExportResult(
            opml = PodcastOpmlWriter.write(plan.feeds, System.currentTimeMillis()),
            feedCount = plan.feeds.size,
            episodeStateCount = plan.feeds.sumOf { it.episodes.size },
            exclusions = plan.exclusions,
            duplicateCount = plan.duplicateCount,
            feedsWithoutProgress = withoutProgress,
        )
    }

    private suspend fun downloadedPodcastBooks(): List<Book> {
        val progress = feedProgress.all()
        return library.downloaded.first()
            .filter { it.mediaType == AppMediaType.PODCAST && it.episodeId != null && downloads.isDownloaded(it.offlineDownloadKey) }
            .map { book -> progress[book.uniqueKey]?.let(book::withFeedProgress) ?: book }
    }

    private fun downloadedEpisodes(subscription: PodcastSubscription, downloaded: List<Book>): List<Book> {
        val showId = PodcastFeedUrl.showId(subscription.feedUrl)
        return downloaded.filter { it.podcastLibraryItemId == showId }
    }

    private suspend fun subscriptionEpisodes(subscription: PodcastSubscription): List<Book> {
        val (show, showBook) = subscriptionShow(subscription)
        return loadSubscriptionEpisodes(subscription, show, showBook).episodes
    }

    private suspend fun loadSubscriptionEpisodes(subscription: PodcastSubscription, show: PodcastShow, showBook: Book): PodcastShow =
        withFeedEpisodes(showBook, show, feedClient.episodes(subscription.feedUrl)).also {
            loadedEpisodes[PodcastFeedUrl.key(subscription.feedUrl)] = it.episodes
        }

    private fun subscriptionShow(subscription: PodcastSubscription): Pair<PodcastShow, Book> {
        val show = PodcastShow(
            id = PodcastFeedUrl.showId(subscription.feedUrl),
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
        return show to showBook
    }
}

private fun Book.withFeedProgress(saved: PodcastFeedProgress): Book {
    val total = saved.durationSec.takeIf { it > 0L } ?: duration
    return copy(
        duration = total,
        currentTime = saved.positionSec,
        readProgress = if (total > 0L) (saved.positionSec.toFloat() / total).coerceIn(0f, 1f) else 0f,
        isFinished = saved.isFinished,
        lastReadTime = saved.updatedAtMs,
    )
}
