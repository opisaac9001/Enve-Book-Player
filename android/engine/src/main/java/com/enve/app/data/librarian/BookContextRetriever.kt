package com.enve.app.data.librarian

import javax.inject.Inject
import javax.inject.Singleton
import java.util.Locale
import kotlin.math.roundToInt

@Singleton
class BookContextRetriever @Inject constructor(
    private val contextStore: EbookContextStore,
) {
    suspend fun contextForWithFallback(
        book: LibrarianBookRef,
        scope: BookIntelligenceScope,
        currentProgress: Double,
        question: String,
    ): BookContextResult {
        val chunks = contextStore.load(book.stableId)?.chunks.orEmpty().sortedBy { it.startProgress }
        val orderedScopes = fallbackScopes(scope)
        var best = bestContextForScope(chunks, orderedScopes.first(), currentProgress, question)
        if (!best.isLikelyTooNarrowForGemini) return best

        orderedScopes
            .drop(1)
            .forEach { fallbackScope ->
                val fallback = bestContextForScope(chunks, fallbackScope, currentProgress, question)
                if (fallback.approxTokenCount() >= MIN_GEMINI_CONTEXT_TOKENS) return fallback
                if (fallback.betterThan(best, question)) best = fallback
            }

        return best
    }

    suspend fun contextFor(
        book: LibrarianBookRef,
        scope: BookIntelligenceScope,
        currentProgress: Double,
    ): BookContextResult {
        val chunks = contextStore.load(book.stableId)?.chunks.orEmpty().sortedBy { it.startProgress }
        return contextFor(chunks, scope, currentProgress)
    }

    private fun bestContextForScope(
        chunks: List<EbookContextChunk>,
        scope: BookIntelligenceScope,
        currentProgress: Double,
        question: String,
    ): BookContextResult {
        val scoped = contextFor(chunks, scope, currentProgress)
        val retrieved = retrievedContextFor(chunks, scope, currentProgress, question)
        return when {
            retrieved == null -> scoped
            retrieved.betterThan(scoped, question) -> retrieved
            else -> scoped
        }
    }

    private fun contextFor(
        chunks: List<EbookContextChunk>,
        scope: BookIntelligenceScope,
        currentProgress: Double,
    ): BookContextResult {
        val range = rangeForScope(scope, currentProgress.coerceIn(0.0, 1.0), chunks)
        val selected = chunks.filter { it.endProgress >= range.start && it.startProgress <= range.end }
        val text = selected
            .mapNotNull { chunk ->
                val bounded = boundedText(chunk, range.start, range.end).trim()
                if (bounded.isBlank()) return@mapNotNull null
                val title = chunk.title?.trim()?.takeIf { it.isNotBlank() }
                if (title == null) bounded else "[$title] $bounded"
            }
            .joinToString("\n\n")

        return BookContextResult(
            scope = scope,
            rangeStart = range.start,
            rangeEnd = range.end,
            text = trimContext(text),
            chunkCount = selected.size,
        )
    }

    private fun retrievedContextFor(
        chunks: List<EbookContextChunk>,
        scope: BookIntelligenceScope,
        currentProgress: Double,
        question: String,
    ): BookContextResult? {
        val query = question.trim()
        if (query.isBlank() || chunks.isEmpty()) return null

        val progress = currentProgress.coerceIn(0.0, 1.0)
        val range = rangeForScope(scope, progress, chunks)
        val terms = questionTerms(query)
        val entityHint = entityHint(query)

        val scored = chunks.mapIndexedNotNull { listIndex, chunk ->
            if (chunk.startProgress > progress + 0.0001) return@mapIndexedNotNull null
            if (chunk.endProgress < range.start || chunk.startProgress > range.end) return@mapIndexedNotNull null
            val bounded = boundedText(chunk, range.start, range.end).trim()
            if (bounded.isBlank()) return@mapIndexedNotNull null
            val score = scoreChunk(bounded, terms, entityHint, chunk, range)
            if (score <= 0) return@mapIndexedNotNull null
            ScoredChunk(chunk = chunk, boundedText = bounded, score = score, listIndex = listIndex)
        }
        if (scored.isEmpty()) return null

        val selectedIndices = linkedSetOf<Int>()
        scored.sortedByDescending { it.score }
            .take(RETRIEVAL_PRIMARY_MATCHES)
            .forEach { match ->
                val index = match.listIndex
                selectedIndices += index
                if (index > 0) selectedIndices += index - 1
                selectedIndices += index + 1
            }

        val selected = chunks
            .filterIndexed { index, _ -> index in selectedIndices }
            .filter { it.startProgress <= progress + 0.0001 }
            .filter { it.endProgress >= range.start && it.startProgress <= range.end }
            .sortedBy { it.index }
            .mapNotNull { chunk ->
                val bounded = boundedText(chunk, range.start, range.end).trim()
                if (bounded.isBlank()) return@mapNotNull null
                val title = chunk.title?.trim()?.takeIf { it.isNotBlank() }
                if (title == null) bounded else "[$title] $bounded"
            }
        if (selected.isEmpty()) return null

        val text = selected
            .joinToString("\n\n")
            .take(RETRIEVAL_CONTEXT_CHARS)
            .trim()
        if (text.isBlank()) return null

        return BookContextResult(
            scope = scope,
            rangeStart = range.start,
            rangeEnd = range.end,
            text = text,
            chunkCount = selected.size,
        )
    }

    private fun fallbackScopes(scope: BookIntelligenceScope): List<BookIntelligenceScope> = when (scope) {
        BookIntelligenceScope.PREVIOUS_CHAPTER -> listOf(
            BookIntelligenceScope.PREVIOUS_CHAPTER,
            BookIntelligenceScope.CURRENT_CHAPTER_SO_FAR,
            BookIntelligenceScope.BOOK_SO_FAR,
        )
        BookIntelligenceScope.CURRENT_CHAPTER_SO_FAR -> listOf(
            BookIntelligenceScope.CURRENT_CHAPTER_SO_FAR,
            BookIntelligenceScope.BOOK_SO_FAR,
        )
        BookIntelligenceScope.RECENT_PAGES -> listOf(
            BookIntelligenceScope.RECENT_PAGES,
            BookIntelligenceScope.CURRENT_CHAPTER_SO_FAR,
            BookIntelligenceScope.BOOK_SO_FAR,
        )
        BookIntelligenceScope.BOOK_SO_FAR -> listOf(BookIntelligenceScope.BOOK_SO_FAR)
    }

    fun catchUpRange(currentProgress: Double, chunks: List<EbookContextChunk>): ProgressRange {
        val progress = currentProgress.coerceIn(0.0, 1.0)
        val sorted = chunks.sortedBy { it.startProgress }
        if (sorted.isEmpty()) return ProgressRange((progress - 0.05).coerceAtLeast(0.0), progress)
        val currentIndex = chunkIndex(progress, sorted) ?: 0
        if (currentIndex <= 0) return ProgressRange((progress - 0.05).coerceAtLeast(0.0), progress)
        val previous = sorted[currentIndex - 1]
        return ProgressRange((previous.endProgress - 0.05).coerceAtLeast(previous.startProgress), previous.endProgress)
    }

    private fun rangeForScope(
        scope: BookIntelligenceScope,
        currentProgress: Double,
        chunks: List<EbookContextChunk>,
    ): ProgressRange {
        if (chunks.isEmpty()) return ProgressRange(currentProgress, currentProgress)
        val currentIndex = chunkIndex(currentProgress, chunks) ?: 0
        val current = chunks[currentIndex]
        return when (scope) {
            BookIntelligenceScope.RECENT_PAGES ->
                ProgressRange((currentProgress - 0.05).coerceAtLeast(0.0), currentProgress)
            BookIntelligenceScope.BOOK_SO_FAR ->
                ProgressRange(0.0, currentProgress)
            BookIntelligenceScope.CURRENT_CHAPTER_SO_FAR ->
                ProgressRange(current.startProgress, minOf(currentProgress, current.endProgress))
            BookIntelligenceScope.PREVIOUS_CHAPTER -> {
                if (currentIndex <= 0) ProgressRange(0.0, currentProgress)
                else {
                    val previous = chunks[currentIndex - 1]
                    ProgressRange(previous.startProgress, previous.endProgress)
                }
            }
        }
    }

    private fun chunkIndex(progress: Double, chunks: List<EbookContextChunk>): Int? {
        var best: Int? = null
        for (index in chunks.indices) {
            if (chunks[index].startProgress <= progress + 0.0001) best = index else break
        }
        return best
    }

    private fun boundedText(chunk: EbookContextChunk, lower: Double, upper: Double): String {
        val span = (chunk.endProgress - chunk.startProgress).coerceAtLeast(0.0001)
        val words = chunk.text.split(Regex("\\s+")).filter { it.isNotBlank() }
        if (words.isEmpty()) return chunk.text

        val startFraction = if (lower > chunk.startProgress + 0.0001) {
            ((lower - chunk.startProgress) / span).coerceIn(0.0, 1.0)
        } else {
            0.0
        }
        val endFraction = if (upper < chunk.endProgress - 0.0001) {
            ((upper - chunk.startProgress) / span).coerceIn(0.0, 1.0)
        } else {
            1.0
        }
        val startIndex = (words.size * startFraction).roundToInt().coerceIn(0, words.lastIndex)
        val endIndex = (words.size * endFraction).roundToInt().coerceIn(startIndex + 1, words.size)
        return words.subList(startIndex, endIndex).joinToString(" ")
    }

    private fun trimContext(text: String): String {
        val maxCharacters = 12_000
        return if (text.length <= maxCharacters) text else text.takeLast(maxCharacters)
    }
}

