package com.enve.core.data.util

import com.enve.core.data.model.SubtitleHandling
import com.enve.core.data.model.TitleDisplayMode

object LibraryDisplayTitleFormatter {
    fun displayTitle(
        title: String,
        mode: TitleDisplayMode,
        subtitleHandling: SubtitleHandling,
    ): String {
        val withoutSubtitle = if (subtitleHandling == SubtitleHandling.REMOVE) {
            title.substringBefore(':').trim().ifBlank { title }
        } else {
            title
        }
        return normalize(withoutSubtitle, mode)
    }

    fun normalize(title: String, mode: TitleDisplayMode): String {
        val bookPrefixRegex = Regex("""^Book\s+(\d+)\s*[-\u2013\u2014]\s*""", RegexOption.IGNORE_CASE)
        val numericPrefixRegex = Regex("""^(\d+)\s*[-\u2013\u2014]\s*""")
        return when (mode) {
            TitleDisplayMode.PRESERVE -> title
            TitleDisplayMode.STRIP_PREFIX -> title
                .replace(bookPrefixRegex, "")
                .replace(numericPrefixRegex, "")
                .trim()
            TitleDisplayMode.MOVE_TO_SUFFIX -> {
                val bookMatch = bookPrefixRegex.find(title)
                val numericMatch = numericPrefixRegex.find(title)
                when {
                    bookMatch != null -> "${title.replace(bookPrefixRegex, "").trim()} (Book ${bookMatch.groupValues[1]})"
                    numericMatch != null -> "${title.replace(numericPrefixRegex, "").trim()} (Book ${numericMatch.groupValues[1]})"
                    else -> title
                }
            }
            TitleDisplayMode.EXTRACT_TO_SERIES -> {
                val match = numericPrefixRegex.find(title) ?: bookPrefixRegex.find(title)
                if (match == null) {
                    title
                } else {
                    "${title.replace(numericPrefixRegex, "").replace(bookPrefixRegex, "").trim()} (Series: #${match.groupValues[1]})"
                }
            }
        }
    }
}
