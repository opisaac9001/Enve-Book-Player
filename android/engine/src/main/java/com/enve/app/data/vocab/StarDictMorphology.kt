package com.enve.app.data.vocab

object StarDictMorphology {

    private val vowelAccentMap: Map<Char, Char> = mapOf(
        'á' to 'a', 'à' to 'a', 'â' to 'a', 'ä' to 'a', 'ã' to 'a', 'å' to 'a',
        'é' to 'e', 'è' to 'e', 'ê' to 'e', 'ë' to 'e',
        'í' to 'i', 'ì' to 'i', 'î' to 'i', 'ï' to 'i',
        'ó' to 'o', 'ò' to 'o', 'ô' to 'o', 'ö' to 'o', 'õ' to 'o',
        'ú' to 'u', 'ù' to 'u', 'û' to 'u', 'ü' to 'u',
        'ý' to 'y', 'ÿ' to 'y',
    )

    fun normalize(word: String): String = buildString(word.length) {
        for (c in word.lowercase()) {
            append(vowelAccentMap[c] ?: c)
        }
    }

    fun candidates(raw: String): List<String> {
        val w = raw.lowercase().trim()
        val seen = HashSet<String>()
        val out = mutableListOf<String>()

        fun add(s: String) {
            if (s.length > 1 && seen.add(s)) out.add(s)
        }

        add(w)

        if (w.endsWith("ily") && w.length > 4) add(w.dropLast(3) + "y")
        if (w.endsWith("ly") && w.length > 4) add(w.dropLast(2))

        if (w.endsWith("ves") && w.length > 4) {
            add(w.dropLast(3) + "f")
            add(w.dropLast(3) + "fe")
        }
        if (w.endsWith("ies") && w.length > 4) add(w.dropLast(3) + "y")

        if (w.endsWith("ing") && w.length > 5) {
            val base = w.dropLast(3)
            add(base + "e")
            add(base)
            if (base.length >= 2 && base.last() == base[base.length - 2]) {
                add(base.dropLast(1))
            }
        }

        if (w.endsWith("ied") && w.length > 4) add(w.dropLast(3) + "y")
        if (w.endsWith("ed") && w.length > 3) {
            val base = w.dropLast(2)
            add(w.dropLast(1))
            add(base)
            if (base.length >= 2 && base.last() == base[base.length - 2]) {
                add(base.dropLast(1))
            }
        }

        if (w.endsWith("est") && w.length > 5) {
            val base = w.dropLast(3)
            add(base + "e")
            add(base)
            if (base.length >= 2 && base.last() == base[base.length - 2]) {
                add(base.dropLast(1))
            }
        }
        if (w.endsWith("er") && w.length > 4) {
            val base = w.dropLast(2)
            add(base + "e")
            add(base)
            if (base.length >= 2 && base.last() == base[base.length - 2]) {
                add(base.dropLast(1))
            }
        }

        if (w.endsWith("es") && w.length > 3) {
            add(w.dropLast(1))
            add(w.dropLast(2))
        }
        if (w.endsWith("s") && w.length > 3) add(w.dropLast(1))

        if (w.length >= 3) {
            add(w + "a")
            add(w + "e")
            add(w + "i")

            if (w.endsWith("o") && w.length > 3) {
                add(w.dropLast(1))
                add(w.dropLast(1) + "a")
            }

            if (w.endsWith("i") && w.length > 3) {
                add(w.dropLast(1) + "a")
                add(w.dropLast(1) + "e")
            }
            if (w.endsWith("u") && w.length > 3) {
                add(w.dropLast(1))
                add(w.dropLast(1) + "a")
                add(w.dropLast(1) + "e")
            }

            if (w.endsWith("ji") && w.length > 3) add(w.dropLast(2))
            if (w.endsWith("evi") && w.length > 4) {
                add(w.dropLast(3))
                add(w.dropLast(3) + "e")
            }
            if (w.endsWith("ovi") && w.length > 4) add(w.dropLast(3))
            if (w.endsWith("je") && w.length > 3) add(w.dropLast(2))
            if (w.endsWith("i") && w.length > 3) add(w.dropLast(1))
            if (w.endsWith("e") && w.length > 3) add(w.dropLast(1) + "a")

            if (w.endsWith("ega") && w.length > 4) add(w.dropLast(3) + "i")
            if (w.endsWith("emu") && w.length > 4) add(w.dropLast(3) + "i")
            if (w.endsWith("em") && w.length > 3) add(w.dropLast(2) + "i")
            if (w.endsWith("ih") && w.length > 3) add(w.dropLast(2) + "i")

            if (w.endsWith("ati") && w.length > 4) add(w.dropLast(3))
            if (w.endsWith("iti") && w.length > 4) add(w.dropLast(3))
            if (w.endsWith("eti") && w.length > 4) add(w.dropLast(3))

            if (w.endsWith("am") && w.length > 3) {
                val s = w.dropLast(2); add(s); add(s + "ti"); add(s + "ati")
            }
            if (w.endsWith("aš") && w.length > 3) {
                val s = w.dropLast(2); add(s); add(s + "ti"); add(s + "ati")
            }
            if (w.endsWith("iš") && w.length > 3) {
                val s = w.dropLast(2); add(s); add(s + "ti"); add(s + "iti")
            }
            if (w.endsWith("im") && w.length > 3) {
                val s = w.dropLast(2); add(s); add(s + "ti"); add(s + "iti")
            }
            if (w.endsWith("eš") && w.length > 3) {
                val s = w.dropLast(2); add(s); add(s + "ti"); add(s + "eti")
            }
            if (w.endsWith("em") && w.length > 3) {
                val s = w.dropLast(2); add(s + "eti")
            }
        }

        return out
    }
}
