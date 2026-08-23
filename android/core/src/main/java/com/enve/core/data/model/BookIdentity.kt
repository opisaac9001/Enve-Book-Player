package com.enve.core.data.model

import java.text.Normalizer
import kotlin.math.max
import kotlin.math.min

object BookIdentity {
    private val placeholderTitles = setOf(
        "unknown title",
        "unknown",
        "untitled",
        "unknown album",
        "no title",
        "track 1",
    )

    fun workKey(book: Book): String {
        if (book.mediaType == AppMediaType.PODCAST) return ""
        val title = workTitle(book.title)
        if (title.isEmpty() || title in placeholderTitles) return ""
        val author = normalizeContributor(book.author)
        if (book.mediaType == AppMediaType.AUDIOBOOK) {
            if (book.duration <= 0L) return ""
            return "w:$title|$author|d:${book.duration}"
        }
        val volume = titleVolume(title, hasSeriesContext(book))
        if (volume != null) {
            val base = volume.base.ifBlank { normalizeContributor(book.seriesName) }.ifBlank { title }
            return "w:$base|$author|s:${volume.number}"
        }
        seriesPosition(book)?.let { return "w:$title|$author|s:$it" }
        return "w:$title|$author"
    }

    fun editionKey(book: Book): String {
        val work = workKey(book)
        if (work.isEmpty()) return ""
        val language = book.language.orEmpty().trim().lowercase()
        val narrator = normalizeNarratorList(book.narrator).sorted().joinToString(",")
        val production = productionType(book)
        val abridged = abridgedState(book)
        val duration = if (book.mediaType == AppMediaType.AUDIOBOOK && book.duration > 0L) "|d:${book.duration}" else ""
        return "$work|f:${book.mediaType.name.lowercase()}|p:$production|a:$abridged|l:$language|n:$narrator$duration"
    }

    fun linkScore(ebook: Book, audiobook: Book): Int {
        if (ebook.mediaType != AppMediaType.EBOOK || audiobook.mediaType != AppMediaType.AUDIOBOOK) return 0
        val ebookIsbn = normalizeIsbn(ebook.isbn13)
        val audiobookIsbn = normalizeIsbn(audiobook.isbn13)
        if (ebookIsbn.isNotEmpty() && ebookIsbn == audiobookIsbn) return 100

        val ebookTitle = workTitle(ebook.title)
        val audiobookTitle = workTitle(audiobook.title)
        if (ebookTitle.isEmpty() || audiobookTitle.isEmpty()) return 0
        val ebookVolumeToken = volumeToken(ebook, ebookTitle)
        val audiobookVolumeToken = volumeToken(audiobook, audiobookTitle)
        if (ebookVolumeToken != null && audiobookVolumeToken != null && ebookVolumeToken != audiobookVolumeToken) return 0

        val ebookAuthor = normalizeContributor(ebook.author)
        val audiobookAuthor = normalizeContributor(audiobook.author)
        val authorSimilarity = tokenSimilarity(ebookAuthor, audiobookAuthor)
        val sameAuthor = ebookAuthor.isNotEmpty() && ebookAuthor == audiobookAuthor
        val compatibleAuthor = sameAuthor || authorSimilarity >= 0.8f || ebookAuthor.isEmpty() || audiobookAuthor.isEmpty()
        if (!compatibleAuthor) return 0

        if (workKey(ebook) == workKey(audiobook)) {
            return if (sameAuthor || authorSimilarity >= 0.8f) 98 else 92
        }

        val ebookVolume = titleVolume(ebookTitle, hasSeriesContext(ebook))
        val audiobookVolume = titleVolume(audiobookTitle, hasSeriesContext(audiobook))
        if (ebookVolume != null || audiobookVolume != null) {
            if (ebookVolume?.number != audiobookVolume?.number) return 0
            if (ebookVolume == null || audiobookVolume == null) return 0
            val baseSimilarity = titleSimilarity(ebookVolume.base, audiobookVolume.base)
            if (baseSimilarity >= 0.9f) return 94
        }

        val titleSimilarity = titleSimilarity(ebookTitle, audiobookTitle)
        return when {
            titleSimilarity >= 0.96f && (sameAuthor || authorSimilarity >= 0.8f) -> 94
            titleSimilarity >= 0.90f && (sameAuthor || authorSimilarity >= 0.8f) -> 88
            else -> 0
        }
    }