private val BookContextResult.isLikelyTooNarrowForGemini: Boolean
    get() = isEmpty || chunkCount <= 1 || approxTokenCount() < MIN_GEMINI_CONTEXT_TOKENS

data class ProgressRange(
    val start: Double,
    val end: Double,
)

private const val MIN_GEMINI_CONTEXT_TOKENS = 1_000
private const val RETRIEVAL_CONTEXT_CHARS = 8_000
private const val RETRIEVAL_PRIMARY_MATCHES = 4

private data class ScoredChunk(
    val chunk: EbookContextChunk,
    val boundedText: String,
    val score: Int,
    val listIndex: Int,
)

private fun BookContextResult.approxTokenCount(): Int = text.approxTokenCount()

private fun BookContextResult.betterThan(other: BookContextResult, question: String): Boolean {
    val thisScore = text.retrievalScore(question)
    val otherScore = other.text.retrievalScore(question)
    return when {
        thisScore != otherScore -> thisScore > otherScore
        approxTokenCount() != other.approxTokenCount() -> approxTokenCount() > other.approxTokenCount()
        else -> chunkCount > other.chunkCount
    }
}

private fun String.approxTokenCount(): Int {
    if (isBlank()) return 0
    return split(Regex("""[\s]+"""))
        .asSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .sumOf { chunk ->
            val pieces = Regex("""[\p{L}\p{N}]+|[^\p{L}\p{N}\s]""").findAll(chunk).count()
            pieces.takeIf { it > 0 } ?: 1
        }
}

