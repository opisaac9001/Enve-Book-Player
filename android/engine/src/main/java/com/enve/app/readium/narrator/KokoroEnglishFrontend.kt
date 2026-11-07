package com.enve.app.readium.narrator

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.icu.text.MessageFormat
import android.util.JsonReader
import android.util.JsonToken
import java.io.File
import java.text.Normalizer
import java.util.Locale

class KokoroEnglishFrontend(directory: File) : AutoCloseable {

    private val sidecar = Sidecar.parse(File(directory, "misaki-en_us-g2p.json"))
    private val environment: OrtEnvironment = OrtEnvironment.getEnvironment()
    private val session: OrtSession = OrtSession.SessionOptions().use { options ->
        environment.createSession(File(directory, "misaki-en_us-g2p.onnx").absolutePath, options)
    }
    private val graphemeIds: Map<Char, Long> =
        sidecar.graphemes.withIndex().associate { (index, char) -> char to index.toLong() }
    private val minPhonemeId =
        maxOf(sidecar.startId, sidecar.bosId, sidecar.eosId, sidecar.unknownId) + 1
    private val cardinal = MessageFormat("{0,spellout}", Locale.US)
    private val ordinal = MessageFormat("{0,spellout,%spellout-ordinal}", Locale.US)

    fun phonemes(text: String): IntArray {
        val prepared = spellNumbers(Normalizer.normalize(text, Normalizer.Form.NFKC))
        val tokens = TOKEN.findAll(prepared).map { it.value }.toList()
        val out = StringBuilder()
        for ((index, raw) in tokens.withIndex()) {
            if (raw.length == 1 && raw[0] in PUNCTUATION) {
                out.append(raw)
                continue
            }
            val token = SYMBOL_WORDS[raw] ?: raw
            if (!token.first().isLetter()) continue
            val ps = wordPhonemes(token.replace('’', '\''), nextWord(tokens, index))
            if (ps.isEmpty()) continue
            if (out.isNotEmpty() && out.last() !in NO_SPACE_AFTER) out.append(' ')
            out.append(ps)
        }
        return out.toString().codePoints().filter { sidecar.kokoroCodepoints.contains(it) }.toArray()
    }

    override fun close() {
        session.close()
    }

    private fun wordPhonemes(word: String, following: String?): String {
        specialCase(word, following)?.let { return it }
        val stress = when {
            word == word.lowercase() -> null
            word == word.uppercase() -> 2.0
            else -> 0.5
        }
        val folded = asciiFold(word)
        val candidates = listOf(word, word.lowercase(), folded, folded.lowercase())
            .filter { it.isNotEmpty() }
            .distinct()
        for (candidate in candidates) {
            lexical(candidate, stress)?.let { return it }
        }
        val oov = folded.ifEmpty { word }
        if (oov.length <= MAX_G2P_INPUT) {
            fallback(oov).takeIf { it.isNotEmpty() }?.let { return it }
        }
        return letters(oov) ?: ""
    }

    private fun specialCase(word: String, following: String?): String? {
        if (word == word.uppercase() && word.length > 1) return null
        val key = if (word == "a" || word == "A" || word == "I") word else word.lowercase()
        val vowelNext = following?.let { it.first().lowercaseChar() in "aeiou" }
        return when (key) {
            "the" -> if (vowelNext == true) "ði" else "ðə"
            "to" -> when (vowelNext) {
                null -> sidecar.gold.getValue("to")
                true -> "tʊ"
                false -> "tə"
            }
            "an" -> "ɐn"
            "a", "A" -> if (vowelNext == null) "${PRIMARY}A" else "ɐ"
            "I" -> "${SECONDARY}I"
            else -> null
        }
    }

    private fun lexical(word: String, stress: Double?): String? {
        if (known(word)) return lookup(word, stress)
        if (word.endsWith("'") && known(word.dropLast(1))) return lookup(word.dropLast(1), stress)
        return stemS(word, stress) ?: stemEd(word, stress) ?: stemIng(word, stress)
    }

    private fun known(word: String): Boolean {
        if (entry(sidecar.gold, word) != null || entry(sidecar.silver, word) != null) return true
        val letters = word.replace("'", "")
        if (letters.isEmpty() || !letters.all { it.isLetter() } || word.any { it.code > 127 }) return false
        return word.length == 1 ||
            (word == word.uppercase() && entry(sidecar.gold, word.lowercase()) != null) ||
            word.drop(1) == word.drop(1).uppercase()
    }

