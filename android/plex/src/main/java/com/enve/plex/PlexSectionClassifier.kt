package com.enve.plex

internal fun isLikelyPlexAudiobookSection(
    type: String,
    title: String,
    agent: String?,
    scanner: String?,
): Boolean {
    val searchable = listOf(title, agent.orEmpty(), scanner.orEmpty())
        .joinToString(" ")
        .lowercase()
    val hasAudiobookSignal =
        searchable.contains("audnexus") ||
            Regex("""\baudio\s*books?\b""").containsMatchIn(searchable) ||
            Regex("""\baudiobooks?\b""").containsMatchIn(searchable) ||
            Regex("""\bbooks?\b""").containsMatchIn(searchable)

    return hasAudiobookSignal && type.equals("artist", ignoreCase = true)
}
