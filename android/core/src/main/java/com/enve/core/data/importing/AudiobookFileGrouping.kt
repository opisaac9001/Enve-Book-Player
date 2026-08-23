package com.enve.core.data.importing

object AudiobookFileGrouping {
    const val MINIMUM_STANDALONE_BOOK_SIZE_BYTES: Long = 64L * 1_024L * 1_024L

    fun <T> groups(
        files: List<T>,
        name: (T) -> String,
        sizeBytes: (T) -> Long = { 0L },
        forcedStandalone: (T) -> Boolean = { false },
    ): List<List<T>> {
        if (files.size <= 1) return files.map(::listOf)

        val sortedFiles = sorted(files, name)
        val hasFilenameChapterEvidence = sortedFiles.any { chapterGroupingKey(name(it)) != null }
        val standaloneBooks = sortedFiles.filter { file ->
            val fileName = name(file)
            val hasChapterEvidence = chapterGroupingKey(fileName) != null
            forcedStandalone(file) ||
                isExplicitBook(fileName) ||
                (!hasChapterEvidence && extension(fileName) in selfContainedExtensions) ||
                (!hasFilenameChapterEvidence && sizeBytes(file) >= MINIMUM_STANDALONE_BOOK_SIZE_BYTES)
        }
        val standaloneNames = standaloneBooks.mapTo(mutableSetOf()) { name(it).lowercase() }
        val candidates = sortedFiles.filterNot { name(it).lowercase() in standaloneNames }
        if (candidates.isEmpty()) return standaloneBooks.map(::listOf)

        val explicitKeys = candidates.mapNotNull { chapterGroupingKey(name(it)) }.toSet()
        val defaultKey = explicitKeys.singleOrNull() ?: "multipart:ambiguous"
        val grouped = candidates.groupBy { chapterGroupingKey(name(it)) ?: defaultKey }
        return (standaloneBooks.map(::listOf) + grouped.values.map { sorted(it, name) })
            .sortedBy { group -> group.firstOrNull()?.let(name)?.lowercase().orEmpty() }
    }

    fun <T> sorted(files: List<T>, name: (T) -> String): List<T> =
        files.sortedWith(
            compareBy<T> { sequencePosition(name(it)).category }
                .thenBy { sequencePosition(name(it)).number }
                .thenBy { stem(name(it)).lowercase() }
                .thenBy { extension(name(it)) },
        )

    fun inferredTitle(fileName: String): String {
        val stem = stem(fileName)
        if (multipartStem(fileName) == null) return stem
        return stem.replace(trailingSequenceRegex, "").ifBlank { stem }
    }

    private fun chapterGroupingKey(fileName: String): String? {
        chapterSequencePrefix(fileName)?.let { prefix ->
            return if (prefix.isEmpty()) "multipart:chapter-sequence" else "multipart:chapter-sequence:$prefix"
        }
        if (leadingNumberRegex.containsMatchIn(stem(fileName))) return "multipart:chapter-sequence"
        return multipartStem(fileName)?.let { "multipart:$it" }
    }

    private fun chapterSequencePrefix(fileName: String): String? {
        val stem = stem(fileName)
        val match = chapterSequenceRegex.find(stem) ?: return null
        return normalizeTitle(stem.substring(0, match.range.first))
    }

    private fun multipartStem(fileName: String): String? {
        var normalized = normalizeTitle(stem(fileName))
        listOf("unabridged", "audiobook", "audio book").forEach { word ->
            normalized = normalized.replace(word, " ")
        }
        val tokens = normalizeTitle(normalized).split(' ').filter(String::isNotBlank)
        val number = tokens.lastOrNull()?.takeIf { token -> token.all(Char::isDigit) } ?: return null
        val hasPartMarker = tokens.dropLast(1).lastOrNull() in partMarkers
        if (number.length < 2 && !hasPartMarker) return null
        return tokens.dropLast(1).joinToString(" ").ifBlank { null }
    }

    private fun isExplicitBook(fileName: String): Boolean {
        val stem = stem(fileName)
        return chapterSequencePrefix(fileName) == null &&
            !leadingNumberRegex.containsMatchIn(stem) &&
            explicitBookRegex.containsMatchIn(stem)
    }

    private fun sequencePosition(fileName: String): SequencePosition {
        val normalized = normalizeTitle(stem(fileName))
        if (normalized in openingTitles) return SequencePosition(0, 0)
        val numbered = chapterSequenceRegex.find(stem(fileName))?.groupValues?.get(1)?.toIntOrNull()
            ?: leadingNumberCaptureRegex.find(stem(fileName))?.groupValues?.get(1)?.toIntOrNull()
        if (numbered != null) return SequencePosition(1, numbered)
        if (normalized in closingTitles) return SequencePosition(3, 0)
        return SequencePosition(2, 0)
    }

    private fun normalizeTitle(value: String): String =
        value.lowercase().replace(nonWordRegex, " ").trim()

    private fun extension(fileName: String): String = fileName.substringAfterLast('.', "").lowercase()

    private fun stem(fileName: String): String = fileName.substringBeforeLast('.', fileName)

    private data class SequencePosition(val category: Int, val number: Int)

    private val selfContainedExtensions = setOf("m4b", "m4a", "mp4")
    private val partMarkers = setOf("part", "track", "chapter", "disc", "cd")
    private val openingTitles = setOf("opening credits", "intro", "introduction", "prologue")
    private val closingTitles = setOf("credits", "closing credits", "end credits", "epilogue")
    private val explicitBookRegex = Regex("""\b(?:book|volume|vol)[\s._#-]*\d+\b""", RegexOption.IGNORE_CASE)
    private val chapterSequenceRegex = Regex("""\b(?:chapter|track|part|disc|cd)[\s._#-]*(\d+)\b""", RegexOption.IGNORE_CASE)
    private val leadingNumberRegex = Regex("""^\s*\d+\b""")
    private val leadingNumberCaptureRegex = Regex("""^\s*(\d+)\b""")
    private val trailingSequenceRegex = Regex("""(?i)[\s._-]+(?:(?:part|track|chapter|disc|cd)[\s._-]*)?\d+$""")
    private val nonWordRegex = Regex("""[\W_]+""")
}