    private fun lookup(rawWord: String, stress: Double?): String? {
        var word = rawWord
        var proper = false
        if (word == word.uppercase() && entry(sidecar.gold, word) == null) {
            word = word.lowercase()
            proper = true
        }
        var ps = entry(sidecar.gold, word)
        if (ps == null && !proper) ps = entry(sidecar.silver, word)
        if (ps == null || (proper && PRIMARY !in ps)) return letters(word)
        return applyStress(ps, stress)
    }

    private fun entry(lexicon: Map<String, String>, word: String): String? {
        lexicon[word]?.let { return it }
        if (word.length < 2) return null
        val lower = word.lowercase()
        val capitalized = lower.replaceFirstChar { it.uppercaseChar() }
        val variant = when (word) {
            lower -> capitalized
            capitalized -> lower
            else -> return null
        }
        return lexicon[variant]
    }

    private fun letters(word: String): String? {
        val spelled = StringBuilder()
        for (char in word) {
            if (!char.isLetter()) continue
            spelled.append(sidecar.gold[char.uppercase()] ?: return null)
        }
        if (spelled.isEmpty()) return null
        val stressed = applyStress(spelled.toString(), 0.0)
        val mark = stressed.lastIndexOf(SECONDARY)
        return if (mark >= 0) {
            stressed.substring(0, mark) + PRIMARY + stressed.substring(mark + 1)
        } else {
            stressed
        }
    }

    private fun stemS(word: String, stress: Double?): String? {
        if (word.length < 3 || !word.endsWith("s")) return null
        val stem = when {
            !word.endsWith("ss") && known(word.dropLast(1)) -> word.dropLast(1)
            (word.endsWith("'s") || (word.length > 4 && word.endsWith("es") && !word.endsWith("ies"))) &&
                known(word.dropLast(2)) -> word.dropLast(2)
            word.length > 4 && word.endsWith("ies") && known(word.dropLast(3) + "y") -> word.dropLast(3) + "y"
            else -> return null
        }
        val ps = lookup(stem, stress)?.takeIf { it.isNotEmpty() } ?: return null
        return ps + when {
            ps.last() in "ptkfθ" -> "s"
            ps.last() in "szʃʒʧʤ" -> "ᵻz"
            else -> "z"
        }
    }

    private fun stemEd(word: String, stress: Double?): String? {
        if (word.length < 4 || !word.endsWith("d")) return null
        val stem = when {
            !word.endsWith("dd") && known(word.dropLast(1)) -> word.dropLast(1)
            word.length > 4 && word.endsWith("ed") && !word.endsWith("eed") && known(word.dropLast(2)) ->
                word.dropLast(2)
            else -> return null
        }
        val ps = lookup(stem, stress)?.takeIf { it.isNotEmpty() } ?: return null
        return when {
            ps.last() == 't' && ps.length > 1 && ps[ps.length - 2] in US_TAUS -> ps.dropLast(1) + "ɾᵻd"
            ps.last() == 't' -> ps + "ᵻd"
            ps.last() in "pkfθʃsʧ" -> ps + "t"
            ps.last() == 'd' -> ps + "ᵻd"
            else -> ps + "d"
        }
    }

    private fun stemIng(word: String, stress: Double?): String? {
        if (word.length < 5 || !word.endsWith("ing")) return null
        val stem = when {
            word.length > 5 && known(word.dropLast(3)) -> word.dropLast(3)
            known(word.dropLast(3) + "e") -> word.dropLast(3) + "e"
            word.length > 5 && DOUBLED_ING.containsMatchIn(word) && known(word.dropLast(4)) -> word.dropLast(4)
            else -> return null
        }
        val ps = lookup(stem, stress ?: 0.5)?.takeIf { it.isNotEmpty() } ?: return null
        return if (ps.length > 1 && ps.last() == 't' && ps[ps.length - 2] in US_TAUS) {
            ps.dropLast(1) + "ɾɪŋ"
        } else {
            ps + "ɪŋ"
        }
    }

    private fun applyStress(ps: String, stress: Double?): String {
        if (stress == null) return ps
        val hasStress = PRIMARY in ps || SECONDARY in ps
        return when {
            stress < -1 -> ps.filter { it != PRIMARY && it != SECONDARY }
            stress == -1.0 || ((stress == 0.0 || stress == -0.5) && PRIMARY in ps) ->
                ps.replace(SECONDARY.toString(), "").replace(PRIMARY, SECONDARY)
            (stress == 0.0 || stress == 0.5 || stress == 1.0) && !hasStress ->
                if (ps.none { it in VOWELS }) ps else restress("$SECONDARY$ps")
            stress >= 1.0 && PRIMARY !in ps && SECONDARY in ps -> ps.replace(SECONDARY, PRIMARY)
            stress > 1.0 && !hasStress ->
                if (ps.none { it in VOWELS }) ps else restress("$PRIMARY$ps")
            else -> ps
        }
    }

