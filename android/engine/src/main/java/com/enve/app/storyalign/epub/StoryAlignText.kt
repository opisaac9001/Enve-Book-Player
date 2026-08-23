package com.enve.app.storyalign.epub

import com.enve.engine.storyalign.StoryAlignGranularity
import java.text.BreakIterator
import java.util.Locale

val StoryAlignGranularity.useWordTokenizer: Boolean
    get() = this == StoryAlignGranularity.SEGMENT ||
        this == StoryAlignGranularity.GROUP ||
        this == StoryAlignGranularity.WORD

object HTMLTags {
    private val contentSectioning = setOf(
        "address", "article", "aside", "footer", "header",
        "h1", "h2", "h3", "h4", "h5", "h6", "hgroup", "main", "nav", "section", "search",
    )
    private val textContent = setOf(
        "blockquote", "dd", "div", "dl", "dt", "figcaption", "figure",
        "hr", "li", "menu", "ol", "p", "pre", "ul",
    )
    private val tableParts = setOf(
        "table", "thead", "th", "tbody", "tr", "td", "colgroup", "caption", "tfoot",
    )
    val inline = setOf("span", "strong", "i", "em", "b", "u")
    val blocks: Set<String> = textContent + contentSectioning + tableParts
}

class Tokenizer {
    fun tokenizeSentences(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        val it = BreakIterator.getSentenceInstance(Locale.US)
        it.setText(text)
        val out = ArrayList<String>()
        var start = it.first()
        var end = it.next()
        while (end != BreakIterator.DONE) {
            val sentence = text.substring(start, end)
            if (sentence.trim().isNotEmpty()) out.add(sentence)
            start = end
            end = it.next()
        }
        return out
    }

    fun tokenizeWords(input: String): List<String> {
        if (input.isEmpty()) return emptyList()
        val tokens = ArrayList<String>()
        var from = 0
        var i = 0
        while (i < input.length) {
            val ch = input[i]
            if (!isSeparator(ch)) {
                i++
                continue
            }
            val head = input.substring(from, i)
            val delim = ch.toString()
            if (head.isNotEmpty()) {
                tokens.add(head + delim)
            } else if (tokens.isEmpty()) {
                tokens.add(delim)
            } else {
                tokens[tokens.size - 1] = tokens[tokens.size - 1] + delim
            }
            i++
            from = i
        }
        if (from < input.length) tokens.add(input.substring(from))
        return coalescePunctOnlyWords(tokens).filter { it.trim().isNotEmpty() }
    }

    fun tokenizePhrases(text: String): List<String> {
        if (text.isEmpty()) return emptyList()
        val phraseSeparators = setOf(',', ':', ';', '\u2014')
        val minWordsForPhrase = 2
        val sentences = tokenizeSentences(text)
        return sentences.flatMap { sentence ->
            val words = tokenizeWords(sentence)
            val phrases = ArrayList<String>()
            var phraseWords = ArrayList<String>()
            for ((index, word) in words.withIndex()) {
                if (word.isEmpty()) continue
                phraseWords.add(word)
                if (phraseWords.size < minWordsForPhrase) continue
                if (index >= words.size - 2) continue
                val lastChar = word.trim().lastOrNull()
                if (lastChar != null && lastChar in phraseSeparators) {
                    phrases.add(phraseWords.joinToString(""))
                    phraseWords = ArrayList()
                }
            }
            if (phraseWords.isNotEmpty()) phrases.add(phraseWords.joinToString(""))
            phrases
        }
    }

    private fun coalescePunctOnlyWords(words: List<String>): List<String> {
        val out = ArrayList<String>()
        var leading = StringBuilder()
        for (w in words) {
            if (w.isAllWhiteSpaceOrPunct) {
                if (out.isEmpty()) leading.append(w) else out[out.size - 1] = out[out.size - 1] + w
                continue
            }
            if (leading.isNotEmpty()) {
                out.add(leading.toString() + w)
                leading = StringBuilder()
            } else {
                out.add(w)
            }
        }
        if (leading.isNotEmpty()) out.add(leading.toString())
        return out
    }

    private fun isSeparator(ch: Char): Boolean {
        if (ch.isWhitespace()) return true
        return when (ch.code) {
            0x2014, 0x002C, 0x003B, 0x0021, 0x003F, 0x007C -> true
            else -> false
        }
    }
}

internal val String.isAllWhiteSpaceOrPunct: Boolean
    get() = all { it.isWhitespace() || it.isStoryAlignPunctuation() }

internal fun Char.isStoryAlignPunctuation(): Boolean = when (Character.getType(this)) {
    Character.CONNECTOR_PUNCTUATION.toInt(),
    Character.DASH_PUNCTUATION.toInt(),
    Character.START_PUNCTUATION.toInt(),
    Character.END_PUNCTUATION.toInt(),
    Character.INITIAL_QUOTE_PUNCTUATION.toInt(),
    Character.FINAL_QUOTE_PUNCTUATION.toInt(),
    Character.OTHER_PUNCTUATION.toInt(),
    -> true
    else -> false
}

internal fun String.removingFragment(): String = substringBefore('#')

internal fun String.deletingLastPathComponent(delimiter: String = "/"): String {
    if (delimiter.isEmpty()) return ""
    val comps = split(delimiter)
    if (comps.isEmpty()) return ""
    return comps.dropLast(1).joinToString(delimiter)
}

internal fun String.lastPathComponent(delimiter: String = "/"): String {
    if (delimiter.isEmpty()) return ""
    var s = this
    while (s.endsWith(delimiter)) s = s.dropLast(delimiter.length)
    if (s.isEmpty()) return ""
    return s.split(delimiter).lastOrNull() ?: ""
}

internal fun String.appendingPathComponent(component: String, delimiter: String = "/"): String {
    if (component.isEmpty()) return this
    if (isEmpty()) return component
    val d = delimiter[0]
    var comp = component
    if (comp.firstOrNull() == d) comp = comp.substring(1)
    return if (lastOrNull() == d) this + comp else this + delimiter + comp
}

internal fun resolvePath(baseDir: String, href: String): String {
    val cleaned = href.removingFragment().let {
        runCatching { java.net.URLDecoder.decode(it, "UTF-8") }.getOrDefault(it)
    }
    val combined = if (cleaned.startsWith("/")) cleaned.removePrefix("/")
    else if (baseDir.isEmpty()) cleaned else "$baseDir/$cleaned"
    val stack = ArrayDeque<String>()
    for (part in combined.split("/")) {
        when (part) {
            "", "." -> {}
            ".." -> if (stack.isNotEmpty()) stack.removeLast()
            else -> stack.addLast(part)
        }
    }
    return stack.joinToString("/")
}
