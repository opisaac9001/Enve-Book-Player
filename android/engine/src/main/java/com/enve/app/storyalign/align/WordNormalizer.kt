package com.enve.app.storyalign.align

import com.enve.app.storyalign.epub.Tokenizer

class WordNormalizer {

    private val emDash = '\u2014'

    private val punctuationMap: Map<Char, Char> = mapOf(
        '“' to '"', '”' to '"', '„' to '"', '‟' to '"',
        '«' to '"', '»' to '"', '〝' to '"', '〞' to '"',
        '‘' to '\'', '’' to '\'', '‚' to '\'', '‛' to '\'',
        '‐' to '-', '‑' to '-', '‒' to '-', '\u2013' to '-',
        '―' to emDash,
        '‹' to '<', '›' to '>',
    )

    fun normalizePunctuation(input: String): String {
        val sb = StringBuilder(input.length)
        for (c in input) sb.append(punctuationMap[c] ?: c)
        return sb.toString().replace("--", emDash.toString())
    }

    private val spelledNumberCache = HashMap<String, String>()

    fun normalizedWord(word: String): Pair<String, Int> {
        val leading = word.takeWhile { it.isWhitespace() }

        val trailingCount = minOf(
            word.reversed().takeWhile { it.isStoryAlignPunct() || it.isWhitespace() }.length,
            word.length - leading.length,
        )
        val trailing = word.substring(word.length - trailingCount)
        val core = word.substring(leading.length, word.length - trailingCount)

        val numberValue: Long? = when {
            core.isNotEmpty() && core.all { it.isDigit() } -> core.toLongOrNull()
            isRomanNumeral(core) -> intFromRomanNumeral(core)?.toLong()
            else -> null
        }

        if (numberValue == null) {
            val parts = core.split(".")
            val leadsWithDot = parts.firstOrNull()?.isEmpty() == true
            val hasDots = parts.size >= 2
            val bodyParts = if (leadsWithDot) parts.drop(1) else parts
            val nonEmptyNumeric = bodyParts.all { it.isNotEmpty() && it.all(Char::isDigit) }
            val hasInternalEmpties = parts.drop(1).any { it.isEmpty() }
            if (hasDots && nonEmptyNumeric && !hasInternalEmpties) {
                val spelledParts = bodyParts.map { spell(it) }
                val body = spelledParts.joinToString(" point ")
                val joined = if (leadsWithDot) "point $body" else body
                if (trailing.contains("%")) {
                    val rest = trailing.replace("%", "")
                    val nw = "$leading$joined percent$rest"
                    return nw to (nw.length - word.length)
                }
                val nw = "$leading$joined$trailing"
                return nw to (nw.length - word.length)
            }
            val afterLeading = word.substring(leading.length)
            if (afterLeading.firstOrNull() == '%' && afterLeading.drop(1).all { it.isStoryAlignPunct() }) {
                val rest = afterLeading.drop(1)
                val nw = "${leading}percent$rest"
                return nw to (nw.length - word.length)
            }
            val normalized = normalizePunctuation(word)
            return normalized to 0
        }

        val spelled = spell(numberValue.toString())
        if (trailing.contains("%")) {
            val rest = trailing.replace("%", "")
            val nw = "$leading$spelled percent$rest"
            return nw to (nw.length - word.length)
        }
        val nw = "$leading$spelled$trailing"
        return nw to (nw.length - word.length)
    }

    fun normalizeWordsInSentence(sentence: String): String {
        val tokens = Tokenizer().tokenizeWords(sentence)
        return tokens.joinToString("") { normalizedWord(it).first }
    }

    private fun spell(digits: String): String {
        spelledNumberCache[digits]?.let { return it }
        val value = digits.toLongOrNull() ?: return digits
        val out = spellCardinal(value)
        spelledNumberCache[digits] = out
        return out
    }

    fun isRomanNumeral(core: String): Boolean {
        if (core.length < 2) return false
        return core.all { it in "IVXLCDMivxlcdm" }
    }

    fun intFromRomanNumeral(s: String): Int? {
        val vals = mapOf('I' to 1, 'V' to 5, 'X' to 10, 'L' to 50, 'C' to 100, 'D' to 500, 'M' to 1000)
        var total = 0
        var prev = 0
        for (c in s.uppercase().reversed()) {
            val v = vals[c] ?: return null
            if (v < prev) total -= v else { total += v; prev = v }
        }
        return total
    }
}

private fun Char.isStoryAlignPunct(): Boolean = when (Character.getType(this)) {
    Character.CONNECTOR_PUNCTUATION.toInt(), Character.DASH_PUNCTUATION.toInt(),
    Character.START_PUNCTUATION.toInt(), Character.END_PUNCTUATION.toInt(),
    Character.INITIAL_QUOTE_PUNCTUATION.toInt(), Character.FINAL_QUOTE_PUNCTUATION.toInt(),
    Character.OTHER_PUNCTUATION.toInt(),
    -> true
    else -> false
}

private val ONES = arrayOf(
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
    "seventeen", "eighteen", "nineteen",
)
private val TENS = arrayOf("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")
private val SCALES = arrayOf("", " thousand", " million", " billion", " trillion", " quadrillion", " quintillion")

internal fun spellCardinal(value: Long): String {
    if (value == 0L) return "zero"
    if (value < 0) return "minus " + spellCardinal(-value)
    val groups = ArrayList<Int>()
    var n = value
    while (n > 0) {
        groups.add((n % 1000).toInt())
        n /= 1000
    }
    val parts = ArrayList<String>()
    for (i in groups.indices.reversed()) {
        val g = groups[i]
        if (g == 0) continue
        parts.add(spellUnder1000(g) + SCALES[i])
    }
    return parts.joinToString(" ")
}

private fun spellUnder1000(n: Int): String {
    val sb = StringBuilder()
    val hundreds = n / 100
    val rest = n % 100
    if (hundreds > 0) {
        sb.append(ONES[hundreds]).append(" hundred")
        if (rest > 0) sb.append(' ')
    }
    if (rest in 1..19) {
        sb.append(ONES[rest])
    } else if (rest >= 20) {
        sb.append(TENS[rest / 10])
        if (rest % 10 > 0) sb.append('-').append(ONES[rest % 10])
    }
    return sb.toString()
}
