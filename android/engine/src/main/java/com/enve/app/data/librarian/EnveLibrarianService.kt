package com.enve.app.data.librarian

import java.text.BreakIterator
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.min

class EnveLibrarianException(message: String) : Exception(message)

@Singleton
class EnveLibrarianService @Inject constructor(
    private val contextService: EbookContextService,
    private val contextRetriever: BookContextRetriever,
    private val engineManager: LibrarianEngineManager,
) {
    suspend fun answer(
        question: String,
        book: LibrarianBookRef,
        scope: BookIntelligenceScope,
        currentProgress: Double,
    ): LibrarianAnswer {
        val trimmed = question.trim()
        if (trimmed.isBlank()) throw EnveLibrarianException("Ask a question first.")
        contextService.contextFor(book)
        val context = contextRetriever.contextForWithFallback(book, scope, currentProgress, trimmed)
        if (context.isEmpty) throw EnveLibrarianException("Prepare local book context before asking Enve Librarian.")
        val answer = engineManager.answer(trimmed, book, context)
        return answer.copy(text = answer.text.sanitizeLibrarianAnswer())
    }
}

@Singleton
class LocalExtractiveLibrarianEngine @Inject constructor() : LibrarianGenerationEngine {
    override val preference = LibrarianEnginePreference.LOCAL_EXTRACTIVE
    override val title = "Basic Local"

    override suspend fun status(): LibrarianEngineStatus =
        LibrarianEngineStatus(
            preference = preference,
            availability = LibrarianEngineAvailability.AVAILABLE,
            title = title,
            detail = "Always available",
            isUsable = true,
        )

    override suspend fun answer(question: String, book: LibrarianBookRef, context: BookContextResult): LibrarianAnswer {
        val sentences = context.text.sentences()
        if (sentences.isEmpty()) return LibrarianAnswer("I don't see that in the local context just yet.", title)

        val lowered = question.lowercase(Locale.US)
        val selected = when {
            lowered.contains("catch me up") || lowered.contains("summary") || lowered.contains("summarize") ->
                summary(sentences)
            lowered.contains("who") || lowered.contains("involved") || lowered.contains("character") ->
                peopleAnswer(sentences)
            lowered.contains("important") || lowered.contains("details") ->
                detailAnswer(sentences)
            lowered.contains("open thread") || lowered.contains("unresolved") || lowered.contains("mystery") ->
                openThreadsAnswer(sentences)
            else ->
                questionAnswer(question, sentences)
        }

        return LibrarianAnswer(
            text = selected.ifBlank { "The local context does not show that yet." },
            engineTitle = title,
        )
    }

    private fun summary(sentences: List<String>): String =
        buildResponse(
            intro = "Here is what I found in the local context:",
            sentences = sentences.evenlySample(maxItems = 5),
        )

    private fun detailAnswer(sentences: List<String>): String =
        buildResponse(
            intro = "Here are the important details I found in the local context:",
            sentences = sentences.evenlySample(maxItems = 5),
        )

    private fun openThreadsAnswer(sentences: List<String>): String {
        val cues = setOf("why", "how", "whether", "if", "but", "still", "not yet", "unknown", "secret", "mystery", "promise")
        val matches = sentences
            .filter { sentence -> cues.any { sentence.contains(it, ignoreCase = true) } }
            .takeLast(5)
            .ifEmpty { sentences.takeLast(min(4, sentences.size)) }
        return buildResponse("Here are the open threads I can see in the local context:", matches)
    }

    private fun peopleAnswer(sentences: List<String>): String {
        val names = sentences
            .flatMap { namePattern.findAll(it).map { match -> match.value.trim() } }
            .filterNot { it in commonCapitalizedWords }
            .groupingBy { it }
            .eachCount()
            .entries
            .sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key })
            .take(8)
            .map { it.key }
        val evidence = sentences
            .filter { sentence -> names.any { name -> sentence.contains(name) } }
            .takeLast(4)
        return if (names.isEmpty()) {
            buildResponse("I can't clearly identify everyone involved from the local context, but here is what it shows:", sentences.takeLast(4))
        } else {
            val lead = "The local context points to ${names.joinToString(", ")}."
            val support = evidence.takeIf { it.isNotEmpty() }?.let { "\n\n" + buildResponse("Here are the relevant details:", it) }.orEmpty()
            lead + support
        }
    }

    private fun questionAnswer(question: String, sentences: List<String>): String {
        val terms = question
            .lowercase(Locale.US)
            .split(Regex("[^a-z0-9']+"))
            .filter { it.length >= 3 && it !in stopWords }
            .toSet()
        if (terms.isEmpty()) return summary(sentences)

        val ranked = sentences
            .map { sentence ->
                val lower = sentence.lowercase(Locale.US)
                val score = terms.count { lower.contains(it) }
                sentence to score
            }
            .filter { it.second > 0 }
            .sortedByDescending { it.second }
            .map { it.first }
            .take(5)

        if (ranked.isEmpty()) {
            return "I don't see that in the local context just yet."
        }
        return buildResponse("From the local context, here is what I found:", ranked)
    }

    private fun buildResponse(intro: String, sentences: List<String>): String {
        val cleaned = sentences
            .map { it.trim() }
            .filter { it.length > 24 }
            .distinct()
            .take(5)
        if (cleaned.isEmpty()) return ""
        return intro + "\n\n" + cleaned.joinToString("\n") { "- $it" }
    }

    private fun List<String>.evenlySample(maxItems: Int): List<String> {
        if (size <= maxItems) return this
        val result = mutableListOf<String>()
        val step = size.toDouble() / maxItems.toDouble()
        repeat(maxItems) { index ->
            result += this[(index * step).toInt().coerceIn(0, lastIndex)]
        }
        return result
    }

    private fun String.sentences(): List<String> {
        val iterator = BreakIterator.getSentenceInstance(Locale.getDefault())
        iterator.setText(this)
        val result = mutableListOf<String>()
        var start = iterator.first()
        var end = iterator.next()
        while (end != BreakIterator.DONE) {
            substring(start, end)
                .replace(Regex("\\s+"), " ")
                .trim()
                .takeIf { it.length > 20 }
                ?.let { result += it }
            start = end
            end = iterator.next()
        }
        return result
    }

    private companion object {
        val namePattern = Regex("\\b[A-Z][a-z]+(?:\\s+[A-Z][a-z]+){0,2}\\b")
        val commonCapitalizedWords = setOf(
            "The", "A", "An", "I", "He", "She", "They", "We", "It", "This", "That",
            "Chapter", "Page", "Book", "Enve",
        )
        val stopWords = setOf(
            "the", "and", "for", "are", "but", "you", "your", "about", "what", "when",
            "where", "who", "why", "how", "was", "were", "with", "from", "that", "this",
            "there", "their", "them", "then", "than", "have", "has", "had", "does", "did",
        )
    }
}

internal fun String.sanitizeLibrarianAnswer(): String {
    val withoutClosedThinkBlocks = replace(Regex("(?is)<think\\b[^>]*>.*?</think>"), " ")
    val withoutDanglingThinkBlock = withoutClosedThinkBlocks.replace(Regex("(?is)<think\\b[^>]*>.*$"), " ")
    val withoutStrayThinkTags = withoutDanglingThinkBlock
        .replace(Regex("(?is)</?think\\b[^>]*>"), " ")
    return withoutStrayThinkTags
        .replace(Regex("\\n{3,}"), "\n\n")
        .trim()
}
