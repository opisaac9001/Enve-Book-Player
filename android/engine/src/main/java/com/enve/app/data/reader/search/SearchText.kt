package com.enve.app.data.reader.search

import java.text.Normalizer

internal data class NormalizedSearchText(val value: String, val starts: IntArray, val ends: IntArray)

internal object SearchText {
    const val MAX_QUERY_LENGTH = 200
    const val CHUNK_OVERLAP = MAX_QUERY_LENGTH * 2
    const val CHUNK_SIZE = 4_000

    fun normalize(value: String): NormalizedSearchText {
        val folded = StringBuilder(value.length)
        val starts = ArrayList<Int>(value.length)
        val ends = ArrayList<Int>(value.length)
        var offset = 0
        while (offset < value.length) {
            val cp = value.codePointAt(offset)
            val end = offset + Character.charCount(cp)
            if (cp in 32..126) {
                val char = cp.toChar().lowercaseChar()
                if (char == ' ' && folded.endsWith(" ")) {
                    ends[ends.lastIndex] = end
                } else {
                    folded.append(char)
                    starts += offset
                    ends += end
                }
                offset = end
                continue
            }
            val decomposed = if (cp < 128) cp.toChar().toString()
                else Normalizer.normalize(String(Character.toChars(cp)), Normalizer.Form.NFD)
            var index = 0
            while (index < decomposed.length) {
                val part = decomposed.codePointAt(index)
                index += Character.charCount(part)
                val type = Character.getType(part)
                if (type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt() ||
                    type == Character.ENCLOSING_MARK.toInt()
                ) {
                    if (ends.isNotEmpty()) ends[ends.lastIndex] = end
                    continue
                }
                val chars = if (Character.isWhitespace(part) || Character.isSpaceChar(part)) " "
                    else String(Character.toChars(Character.toLowerCase(part)))
                if (chars == " " && folded.endsWith(" ")) {
                    ends[ends.lastIndex] = end
                    continue
                }
                folded.append(chars)
                repeat(chars.length) {
                    starts += offset
                    ends += end
                }
            }
            offset = end
        }
        return NormalizedSearchText(folded.toString(), starts.toIntArray(), ends.toIntArray())
    }

    fun fold(value: String): String {
        val decomposed = Normalizer.normalize(value, Normalizer.Form.NFD)
        val folded = StringBuilder(decomposed.length)
        var index = 0
        while (index < decomposed.length) {
            val cp = decomposed.codePointAt(index)
            index += Character.charCount(cp)
            val type = Character.getType(cp)
            if (type == Character.NON_SPACING_MARK.toInt() || type == Character.COMBINING_SPACING_MARK.toInt() ||
                type == Character.ENCLOSING_MARK.toInt()
            ) continue
            if (Character.isWhitespace(cp) || Character.isSpaceChar(cp)) {
                if (!folded.endsWith(" ")) folded.append(' ')
            } else {
                folded.appendCodePoint(Character.toLowerCase(cp))
            }
        }
        return folded.toString()
    }
    fun collapse(value: String): String = value.trim().replace(Regex("\\s+"), " ")
    fun isAscii(value: String): Boolean = value.all { it.code < 128 }
    fun asciiTokens(value: String): List<String> = Regex("[a-zA-Z0-9]+").findAll(value).map { it.value }.toList()
    fun ftsPhrase(tokens: List<String>): String = tokens.joinToString(" ", "\"", "\"")

    fun chunkStarts(length: Int): List<Int> {
        if (length == 0) return emptyList()
        val starts = mutableListOf(0)
        while (starts.last() + CHUNK_SIZE < length) starts += starts.last() + CHUNK_SIZE - CHUNK_OVERLAP
        return starts
    }

    fun matches(folded: String, foldedQuery: String, wholeWords: Boolean, minMatchEnd: Int, limit: Int): List<Int> {
        if (foldedQuery.isEmpty() || limit <= 0) return emptyList()
        val offsets = mutableListOf<Int>()
        var from = 0
        while (offsets.size < limit) {
            val start = folded.indexOf(foldedQuery, from)
            if (start < 0) break
            val end = start + foldedQuery.length
            from = start + 1
            if (end <= minMatchEnd) continue
            if (wholeWords && ((start > 0 && Character.isLetterOrDigit(folded.codePointBefore(start))) ||
                    (end < folded.length && Character.isLetterOrDigit(folded.codePointAt(end))))) continue
            offsets += start
        }
        return offsets
    }

}
