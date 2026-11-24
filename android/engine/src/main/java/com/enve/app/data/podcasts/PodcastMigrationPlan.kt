package com.enve.app.data.podcasts

import com.enve.core.data.local.PodcastFeedProgress
import com.enve.core.data.model.Book
import com.enve.engine.podcasts.PodcastExportExclusion
import com.enve.engine.podcasts.PodcastFeedUrl
import com.enve.engine.podcasts.PodcastImportCandidate
import com.enve.engine.podcasts.PodcastImportPreview
import com.enve.engine.podcasts.PodcastOpmlEpisode
import com.enve.engine.podcasts.PodcastSubscription
import java.net.URI
import java.net.URISyntaxException
import java.util.Locale
import kotlin.math.abs

private const val SAME_DAY_WINDOW_MS = 36L * 60 * 60 * 1000
private val titleSeparators = Regex("[\\s\\p{Punct}]+")

internal fun podcastImportPreview(document: PodcastOpmlDocument, existingFeedUrls: List<String>): PodcastImportPreview {
    val existingKeys = existingFeedUrls.mapTo(mutableSetOf(), PodcastFeedUrl::key)
    val merged = LinkedHashMap<String, PodcastOpmlFeed>()
    var duplicates = 0
    for (feed in document.feeds) {
        val key = PodcastFeedUrl.key(feed.feedUrl)
        val existing = merged[key]
        if (existing == null) {
            merged[key] = feed
        } else {
            duplicates++
            merged[key] = existing.copy(
                isSubscribed = existing.isSubscribed || feed.isSubscribed,
                episodes = existing.episodes + feed.episodes,
            )
        }
    }
    return PodcastImportPreview(
        candidates = merged.map { (key, feed) ->
            PodcastImportCandidate(
                key = key,
                title = feed.title,
                feedUrl = feed.feedUrl,
                isAlreadySubscribed = key in existingKeys,
                isSubscribedInSource = feed.isSubscribed,
                episodes = feed.episodes.filter(PodcastOpmlEpisode::hasListeningState),
            )
        },
        duplicateCount = duplicates,
        invalidCount = document.invalidFeedCount,
    )
}

internal sealed interface PodcastEpisodeStateDecision {
    data class Apply(val progress: PodcastFeedProgress) : PodcastEpisodeStateDecision
    data object KeptExistingProgress : PodcastEpisodeStateDecision
    data object AlreadyFinished : PodcastEpisodeStateDecision
}

internal object PodcastEpisodeStateMerge {
    fun decide(
        imported: PodcastOpmlEpisode,
        existing: PodcastFeedProgress?,
        episodeDurationSec: Long,
        nowMs: Long,
    ): PodcastEpisodeStateDecision {
        val duration = episodeDurationSec.takeIf { it > 0L } ?: existing?.durationSec?.takeIf { it > 0L }
        if (existing != null) {
            if (existing.isFinished) return PodcastEpisodeStateDecision.AlreadyFinished
            val updatedAt = imported.updatedAtMs
            if (updatedAt == null || updatedAt <= existing.updatedAtMs) return PodcastEpisodeStateDecision.KeptExistingProgress
        }
        val updatedAt = imported.updatedAtMs ?: nowMs
        if (imported.isPlayed) {
            return PodcastEpisodeStateDecision.Apply(PodcastFeedProgress(duration ?: 0L, duration ?: 0L, isFinished = true, updatedAtMs = updatedAt))
        }
        val position = imported.positionSec ?: 0L
        return PodcastEpisodeStateDecision.Apply(
            PodcastFeedProgress(duration?.let { minOf(position, it) } ?: position, duration ?: 0L, isFinished = false, updatedAtMs = updatedAt),
        )
    }
}

internal class PodcastEpisodeIndex(episodes: List<Book>) {
    private val byGuid = HashMap<String, Book>()
    private val byEnclosure = HashMap<String, Book>()
    private val byFileName: Map<String, Book>
    private val byTitle = HashMap<String, MutableList<Book>>()

    init {
        val fileNames = HashMap<String, Book>()
        val fileNameCounts = HashMap<String, Int>()
        for (episode in episodes) {
            episode.episodeId?.let { byGuid.putIfAbsent(it, episode) }
            episode.podcastEnclosureUrl?.let { enclosure ->
                byEnclosure.putIfAbsent(PodcastFeedUrl.key(enclosure), episode)
                fileName(enclosure)?.let { name ->
                    fileNameCounts[name] = (fileNameCounts[name] ?: 0) + 1
                    fileNames[name] = episode
                }
            }
            byTitle.getOrPut(titleKey(episode.title)) { mutableListOf() } += episode
        }
        byFileName = fileNames.filterKeys { fileNameCounts[it] == 1 }
    }

