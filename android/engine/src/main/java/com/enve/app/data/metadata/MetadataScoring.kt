package com.enve.app.data.metadata

import java.text.Normalizer
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

object MetadataScoring {
    private const val W_DURATION = 0.7
    private const val W_TITLE = 0.2
    private const val W_AUTHOR = 0.1
    private const val DEFAULT_DURATION_SCORE_MISSING_INFO = 0.1

    fun normalizeSearchQuery(input: String): String {
        return input
            .replace("\\[[^\\]]*\\]".toRegex(), "")
            .replace("\\([^)]*\\)".toRegex(), "")
            .replace("\\{[^}]*\\}".toRegex(), "")
            .replace("\\s+".toRegex(), " ")
            .trim()
    }

    fun parseTitleAndAuthor(query: String): Pair<String, String?> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return trimmed to null

        val regex = "(?i)\\s+by\\s+|\\s+-\\s+".toRegex()
        val match = regex.findAll(trimmed).lastOrNull() ?: return trimmed to null
        val title = trimmed.substring(0, match.range.first).trim()
        val author = trimmed.substring(match.range.last + 1).trim()
        return if (title.isEmpty() || author.isEmpty()) trimmed to null else title to author
    }

    fun defaultSearchQuery(title: String, author: String?): String {
        val normalizedTitle = normalizeSearchQuery(title)
        val normalizedAuthor = normalizeSearchQuery(author.orEmpty())
        val parsedTitle = parseTitleAndAuthor(normalizedTitle)
        val parsedAuthor = parsedTitle.second
        val titleContainsAuthor = parsedAuthor != null &&
            normalizedAuthor.isNotBlank() &&
            authorNamesEquivalent(parsedAuthor, normalizedAuthor)
        val queryTitle = if (titleContainsAuthor) parsedTitle.first else normalizedTitle
        val queryAuthor = normalizedAuthor.takeIf { it.isNotBlank() }
        return listOfNotNull(
            queryTitle.takeIf { it.isNotBlank() },
            queryAuthor?.takeIf { it.isNotBlank() },
        ).joinToString(" by ")
    }

    fun calculateAudioScore(file: MetadataMatchFileSnapshot, candidate: MetadataMatchCandidate): MetadataMatchScore {
        val durationScore = calculateDurationScore(
            localDurationSeconds = file.durationSec.toDouble(),
            catalogDurationSeconds = (candidate.durationSec ?: 0L).toDouble(),
        )
        val titleToMatch = bestTitleForMatching(file)
        var titleScore = calculateTitleScore(titleToMatch, candidate.title)

        if (!candidate.seriesName.isNullOrBlank()) {
            val seriesScore = calculateTitleScore(titleToMatch, candidate.seriesName)
            if (seriesScore > titleScore) {
                titleScore = min(1.0, seriesScore + 0.1)
            }
        }

        val authorScore = calculateAuthorScore(file.author.orEmpty(), candidate.authors.ifEmpty { listOfNotNull(candidate.author) })
        val baseConfidence = W_DURATION * durationScore + W_TITLE * titleScore + W_AUTHOR * authorScore
        val confidence = (baseConfidence + calculateSeriesNumberPenalty(
            localTitle = titleToMatch,
            localFileName = file.fileName.orEmpty(),
            resultTitle = candidate.title,
            localSeriesNumber = file.seriesNumber,
        )).coerceIn(0.0, 1.0)
        val hasDuration = file.durationSec > 0 && (candidate.durationSec ?: 0L) > 0L
        val durationDiffMinutes = if (candidate.durationSec == null) Double.MAX_VALUE else {
            abs(candidate.durationSec - file.durationSec) / 60.0
        }

        return MetadataMatchScore(
            total = confidence,
            durationScore = durationScore,
            titleScore = titleScore,
            authorScore = authorScore,
            hasDuration = hasDuration,
            requiresManualReview = !hasDuration || durationDiffMinutes > 10.0,
        )
    }

    fun calculateBookScore(
        file: MetadataMatchFileSnapshot,
        title: String,
        authors: List<String>,
        isbn: String?,
    ): MetadataMatchScore {
        val fileIsbn = file.isbn?.trim().orEmpty()
        val candidateIsbn = isbn?.trim().orEmpty()
        if (fileIsbn.isNotEmpty() && candidateIsbn.isNotEmpty() && fileIsbn.equals(candidateIsbn, ignoreCase = true)) {
            return MetadataMatchScore(
                total = 1.0,
                durationScore = 1.0,
                titleScore = 1.0,
                authorScore = 1.0,
                hasDuration = false,
                requiresManualReview = false,
            )
        }

        val titleScore = calculateTitleScore(bestTitleForMatching(file), title)
        val authorScore = calculateAuthorScore(file.author.orEmpty(), authors)
        val total = ((0.75 * titleScore) + (0.25 * authorScore)).coerceIn(0.0, 1.0)

        return MetadataMatchScore(
            total = total,
            durationScore = 1.0,
            titleScore = titleScore,
            authorScore = authorScore,
            hasDuration = false,
            requiresManualReview = false,
        )
    }

    fun confidenceLabel(score: Double): String = "${(score * 100).roundToInt()}%"

    fun cleanTitleForCompare(title: String, keepSubtitle: Boolean = false): String {
        var cleaned = title
        if (!keepSubtitle) {
            val colon = cleaned.indexOf(':')
            val dash = cleaned.indexOf(" - ")
            cleaned = when {
                colon >= 0 -> cleaned.substring(0, colon).trim()
                dash >= 0 -> cleaned.substring(0, dash).trim()
                else -> cleaned
            }
        }
        cleaned = cleaned
            .replace("\\([^)]*\\)".toRegex(), "")
            .replace("\\[[^\\]]*\\]".toRegex(), "")
            .replace("'", "")
            .replace("\\s+".toRegex(), " ")
            .trim()
        return stripDiacritics(cleaned).lowercase()
    }

    fun cleanAuthorForCompare(author: String): String {
        return stripDiacritics(
            author
                .replace("\\s+".toRegex(), " ")
                .trim()
                .replace("([a-zA-Z])\\.([a-zA-Z])".toRegex(), "$1. $2")
                .replace("\\s+et al\\.?".toRegex(RegexOption.IGNORE_CASE), ""),
        ).lowercase()
    }

    fun normalizedIdentity(title: String, author: String?, year: Int?): String {
        val normalizedTitle = cleanTitleForCompare(title)
        val normalizedAuthor = cleanAuthorForCompare(author.orEmpty())
        return listOf(normalizedTitle, normalizedAuthor, year?.toString().orEmpty()).joinToString("|")
    }

    private fun bestTitleForMatching(file: MetadataMatchFileSnapshot): String {
        return listOf(file.folderName, file.fileName, file.title).firstOrNull { !it.isNullOrBlank() }.orEmpty()
    }

    private fun calculateDurationScore(localDurationSeconds: Double, catalogDurationSeconds: Double): Double {
        if (localDurationSeconds == 0.0 || catalogDurationSeconds == 0.0) {
            return DEFAULT_DURATION_SCORE_MISSING_INFO
        }
        val durationDiff = abs((catalogDurationSeconds / 60.0) - (localDurationSeconds / 60.0))
        return when {
            durationDiff <= 1 -> 1.0
            durationDiff <= 5 -> 1.1 - 0.1 * durationDiff
            durationDiff <= 10 -> 1.2 - 0.12 * durationDiff
            else -> 0.0
        }
    }

    private fun calculateTitleScore(queryTitle: String, bookTitle: String): Double {
        val scoreWithSubtitle = calculateTitleScoreInternal(queryTitle, bookTitle, keepSubtitle = true)
        if (queryTitle.contains(':') || queryTitle.contains(" - ")) {
            return max(scoreWithSubtitle, calculateTitleScoreInternal(queryTitle, bookTitle, keepSubtitle = false))
        }
        return scoreWithSubtitle
    }

    private fun calculateTitleScoreInternal(queryTitle: String, bookTitle: String, keepSubtitle: Boolean): Double {
        val cleanQuery = cleanTitleForCompare(queryTitle, keepSubtitle)
        val cleanBook = cleanTitleForCompare(bookTitle, keepSubtitle)
        if (cleanQuery.isEmpty() || cleanBook.isEmpty()) return 0.0
        return levenshteinSimilarity(cleanQuery, cleanBook)
    }

    private fun calculateAuthorScore(queryAuthor: String, bookAuthors: List<String>): Double {
        val normalizedQuery = cleanAuthorForCompare(queryAuthor)
        if (normalizedQuery.isEmpty()) return 1.0
        if (bookAuthors.isEmpty()) return 0.0

        val normalizedBookAuthor = cleanAuthorForCompare(bookAuthors.joinToString(", "))
        if (normalizedBookAuthor.isEmpty()) return 0.0

        var maxScore = levenshteinSimilarity(normalizedQuery, normalizedBookAuthor)
        normalizedBookAuthor
            .split(',')
            .map { it.trim().lowercase() }
            .filter { it.isNotEmpty() }
            .forEach { part ->
                maxScore = max(maxScore, levenshteinSimilarity(normalizedQuery, part))
            }
        return maxScore
    }

    private fun authorNamesEquivalent(left: String, right: String): Boolean {
        val normalizedLeft = cleanAuthorForCompare(left)
        val normalizedRight = cleanAuthorForCompare(right)
        if (normalizedLeft == normalizedRight) return true
        val leftTokens = authorTokens(normalizedLeft)
        val rightTokens = authorTokens(normalizedRight)
        return leftTokens.size >= 2 && leftTokens == rightTokens
    }

    private fun authorTokens(value: String): Set<String> {
        return value
            .split("[^a-z0-9]+".toRegex())
            .filter { it.length > 1 }
            .toSet()
    }

    private fun calculateSeriesNumberPenalty(
        localTitle: String,
        localFileName: String,
        resultTitle: String,
        localSeriesNumber: Int?,
    ): Double {
        val localNumbers = (extractSeriesNumbers(localTitle) + extractSeriesNumbers(localFileName)).toMutableSet()
        if (localSeriesNumber != null && localSeriesNumber > 0) localNumbers += localSeriesNumber
        val resultNumbers = extractSeriesNumbers(resultTitle)
        if (localNumbers.isEmpty() || resultNumbers.isEmpty()) return 0.0

        if (resultNumbers.size > 1) {
            val localNum = localNumbers.firstOrNull()
            val minResult = resultNumbers.minOrNull()
            val maxResult = resultNumbers.maxOrNull()
            if (localNum != null && minResult != null && maxResult != null && localNum in minResult..maxResult) {
                return -0.05
            }
        }
        return if (localNumbers.intersect(resultNumbers.toSet()).isNotEmpty()) 0.0 else -0.30
    }

    private fun extractSeriesNumbers(text: String): List<Int> {
        val lower = text.lowercase()
        val numbers = mutableListOf<Int>()
        numbers += extractRomanNumerals(text)
        numbers += extractWrittenNumbers(lower)
        val patterns = listOf(
            "\\b(?:book|bk)\\.?\\s*(\\d+)",
            "\\bvol(?:ume)?\\.?\\s*(\\d+)",
            "\\b(?:part|pt)\\.?\\s*(\\d+)",
            "#(\\d+)",
            "\\b(?:episode|chapter|issue|season)\\s*(\\d+)",
        )
        patterns.forEach { pattern ->
            pattern.toRegex(RegexOption.IGNORE_CASE).findAll(lower).forEach { match ->
                match.groupValues.getOrNull(1)?.toIntOrNull()?.takeIf { it in 1..199 }?.let(numbers::add)
            }
        }
        return numbers.distinct()
    }

    private fun extractRomanNumerals(text: String): List<Int> {
        val pattern = "(?:book|vol(?:ume)?|part|chapter|episode|#|:\\s*)\\s*([IVXLCDM]+)\\b".toRegex(RegexOption.IGNORE_CASE)
        return pattern.findAll(text).mapNotNull { match ->
            romanToInt(match.groupValues[1].uppercase())?.takeIf { it in 1..99 }
        }.toList()
    }

    private fun romanToInt(roman: String): Int? {
        val values = mapOf('I' to 1, 'V' to 5, 'X' to 10, 'L' to 50, 'C' to 100, 'D' to 500, 'M' to 1000)
        var result = 0
        var previous = 0
        roman.reversed().forEach { char ->
            val value = values[char] ?: return null
            if (value < previous) result -= value else result += value
            previous = value
        }
        return result.takeIf { it > 0 }
    }

    private fun extractWrittenNumbers(text: String): List<Int> {
        val written = mapOf(
            "one" to 1, "two" to 2, "three" to 3, "four" to 4, "five" to 5,
            "six" to 6, "seven" to 7, "eight" to 8, "nine" to 9, "ten" to 10,
            "eleven" to 11, "twelve" to 12, "thirteen" to 13, "fourteen" to 14, "fifteen" to 15,
            "sixteen" to 16, "seventeen" to 17, "eighteen" to 18, "nineteen" to 19, "twenty" to 20,
            "twenty-one" to 21, "twenty-two" to 22, "twenty-three" to 23, "twenty-four" to 24, "twenty-five" to 25,
        )
        return written.mapNotNull { (word, value) ->
            if ("(?:book|vol(?:ume)?|part|chapter|episode)\\s+$word\\b".toRegex(RegexOption.IGNORE_CASE).containsMatchIn(text)) value else null
        }
    }

    private fun levenshteinSimilarity(first: String, second: String): Double {
        if (first == second) return 1.0
        val distance = levenshteinDistance(first.lowercase(), second.lowercase())
        val maxLength = max(first.length, second.length)
        if (maxLength == 0) return 1.0
        return 1.0 - distance.toDouble() / maxLength.toDouble()
    }

    private fun levenshteinDistance(first: String, second: String): Int {
        if (first.isEmpty()) return second.length
        if (second.isEmpty()) return first.length

        var previous = IntArray(first.length + 1) { it }
        var current = IntArray(first.length + 1)
        for (j in 1..second.length) {
            current[0] = j
            for (i in 1..first.length) {
                val substitution = if (first[i - 1] == second[j - 1]) 0 else 1
                current[i] = minOf(
                    current[i - 1] + 1,
                    previous[i] + 1,
                    previous[i - 1] + substitution,
                )
            }
            val swap = previous
            previous = current
            current = swap
        }
        return previous[first.length]
    }

    private fun stripDiacritics(value: String): String {
        val normalized = Normalizer.normalize(value, Normalizer.Form.NFD)
        return "\\p{Mn}+".toRegex().replace(normalized, "")
    }
}