    fun duplicateScore(left: Book, right: Book): DuplicateScore? {
        if (left.uniqueKey == right.uniqueKey) return null
        if (left.mediaType != right.mediaType) return null

        val leftIsbn = normalizeIsbn(left.isbn13)
        val rightIsbn = normalizeIsbn(right.isbn13)
        if (leftIsbn.isNotEmpty() && leftIsbn == rightIsbn) {
            return DuplicateScore(100, DuplicateMatchReason.ISBN)
        }

        val leftEdition = editionKey(left)
        val rightEdition = editionKey(right)
        if (leftEdition.isNotEmpty() && leftEdition == rightEdition) {
            return DuplicateScore(98, DuplicateMatchReason.EXACT_TITLE_AUTHOR)
        }

        if (left.mediaType == AppMediaType.AUDIOBOOK && left.duration > 0L && right.duration > 0L) {
            return null
        }

        val leftTitle = workTitle(left.title)
        val rightTitle = workTitle(right.title)
        if (leftTitle.isEmpty() || rightTitle.isEmpty()) return null
        val leftVolumeToken = volumeToken(left, leftTitle)
        val rightVolumeToken = volumeToken(right, rightTitle)
        if (leftVolumeToken != null && rightVolumeToken != null && leftVolumeToken != rightVolumeToken) return null

        val leftAuthor = normalizeContributor(left.author)
        val rightAuthor = normalizeContributor(right.author)
        val authorSimilarity = tokenSimilarity(leftAuthor, rightAuthor)
        val sameAuthor = leftAuthor.isNotEmpty() && leftAuthor == rightAuthor
        val compatibleAuthor = sameAuthor || authorSimilarity >= 0.75f || leftAuthor.isEmpty() || rightAuthor.isEmpty()

        if (leftTitle == rightTitle) {
            return when {
                sameAuthor -> DuplicateScore(98, DuplicateMatchReason.EXACT_TITLE_AUTHOR)
                authorSimilarity >= 0.8f -> DuplicateScore(96, DuplicateMatchReason.EXACT_TITLE_AUTHOR)
                leftAuthor.isEmpty() || rightAuthor.isEmpty() -> DuplicateScore(90, DuplicateMatchReason.EXACT_TITLE)
                else -> DuplicateScore(82, DuplicateMatchReason.EXACT_TITLE)
            }
        }

        if (!compatibleAuthor) return null
        val titleSimilarity = titleSimilarity(leftTitle, rightTitle)
        val confidence = when {
            titleSimilarity >= 0.92f && (sameAuthor || authorSimilarity >= 0.8f) -> 90
            titleSimilarity >= 0.82f && (sameAuthor || authorSimilarity >= 0.8f) -> 86
            titleSimilarity >= 0.70f && (sameAuthor || authorSimilarity >= 0.8f) -> 76
            titleSimilarity >= 0.92f -> 72
            else -> return null
        }
        return DuplicateScore(confidence, DuplicateMatchReason.SIMILAR_TITLE_AUTHOR)
    }

    fun normalizeIsbn(value: String?): String =
        value.orEmpty().filter { it.isDigit() || it == 'X' || it == 'x' }.uppercase()

    fun workTitle(value: String): String {
        var title = normalizeWords(value)
        val markers = listOf(
            "full cast",
            "fullcast",
            "dramatized",
            "dramatised",
            "graphic audio",
            "graphicaudio",
            "audio drama",
            "radio drama",
            "unabridged",
            "abridged",
            "audiobook",
            "ebook",
            "edition",
        )
        var changed = true
        while (changed) {
            changed = false
            for (marker in markers) {
                if (title.endsWith(" $marker")) {
                    title = title.dropLast(marker.length + 1).trim()
                    changed = true
                }
            }
        }
        return title.replace(Regex("""\b(the|a|an)\b"""), " ")
            .replace(Regex("""\s+"""), " ")
            .trim()
    }

    fun normalizeContributor(value: String?): String =
        normalizeWords(value.orEmpty())
            .replace(Regex("""\b(the|a|an)\b"""), " ")
            .replace(Regex("""\s+"""), " ")
            .trim()