    fun match(imported: PodcastOpmlEpisode): Book? {
        imported.guid?.let { guid -> byGuid[guid]?.let { return it } }
        imported.enclosureUrl?.let { enclosure ->
            byEnclosure[PodcastFeedUrl.key(enclosure)]?.let { return it }
            fileName(enclosure)?.let { name -> byFileName[name]?.let { return it } }
        }
        val title = imported.title ?: return null
        val candidates = byTitle[titleKey(title)].orEmpty()
        imported.publishedAtMs?.let { published ->
            candidates.filter { it.addedOn > 0L && abs(it.addedOn - published) < SAME_DAY_WINDOW_MS }
                .singleOrNull()?.let { return it }
        }
        return candidates.singleOrNull()
    }

    private fun fileName(url: String): String? {
        val path = try {
            URI(url.trim()).path
        } catch (_: URISyntaxException) {
            null
        } ?: return null
        return path.substringAfterLast('/').lowercase(Locale.ROOT).takeIf { it.length >= 8 }
    }

    private fun titleKey(title: String): String =
        title.lowercase(Locale.ROOT).split(titleSeparators).filter(String::isNotEmpty).joinToString(" ")
}

internal data class PodcastStateApplication(
    val writes: Map<String, PodcastFeedProgress>,
    val applied: Int,
    val keptExisting: Int,
    val alreadyFinished: Int,
    val unmatched: Int,
)

internal fun applyImportedPodcastStates(
    states: List<PodcastOpmlEpisode>,
    episodes: List<Book>,
    existing: Map<String, PodcastFeedProgress>,
    nowMs: Long,
): PodcastStateApplication {
    val index = PodcastEpisodeIndex(episodes)
    val newest = LinkedHashMap<String, Pair<Book, PodcastOpmlEpisode>>()
    var unmatched = 0
    for (state in states) {
        val book = index.match(state)
        if (book == null) {
            unmatched++
            continue
        }
        val current = newest[book.uniqueKey]
        if (current == null || supersedes(state, current.second)) newest[book.uniqueKey] = book to state
    }
    val writes = LinkedHashMap<String, PodcastFeedProgress>()
    var kept = 0
    var finished = 0
    for ((key, entry) in newest) {
        when (val decision = PodcastEpisodeStateMerge.decide(entry.second, existing[key], entry.first.duration, nowMs)) {
            is PodcastEpisodeStateDecision.Apply -> writes[key] = decision.progress
            PodcastEpisodeStateDecision.KeptExistingProgress -> kept++
            PodcastEpisodeStateDecision.AlreadyFinished -> finished++
        }
    }
    return PodcastStateApplication(writes, writes.size, kept, finished, unmatched)
}

private fun supersedes(candidate: PodcastOpmlEpisode, current: PodcastOpmlEpisode): Boolean {
    val lhs = candidate.updatedAtMs ?: Long.MIN_VALUE
    val rhs = current.updatedAtMs ?: Long.MIN_VALUE
    return if (lhs != rhs) lhs > rhs else candidate.isPlayed && !current.isPlayed
}

internal data class PodcastExportPlan(
    val feeds: List<PodcastOpmlExportFeed>,
    val exclusions: List<PodcastExportExclusion>,
    val duplicateCount: Int,
)

internal fun podcastExportPlan(
    subscriptions: List<PodcastSubscription>,
    episodesByFeedKey: Map<String, List<Book>>,
    includePrivateFeeds: Boolean,
): PodcastExportPlan {
    val seen = mutableSetOf<String>()
    val feeds = mutableListOf<PodcastOpmlExportFeed>()
    val exclusions = mutableListOf<PodcastExportExclusion>()
    var duplicates = 0
    for (subscription in subscriptions) {
        val key = PodcastFeedUrl.key(subscription.feedUrl)
        if (!seen.add(key)) {
            duplicates++
            continue
        }
        val concern = PodcastFeedUrl.privacyConcern(subscription.feedUrl)
        if (!includePrivateFeeds && concern != null) {
            exclusions += PodcastExportExclusion(subscription.title, concern)
            continue
        }
        feeds += PodcastOpmlExportFeed(
            title = subscription.title,
            feedUrl = PodcastFeedUrl.canonical(subscription.feedUrl) ?: subscription.feedUrl,
            episodes = episodesByFeedKey[key].orEmpty().mapNotNull { exportedState(it, includePrivateFeeds) },
        )
    }
    return PodcastExportPlan(feeds, exclusions, duplicates)
}

private fun exportedState(episode: Book, includePrivateLinks: Boolean): PodcastOpmlEpisode? {
    val played = episode.isFinished
    if (!played && episode.currentTime <= 0L) return null
    fun shareable(value: String?) = value?.takeIf { includePrivateLinks || PodcastFeedUrl.privacyConcern(it) == null }
    return PodcastOpmlEpisode(
        title = episode.title,
        guid = shareable(episode.episodeId),
        enclosureUrl = shareable(episode.podcastEnclosureUrl),
        publishedAtMs = episode.addedOn.takeIf { it > 0L },
        updatedAtMs = episode.lastReadTime.takeIf { it > 0L },
        positionSec = if (played) null else episode.currentTime,
        isPlayed = played,
    )
}
