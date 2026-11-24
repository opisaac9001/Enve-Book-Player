package com.enve.app.data.podcasts

import com.enve.core.data.model.Book
import com.enve.engine.podcasts.PodcastFeedUrl
import com.enve.engine.podcasts.PodcastRoutinePick
import com.enve.engine.podcasts.PodcastRoutineRule
import com.enve.engine.podcasts.PodcastRoutineRuleOutcome

sealed interface PodcastRoutineFeed {
    data class Fresh(val episodes: List<Book>) : PodcastRoutineFeed
    data class Stale(val episodes: List<Book>) : PodcastRoutineFeed
    data class DownloadedOnly(val episodes: List<Book>) : PodcastRoutineFeed
    data object Failed : PodcastRoutineFeed
}

object PodcastRoutineSelector {
    fun resolve(
        rules: List<PodcastRoutineRule>,
        feedsByKey: Map<String, PodcastRoutineFeed>,
        subscribedFeedKeys: Set<String>,
        isOffline: Boolean,
        isDownloaded: (Book) -> Boolean,
    ): List<PodcastRoutineRuleOutcome> {
        val taken = mutableSetOf<String>()
        return rules.map { rule ->
            resolve(rule, feedsByKey, subscribedFeedKeys, isOffline, isDownloaded, taken).also { outcome ->
                outcome.episodes.mapTo(taken, Book::uniqueKey)
            }
        }
    }

    fun chronological(episodes: List<Book>): List<Book> {
        val seen = mutableSetOf<String>()
        return episodes.withIndex()
            .filter { seen.add(it.value.uniqueKey) }
            .sortedWith(compareBy<IndexedValue<Book>> { it.value.addedOn }.thenByDescending { it.index })
            .map { it.value }
    }

    private fun resolve(
        rule: PodcastRoutineRule,
        feedsByKey: Map<String, PodcastRoutineFeed>,
        subscribedFeedKeys: Set<String>,
        isOffline: Boolean,
        isDownloaded: (Book) -> Boolean,
        taken: Set<String>,
    ): PodcastRoutineRuleOutcome {
        fun outcome(episodes: List<Book> = emptyList(), note: String?) =
            PodcastRoutineRuleOutcome(rule.id, rule.showTitle, episodes, note)

        val key = PodcastFeedUrl.key(rule.feedUrl)
        if (key !in subscribedFeedKeys) return outcome(note = "You're no longer subscribed to this show.")

        val (listing, isStale) = when (val feed = feedsByKey[key] ?: PodcastRoutineFeed.Failed) {
            PodcastRoutineFeed.Failed -> return outcome(
                note = if (isOffline) "No downloaded episodes are available offline." else "The feed couldn't be loaded. Try again later.",
            )
            is PodcastRoutineFeed.Fresh -> feed.episodes to false
            is PodcastRoutineFeed.Stale -> feed.episodes to !isOffline
            is PodcastRoutineFeed.DownloadedOnly -> {
                if (rule.pick is PodcastRoutinePick.NextUnplayed) {
                    return outcome(
                        note = "The episode list isn't available offline, so the next episode in order can't be confirmed. " +
                            "Open this show while online first.",
                    )
                }
                feed.episodes to false
            }
        }

        val ordered = chronological(listing)
        fun isAvailable(episode: Book) = !isOffline || isDownloaded(episode)
        val staleNote = if (isStale) "Couldn't refresh this show, so the last loaded episode list was used." else null

        return when (val pick = rule.pick) {
            PodcastRoutinePick.NewestUnplayed -> {
                val unplayed = ordered.asReversed().filterNot(Book::isFinished)
                if (unplayed.isEmpty()) return outcome(note = "Every episode has been played.")
                val fresh = unplayed.filterNot { it.uniqueKey in taken }
                if (fresh.isEmpty()) return outcome(note = "Already queued by an earlier rule.")
                val choice = fresh.firstOrNull(::isAvailable)
                    ?: return outcome(note = "None of the unplayed episodes are downloaded.")
                outcome(listOf(choice), staleNote)
            }
            is PodcastRoutinePick.NextUnplayed -> {
                val anchor = ordered.indexOfLast { it.isStarted || it.isFinished }
                val start = when {
                    anchor < 0 -> 0
                    ordered[anchor].isFinished -> anchor + 1
                    else -> anchor
                }
                val upcoming = ordered.drop(start).filterNot(Book::isFinished)
                if (upcoming.isEmpty()) return outcome(note = "You're caught up on this show.")

                val picked = mutableListOf<Book>()
                var blocked: Book? = null
                for (episode in upcoming) {
                    if (picked.size >= pick.count) break
                    if (episode.uniqueKey in taken) continue
                    if (!isAvailable(episode)) {
                        blocked = episode
                        break
                    }
                    picked += episode
                }
                when {
                    blocked != null && picked.isEmpty() ->
                        outcome(note = "“${blocked.title}” is next but isn't downloaded, so later episodes were held back.")
                    blocked != null -> outcome(picked, "Stopped before “${blocked.title}”, which isn't downloaded.")
                    picked.isEmpty() -> outcome(note = "Already queued by an earlier rule.")
                    else -> outcome(picked, staleNote)
                }
            }
        }
    }

    private val Book.isStarted: Boolean get() = currentTime > 0L || readProgress > 0f
}