    fun titleSimilarity(left: String, right: String): Float {
        if (left == right) return 1f
        val leftTokens = left.tokenSet()
        val rightTokens = right.tokenSet()
        if (leftTokens.isEmpty() || rightTokens.isEmpty()) return 0f

        val intersection = leftTokens.intersect(rightTokens).size.toFloat()
        val union = leftTokens.union(rightTokens).size.toFloat()
        val minTokenCount = min(leftTokens.size, rightTokens.size)
        val overlap = intersection / minTokenCount
        val jaccard = intersection / union
        val tokenScore = if (minTokenCount == 1 && leftTokens.size != rightTokens.size) {
            jaccard
        } else {
            overlap * 0.85f + jaccard * 0.15f
        }
        val containment = if (left.contains(right) || right.contains(left)) {
            min(left.length, right.length).toFloat() / max(left.length, right.length)
        } else {
            0f
        }
        return max(max(jaccard, tokenScore), containment)
    }

    private fun normalizeWords(value: String): String {
        val stripped = Normalizer.normalize(value.lowercase(), Normalizer.Form.NFD)
            .replace(Regex("""\p{Mn}+"""), "")
        return stripped
            .replace("&", " and ")
            .replace(Regex("""['’]s\b"""), "")
            .replace(Regex("""\([^)]*\)|\[[^]]*]|\{[^}]*\}"""), " ")
            .replace(Regex("""[^a-z0-9]+"""), " ")
            .trim()
    }

    private fun hasSeriesContext(book: Book): Boolean =
        !book.seriesName.isNullOrBlank() || !book.seriesNumber.isNullOrBlank()

    private fun titleVolume(title: String, seriesContext: Boolean): TitleVolume? {
        val keyword = Regex("""\b(?:volume|vol|book|bk|part|pt|novel)\b\.?\s*#?\s*(\d+(?:\.\d+)?)""")
            .find(title)
        if (keyword != null) {
            return TitleVolume(normalizedNumber(keyword.groupValues[1]), title.removeRange(keyword.range).cleanSpaces())
        }
        if (seriesContext) {
            val trailing = Regex("""\s(\d+(?:\.\d+)?)$""").find(title)
            if (trailing != null) {
                return TitleVolume(normalizedNumber(trailing.groupValues[1]), title.substring(0, trailing.range.first).cleanSpaces())
            }
        }
        return null
    }

    private fun volumeToken(book: Book, normalizedTitle: String): String? =
        titleVolume(normalizedTitle, hasSeriesContext(book))?.number ?: seriesPosition(book)

    private fun seriesPosition(book: Book): String? {
        val raw = book.seriesNumber?.trim().orEmpty()
        if (raw.isEmpty()) return null
        val numeric = raw.filter { it.isDigit() || it == '.' }
        val parsed = numeric.toDoubleOrNull()
        return if (parsed != null && parsed > 0.0) "%g".format(parsed) else raw.lowercase()
    }

    private fun normalizedNumber(value: String): String =
        value.toDoubleOrNull()?.let { "%g".format(it) } ?: value

    private fun normalizeNarratorList(value: String?): List<String> =
        normalizeContributor(value)
            .split(" and ", ",")
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    private fun productionType(book: Book): String {
        val haystack = "${book.title} ${book.subtitle.orEmpty()} ${book.narrator.orEmpty()}".lowercase()
        return when {
            "graphic audio" in haystack || "full cast" in haystack || "dramatized" in haystack || "dramatised" in haystack -> "dramatized"
            else -> "standard"
        }
    }

    private fun abridgedState(book: Book): String {
        val haystack = "${book.title} ${book.subtitle.orEmpty()} ${book.description.orEmpty()}".lowercase()
        return if ("abridged" in haystack && "unabridged" !in haystack) "abridged" else "unabridged"
    }

    private fun tokenSimilarity(left: String, right: String): Float {
        if (left.isEmpty() || right.isEmpty()) return 0f
        if (left == right) return 1f
        val leftTokens = left.tokenSet()
        val rightTokens = right.tokenSet()
        if (leftTokens.isEmpty() || rightTokens.isEmpty()) return 0f
        val intersection = leftTokens.intersect(rightTokens).size.toFloat()
        return intersection / min(leftTokens.size, rightTokens.size)
    }

    private fun String.tokenSet(): Set<String> =
        split(' ')
            .asSequence()
            .map { it.trim() }
            .filter { it.length > 1 }
            .toSet()

    private fun String.cleanSpaces(): String =
        replace(Regex("""\s{2,}"""), " ").trim()

    private data class TitleVolume(val number: String, val base: String)
}

data class DuplicateScore(
    val confidence: Int,
    val reason: DuplicateMatchReason,
)
