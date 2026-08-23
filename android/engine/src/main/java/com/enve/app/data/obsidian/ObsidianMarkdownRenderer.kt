package com.enve.app.data.obsidian

import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.Book
import com.enve.core.data.model.ReaderAnnotation
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

enum class ObsidianUpdatePolicy {
    MAGIC,
    APPEND,
}

object ObsidianMarkdownRenderer {
    private val blockRegex = Regex(
        "<!-- enve-highlight:([^\\s]+) start -->(.*?)<!-- enve-highlight:\\1 end -->",
        setOf(RegexOption.DOT_MATCHES_ALL),
    )

    fun renderBook(
        book: Book,
        bookId: String,
        annotations: List<ReaderAnnotation>,
        exportedAtMs: Long = System.currentTimeMillis(),
    ): String = buildString {
        append("---\n")
        append("title: \"").append(yaml(book.title.ifBlank { bookId })).append("\"\n")
        book.author?.takeIf { it.isNotBlank() }?.let { append("author: \"").append(yaml(it)).append("\"\n") }
        book.seriesName?.takeIf { it.isNotBlank() }?.let { append("series: \"").append(yaml(it)).append("\"\n") }
        book.seriesNumber?.takeIf { it.isNotBlank() }?.let { append("series_number: \"").append(yaml(it)).append("\"\n") }
        append("book_id: \"").append(yaml(bookId)).append("\"\n")
        append("exported_at: \"").append(iso(exportedAtMs)).append("\"\n")
        append("---\n\n")
        append("# ").append(book.title.ifBlank { bookId }).append("\n\n")

        val active = annotations
            .filter { it.deletedAt == null }
            .sortedWith(compareBy<ReaderAnnotation> { it.totalProgression ?: it.progression ?: 0.0 }.thenBy { it.createdAt })
        if (active.isEmpty()) {
            append("_No annotations exported._\n")
            return@buildString
        }

        append("## Highlights\n\n")
        active.forEach { annotation ->
            append(blockFor(annotation)).append("\n\n")
        }
    }.trimEnd() + "\n"

    fun merge(existing: String, rendered: String, policy: ObsidianUpdatePolicy): String {
        if (existing.isBlank()) return rendered
        val existingBlocks = blocksById(existing)
        val renderedBlocks = blocksById(rendered)
        return when (policy) {
            ObsidianUpdatePolicy.MAGIC -> {
                var merged = rendered
                existingBlocks.forEach { (id, block) ->
                    merged = blockRegex.replace(merged) { match ->
                        if (match.groupValues[1] == id) block else match.value
                    }
                }
                merged
            }
            ObsidianUpdatePolicy.APPEND -> {
                val missing = renderedBlocks
                    .filterKeys { it !in existingBlocks }
                    .values
                    .joinToString("\n\n")
                    .trim()
                if (missing.isBlank()) existing
                else existing.trimEnd() + "\n\n## New Enve Exports\n\n" + missing + "\n"
            }
        }
    }

    fun filenameFor(book: Book, bookId: String): String =
        "${safeFilename(book.title).ifBlank { safeFilename(bookId).ifBlank { "Book" } }}.md"

    private fun blockFor(annotation: ReaderAnnotation): String = buildString {
        append("<!-- enve-highlight:").append(annotation.id).append(" start -->\n")
        if (annotation.selectedText.isNotBlank()) {
            annotation.selectedText.lines().forEach { line ->
                append("> ").append(line).append("\n")
            }
            append("\n")
        }
        if (annotation.note.isNotBlank()) {
            append("**Note:** ").append(annotation.note).append("\n\n")
        }
        val details = listOfNotNull(
            AnnotationKind.parse(annotation.kind).label.takeIf { it.isNotBlank() },
            annotation.chapterId?.takeIf { it.isNotBlank() },
            annotation.totalProgression?.let { "${(it * 100.0).toInt()}%" },
        )
        if (details.isNotEmpty()) append("_").append(details.joinToString(" - ")).append("_\n")
        append("<!-- enve-highlight:").append(annotation.id).append(" end -->")
    }.trim()

    private fun blocksById(markdown: String): Map<String, String> =
        blockRegex.findAll(markdown).associate { it.groupValues[1] to it.value }

    private fun safeFilename(raw: String): String =
        raw.trim()
            .replace(Regex("[\\\\/:*?\"<>|]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim('.', ' ')
            .take(96)
            .trim()

    private fun yaml(value: String): String =
        value.replace("\\", "\\\\").replace("\"", "\\\"")

    private fun iso(epochMs: Long): String =
        DateTimeFormatter.ISO_INSTANT.format(Instant.ofEpochMilli(epochMs).atOffset(ZoneOffset.UTC))
}