    private fun restress(ps: String): String {
        val positions = DoubleArray(ps.length) { it.toDouble() }
        for (i in ps.indices) {
            if (ps[i] != PRIMARY && ps[i] != SECONDARY) continue
            val vowel = (i until ps.length).firstOrNull { ps[it] in VOWELS } ?: continue
            positions[i] = vowel - 0.5
        }
        return ps.indices.sortedBy { positions[it] }.map { ps[it] }.joinToString("")
    }

    private fun fallback(word: String): String {
        val inputIds = LongArray(word.length + 2)
        inputIds[0] = sidecar.bosId.toLong()
        word.forEachIndexed { index, char ->
            inputIds[index + 1] = graphemeIds[char] ?: sidecar.unknownId.toLong()
        }
        inputIds[word.length + 1] = sidecar.eosId.toLong()
        val decoded = ArrayList<Int>(sidecar.maxSteps)
        decoded.add(sidecar.startId)
        while (decoded.size < sidecar.maxSteps) {
            val next = greedyStep(inputIds, decoded)
            decoded.add(next)
            if (next == sidecar.eosId) break
        }
        return buildString {
            for (id in decoded) {
                if (id in minPhonemeId until sidecar.phonemes.length) append(sidecar.phonemes[id])
            }
        }
    }

    private fun greedyStep(inputIds: LongArray, decoded: List<Int>): Int {
        val decoderIds = LongArray(decoded.size) { decoded[it].toLong() }
        OnnxTensor.createTensor(environment, arrayOf(inputIds)).use { encoderTensor ->
            OnnxTensor.createTensor(environment, arrayOf(decoderIds)).use { decoderTensor ->
                session.run(
                    mapOf("input_ids" to encoderTensor, "decoder_input_ids" to decoderTensor),
                ).use { result ->
                    @Suppress("UNCHECKED_CAST")
                    val logits = result.get(0).value as Array<Array<FloatArray>>
                    val row = logits[0].last()
                    var best = 0
                    for (i in 1 until row.size) {
                        if (row[i] > row[best]) best = i
                    }
                    return best
                }
            }
        }
    }

    private fun spellNumbers(text: String): String {
        var result = CURRENCY.replace(text) { spellCurrency(it) }
        result = ORDINAL.replace(result) { match ->
            val digits = match.groupValues[1]
            if (digits.length > MAX_SPELLOUT_DIGITS) {
                spellDigits(digits)
            } else {
                ordinal.format(arrayOf(digits.toLong()))
            }
        }
        return NUMBER.replace(result) { match ->
            val whole = match.groupValues[1].replace(",", "")
            val fraction = match.groupValues[2]
            if (fraction.isEmpty()) {
                spellInteger(whole)
            } else {
                spellInteger(whole) + " point " + spellDigits(fraction)
            }
        }
    }

    private fun spellCurrency(match: MatchResult): String {
        val unit = CURRENCY_UNITS.getValue(match.value.first())
        val whole = match.groupValues[1].replace(",", "")
        val fraction = match.groupValues[2]
        if (fraction.length > 2) {
            return spellInteger(whole) + " point " + spellDigits(fraction) + " " + unit.plural
        }
        val subunits = when (fraction.length) {
            0 -> 0
            1 -> fraction.toInt() * 10
            else -> fraction.toInt()
        }
        val wholeWords = spellInteger(whole) + " " + (if (whole == "1") unit.singular else unit.plural)
        val subunitWords = if (subunits > 0) {
            cardinal.format(arrayOf(subunits.toLong())) + " " +
                (if (subunits == 1) unit.subunitSingular else unit.subunitPlural)
        } else {
            null
        }
        return when {
            whole == "0" && subunitWords != null -> subunitWords
            subunitWords != null -> "$wholeWords and $subunitWords"
            else -> wholeWords
        }
    }

    private fun spellInteger(digits: String): String =
        if (digits.length > MAX_SPELLOUT_DIGITS || (digits.length > 1 && digits.first() == '0')) {
            spellDigits(digits)
        } else {
            cardinal.format(arrayOf(digits.toLong()))
        }

    private fun spellDigits(digits: String): String =
        digits.map { cardinal.format(arrayOf((it - '0').toLong())) }.joinToString(" ")

    private fun asciiFold(word: String): String =
        Normalizer.normalize(word, Normalizer.Form.NFD)
            .filter { it.code < 128 && (it.isLetter() || it == '\'') }

    private fun nextWord(tokens: List<String>, index: Int): String? {
        for (i in index + 1 until tokens.size) {
            val token = tokens[i]
            if (token.first().isLetter()) return token
            if (token.length == 1 && token[0] in PUNCTUATION) return null
        }
        return null
    }