private fun questionTerms(question: String): Set<String> =
    question.lowercase(Locale.US)
        .split(Regex("[^a-z0-9']+"))
        .filter { it.length >= 3 && it !in retrievalStopWords }
        .toSet()

private fun entityHint(question: String): String? {
    val normalized = question.replace(Regex("\\s+"), " ").trim()
    val patterns = listOf(
        Regex("""(?i)\bwho\s+(?:is|was|are|were)\s+(.+?)\??$"""),
        Regex("""(?i)\btell me about\s+(.+?)\??$"""),
        Regex("""(?i)\bwhat do we know about\s+(.+?)\??$"""),
        Regex("""(?i)\bwhat about\s+(.+?)\??$"""),
    )
    val raw = patterns.asSequence()
        .mapNotNull { it.find(normalized)?.groupValues?.getOrNull(1) }
        .firstOrNull()
        ?.trim()
        ?.trimEnd('?', '.', '!', ',')
        ?.takeIf { it.length >= 2 }
        ?: return null
    return raw.lowercase(Locale.US)
}

private fun scoreChunk(
    text: String,
    terms: Set<String>,
    entityHint: String?,
    chunk: EbookContextChunk,
    range: ProgressRange,
): Int {
    val lower = text.lowercase(Locale.US)
    var score = 0
    if (entityHint != null && lower.contains(entityHint)) {
        score += 12
    }
    terms.forEach { term ->
        if (lower.contains(term)) score += 2
    }
    if (entityHint != null && chunk.title?.contains(entityHint, ignoreCase = true) == true) score += 6
    if (chunk.title?.let { title -> terms.any { title.contains(it, ignoreCase = true) } } == true) score += 3
    if (chunk.startProgress <= range.end && chunk.endProgress >= range.start) score += 1
    return score
}

private fun String.retrievalScore(question: String): Int {
    val terms = questionTerms(question)
    val entityHint = entityHint(question)
    val lower = lowercase(Locale.US)
    var score = 0
    if (entityHint != null && lower.contains(entityHint)) score += 12
    terms.forEach { term -> if (lower.contains(term)) score += 2 }
    return score
}

private val retrievalStopWords = setOf(
    "about",
    "after",
    "again",
    "book",
    "chapter",
    "does",
    "from",
    "have",
    "into",
    "just",
    "know",
    "like",
    "look",
    "mean",
    "more",
    "people",
    "said",
    "such",
    "tell",
    "than",
    "that",
    "them",
    "then",
    "they",
    "this",
    "what",
    "when",
    "where",
    "which",
    "with",
    "would",
    "your",
)
