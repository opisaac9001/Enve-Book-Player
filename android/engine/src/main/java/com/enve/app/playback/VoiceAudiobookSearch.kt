package com.enve.app.playback

internal data class VoiceAudiobookSearch(
    val query: String?,
    val title: String?,
    val creator: String?,
) {
    val isEmpty: Boolean
        get() = query == null && title == null && creator == null

    fun rank(candidateTitle: String, author: String?, narrator: String?): Int {
        if (isEmpty) return 0

        title?.let { requestedTitle ->
            val titleRank = textRank(candidateTitle, requestedTitle)
            if (titleRank == NO_MATCH) return NO_MATCH
            val creatorRank = creator?.let {
                minOf(textRank(author, it), textRank(narrator, it)).coerceAtMost(CREATOR_MISMATCH)
            } ?: 0
            return titleRank * 10 + creatorRank
        }

        query?.let { requested ->
            return minOf(
                textRank(candidateTitle, requested) * 10,
                textRank(author, requested) * 10 + 1,
                textRank(narrator, requested) * 10 + 2,
            )
        }

        val requestedCreator = creator ?: return NO_MATCH
        return minOf(textRank(author, requestedCreator), textRank(narrator, requestedCreator))
    }

    fun matches(candidateTitle: String, author: String?, narrator: String?): Boolean =
        rank(candidateTitle, author, narrator) < NO_MATCH

    companion object {
        const val NO_MATCH = 1_000
        private const val CREATOR_MISMATCH = 9

        fun create(query: String?, title: String?, creator: String?): VoiceAudiobookSearch {
            val cleanedQuery = query.cleaned()
            val cleanedTitle = title.cleaned()
            val cleanedCreator = creator.cleaned()
            val titleAndCreator = if (cleanedTitle == null && cleanedCreator == null) {
                cleanedQuery?.let(TITLE_AND_CREATOR::matchEntire)
            } else {
                null
            }
            return VoiceAudiobookSearch(
                query = cleanedQuery.takeIf { titleAndCreator == null },
                title = cleanedTitle ?: titleAndCreator?.groupValues?.get(1)?.cleaned(),
                creator = cleanedCreator ?: titleAndCreator?.groupValues?.get(2)?.cleaned(),
            )
        }

        private val TITLE_AND_CREATOR = Regex("^(.+?)\\s+by\\s+(.+)$", RegexOption.IGNORE_CASE)

        private fun String?.cleaned(): String? = this
            ?.trim()
            ?.replace(Regex("\\s+"), " ")
            ?.takeIf { it.isNotEmpty() }

        private fun textRank(value: String?, requested: String): Int {
            val candidate = value.cleaned()?.lowercase() ?: return NO_MATCH
            val target = requested.cleaned()?.lowercase() ?: return NO_MATCH
            return when {
                candidate == target -> 0
                candidate.startsWith(target) -> 1
                candidate.contains(target) -> 2
                else -> NO_MATCH
            }
        }
    }
}