    private class Sidecar(
        val graphemes: String,
        val phonemes: String,
        val startId: Int,
        val bosId: Int,
        val eosId: Int,
        val unknownId: Int,
        val maxSteps: Int,
        val gold: Map<String, String>,
        val silver: Map<String, String>,
        val kokoroCodepoints: Set<Int>,
    ) {
        companion object {
            fun parse(file: File): Sidecar {
                var graphemes = ""
                var phonemes = ""
                var startId = 0
                var bosId = 0
                var eosId = 0
                var unknownId = 0
                var maxSteps = 0
                var gold: Map<String, String> = emptyMap()
                var silver: Map<String, String> = emptyMap()
                var kokoroCodepoints: Set<Int> = emptySet()
                JsonReader(file.bufferedReader()).use { reader ->
                    reader.beginObject()
                    while (reader.hasNext()) {
                        when (reader.nextName()) {
                            "graphemes" -> graphemes = reader.nextString()
                            "phonemes" -> phonemes = reader.nextString()
                            "start_id" -> startId = reader.nextInt()
                            "bos_id" -> bosId = reader.nextInt()
                            "eos_id" -> eosId = reader.nextInt()
                            "unknown_id" -> unknownId = reader.nextInt()
                            "max_steps" -> maxSteps = reader.nextInt()
                            "gold" -> gold = readLexicon(reader)
                            "silver" -> silver = readLexicon(reader)
                            "kokoro_vocab" -> kokoroCodepoints = readVocabCodepoints(reader)
                            else -> reader.skipValue()
                        }
                    }
                    reader.endObject()
                }
                return Sidecar(
                    graphemes = graphemes,
                    phonemes = phonemes,
                    startId = startId,
                    bosId = bosId,
                    eosId = eosId,
                    unknownId = unknownId,
                    maxSteps = maxSteps,
                    gold = gold,
                    silver = silver,
                    kokoroCodepoints = kokoroCodepoints,
                )
            }

            private fun readLexicon(reader: JsonReader): Map<String, String> {
                val entries = HashMap<String, String>(131_072)
                reader.beginObject()
                while (reader.hasNext()) {
                    val word = reader.nextName()
                    when (reader.peek()) {
                        JsonToken.STRING -> entries[word] = reader.nextString()
                        JsonToken.BEGIN_OBJECT -> {
                            reader.beginObject()
                            while (reader.hasNext()) {
                                if (reader.nextName() == "DEFAULT" && reader.peek() == JsonToken.STRING) {
                                    entries[word] = reader.nextString()
                                } else {
                                    reader.skipValue()
                                }
                            }
                            reader.endObject()
                        }
                        else -> reader.skipValue()
                    }
                }
                reader.endObject()
                return entries
            }

            private fun readVocabCodepoints(reader: JsonReader): Set<Int> {
                val codepoints = HashSet<Int>()
                reader.beginObject()
                while (reader.hasNext()) {
                    codepoints.add(reader.nextName().codePointAt(0))
                    reader.skipValue()
                }
                reader.endObject()
                return codepoints
            }
        }
    }

    private data class CurrencyUnit(
        val singular: String,
        val plural: String,
        val subunitSingular: String,
        val subunitPlural: String,
    )

    private companion object {
        const val PRIMARY = 'ˈ'
        const val SECONDARY = 'ˌ'
        const val VOWELS = "AIOQWYaiuæɑɒɔəɛɜɪʊʌᵻ"
        const val US_TAUS = "AIOWYiuæɑəɛɪɹʊʌ"
        const val PUNCTUATION = ";:,.!?—…\"“”()"
        const val NO_SPACE_AFTER = "(“\""
        const val MAX_G2P_INPUT = 62
        const val MAX_SPELLOUT_DIGITS = 12
        val SYMBOL_WORDS = mapOf("%" to "percent", "&" to "and")
        val TOKEN = Regex("""[\p{L}][\p{L}'’]*|[^\s\p{L}]""")
        val CURRENCY = Regex("""[$£€] ?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?""")
        val ORDINAL = Regex("""(\d+)(?:st|nd|rd|th)\b""")
        val NUMBER = Regex("""(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d+))?""")
        val DOUBLED_ING = Regex("""([bcdgklmnprstvxz])\1ing$|cking$""")
        val CURRENCY_UNITS = mapOf(
            '$' to CurrencyUnit("dollar", "dollars", "cent", "cents"),
            '£' to CurrencyUnit("pound", "pounds", "penny", "pence"),
            '€' to CurrencyUnit("euro", "euros", "cent", "cents"),
        )
    }
}
