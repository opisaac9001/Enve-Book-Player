package com.enve.core.data.model

data class PodcastShow(
    val id: String,
    val title: String,
    val author: String?,
    val description: String?,
    val coverUrl: String?,
    val genres: List<String>,
    val episodes: List<Book>,
    val feedUrl: String?,
    val storedFeedKeys: List<PodcastFeedKey>,
)

data class PodcastFeedKey(
    val guid: String?,
    val enclosureUrl: String?,
    val title: String,
    val publishedAtMs: Long?,
)

data class PodcastFeedEpisode(
    val guid: String,
    val title: String,
    val description: String?,
    val publishedAtMs: Long?,
    val durationSec: Long,
    val enclosureUrl: String,
    val enclosureType: String?,
)
