package com.enve.engine.podcasts

object PodcastOpmlLimits {
    const val MAX_BYTES = 16 * 1024 * 1024
    const val MAX_OUTLINES = 200_000
    const val MAX_FEEDS = 5_000
    const val MAX_DEPTH = 32
}

enum class PodcastOpmlError(val message: String) {
    UNREADABLE("The file couldn't be opened. Make sure it's downloaded and try again."),
    EMPTY("The file is empty."),
    TOO_LARGE("The file is larger than 16 MB, which is more than a podcast export should need."),
    UNSUPPORTED_ENCODING("The file isn't UTF-8 text. Export it again or save it as UTF-8."),
    DOCUMENT_TYPE_NOT_ALLOWED("The file declares a document type or entities, which OPML files never need. It wasn't opened."),
    NOT_OPML("This isn't an OPML file."),
    TOO_COMPLEX("The file has too many entries or is nested too deeply to import safely."),
    MALFORMED("The file is damaged and couldn't be read."),
    NO_FEEDS("The file doesn't contain any podcast feeds."),
}

class PodcastOpmlException(val error: PodcastOpmlError) : Exception(error.message)

data class PodcastOpmlEpisode(
    val title: String? = null,
    val guid: String? = null,
    val enclosureUrl: String? = null,
    val publishedAtMs: Long? = null,
    val updatedAtMs: Long? = null,
    val positionSec: Long? = null,
    val isPlayed: Boolean = false,
) {
    val hasListeningState: Boolean get() = isPlayed || (positionSec ?: 0L) > 0L
}

data class PodcastImportCandidate(
    val key: String,
    val title: String,
    val feedUrl: String,
    val isAlreadySubscribed: Boolean,
    val isSubscribedInSource: Boolean,
    val episodes: List<PodcastOpmlEpisode>,
) {
    val playedCount: Int get() = episodes.count(PodcastOpmlEpisode::isPlayed)
    val inProgressCount: Int get() = episodes.count { !it.isPlayed && (it.positionSec ?: 0L) > 0L }
    val listeningStateCount: Int get() = playedCount + inProgressCount
}

data class PodcastImportPreview(
    val candidates: List<PodcastImportCandidate>,
    val duplicateCount: Int,
    val invalidCount: Int,
) {
    val newCount: Int get() = candidates.count { !it.isAlreadySubscribed }
    val alreadySubscribedCount: Int get() = candidates.count(PodcastImportCandidate::isAlreadySubscribed)
    val listeningStateCount: Int get() = candidates.sumOf(PodcastImportCandidate::listeningStateCount)
    val defaultSelection: Set<String>
        get() = candidates.filter { it.isSubscribedInSource || it.isAlreadySubscribed }.mapTo(mutableSetOf(), PodcastImportCandidate::key)
}

data class PodcastImportReport(
    val subscribed: Int = 0,
    val alreadySubscribed: Int = 0,
    val applied: Int = 0,
    val keptExisting: Int = 0,
    val alreadyFinished: Int = 0,
    val unmatched: Int = 0,
    val unloadedFeeds: List<String> = emptyList(),
    val unloadedStates: Int = 0,
) {
    val summaryLines: List<String>
        get() = buildList {
            add("Added ${count(subscribed, "show")}.")
            if (alreadySubscribed > 0) add("${count(alreadySubscribed, "show")} already subscribed.")
            if (applied > 0) add("Restored listening history for ${count(applied, "episode")}.")
            if (keptExisting > 0) add("${count(keptExisting, "episode")} kept Enve's progress because it was the same or newer.")
            if (alreadyFinished > 0) add("${count(alreadyFinished, "episode")} already finished in Enve.")
            if (unmatched > 0) {
                add("${count(unmatched, "episode")} no longer in the show's feed or couldn't be matched, so that history wasn't imported.")
            }
            if (unloadedFeeds.isNotEmpty()) {
                add(
                    "History for ${count(unloadedStates, "episode")} wasn't applied because these shows couldn't be loaded: " +
                        "${unloadedFeeds.joinToString(", ")}.",
                )
            }
        }

    private fun count(value: Int, noun: String) = if (value == 1) "1 $noun" else "$value ${noun}s"
}

data class PodcastExportExclusion(val title: String, val concern: PodcastFeedPrivacyConcern)

data class PodcastExportResult(
    val opml: ByteArray,
    val feedCount: Int,
    val episodeStateCount: Int,
    val exclusions: List<PodcastExportExclusion>,
    val duplicateCount: Int,
    val feedsWithoutProgress: List<String>,
) {
    override fun equals(other: Any?): Boolean = other is PodcastExportResult &&
        opml.contentEquals(other.opml) && feedCount == other.feedCount && episodeStateCount == other.episodeStateCount &&
        exclusions == other.exclusions && duplicateCount == other.duplicateCount && feedsWithoutProgress == other.feedsWithoutProgress

    override fun hashCode(): Int = opml.contentHashCode()
}
