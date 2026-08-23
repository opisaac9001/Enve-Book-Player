package com.enve.core.data.util

object NaturalSort {

    private val CHUNK_REGEX = Regex("(\\d+|\\D+)")

    fun compare(a: String?, b: String?): Int {
        if (a === b) return 0
        if (a == null) return 1
        if (b == null) return -1

        val chunksA = CHUNK_REGEX.findAll(a).map { it.value }.toList()
        val chunksB = CHUNK_REGEX.findAll(b).map { it.value }.toList()

        val len = minOf(chunksA.size, chunksB.size)
        for (i in 0 until len) {
            val ca = chunksA[i]
            val cb = chunksB[i]
            val cmp = if (ca[0].isDigit() && cb[0].isDigit()) {
                val la = ca.toLongOrNull()
                val lb = cb.toLongOrNull()
                if (la != null && lb != null) la.compareTo(lb) else ca.compareTo(cb)
            } else {
                ca.compareTo(cb, ignoreCase = true)
            }
            if (cmp != 0) return cmp
        }
        return chunksA.size.compareTo(chunksB.size)
    }

    val comparator: Comparator<String?> = Comparator { a, b -> compare(a, b) }
}
