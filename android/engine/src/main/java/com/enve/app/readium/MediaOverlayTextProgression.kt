package com.enve.app.readium

object MediaOverlayTextProgression {
    data class FragmentOffsets(
        val offsetsById: Map<String, Int>,
        val textLength: Int,
    )

    fun chapterSpan(chapterStarts: List<Double?>, readingOrderIndex: Int): ClosedFloatingPointRange<Double>? {
        val start = chapterStarts.getOrNull(readingOrderIndex) ?: return null
        val end = chapterStarts.getOrNull(readingOrderIndex + 1) ?: 1.0
        return start..end
    }

    fun clipProgressions(
        clips: List<SmilClip>,
        span: ClosedFloatingPointRange<Double>,
        offsets: FragmentOffsets?,
    ): List<Double> = clips.mapIndexed { index, clip ->
        val offset = clip.textFragmentId?.let { offsets?.offsetsById?.get(it) }
        val withinChapter = if (offsets != null && offsets.textLength > 0 && offset != null) {
            offset.toDouble() / offsets.textLength
        } else {
            index.toDouble() / clips.size
        }
        (span.start + withinChapter.coerceIn(0.0, 1.0) * (span.endInclusive - span.start)).coerceIn(0.0, 1.0)
    }

    fun readingProgression(textProgression: Double?, narrationCompleted: Boolean): Double? =
        if (narrationCompleted) 1.0 else textProgression

    fun fragmentOffsets(xhtml: String): FragmentOffsets {
        val bytes = xhtml.encodeToByteArray()
        val offsets = mutableMapOf<String, Int>()
        var length = 0
        var pendingSpace = false
        var index = bodyStart(bytes) ?: 0

        while (index < bytes.size) {
            val byte = bytes[index].toInt() and 0xFF
            if (byte == '<'.code) {
                if (hasPrefix(bytes, index, COMMENT_OPEN)) {
                    index = end(COMMENT_CLOSE, bytes, index + COMMENT_OPEN.size)
                    continue
                }
                var tagEnd = index + 1
                while (tagEnd < bytes.size && bytes[tagEnd] != '>'.code.toByte()) tagEnd++
                val tagStart = index + 1
                val tagStop = minOf(tagEnd, bytes.size)
                index = tagEnd + 1
                val first = if (tagStart < tagStop) bytes[tagStart].toInt() and 0xFF else continue
                if (first == '/'.code || first == '!'.code || first == '?'.code) continue

                idAttribute(bytes, tagStart, tagStop)?.let { id ->
                    offsets.putIfAbsent(id, length + if (pendingSpace) 1 else 0)
                }
                val name = tagName(bytes, tagStart, tagStop)
                if ((name == "script" || name == "style") && bytes[tagStop - 1] != '/'.code.toByte()) {
                    index = end("</$name".encodeToByteArray(), bytes, index)
                }
                continue
            }

            if (isSpace(byte)) {
                pendingSpace = length > 0
                index++
                continue
            }
            if (pendingSpace) {
                length++
                pendingSpace = false
            }
            if (byte == '&'.code) {
                var entityEnd = index + 1
                while (entityEnd < bytes.size && entityEnd - index <= 10 && bytes[entityEnd] != ';'.code.toByte()) {
                    entityEnd++
                }
                length++
                index = if (entityEnd < bytes.size && bytes[entityEnd] == ';'.code.toByte()) entityEnd + 1 else index + 1
                continue
            }
            if ((byte and 0xC0) != 0x80) length++
            index++
        }
        return FragmentOffsets(offsets, length)
    }

    private val COMMENT_OPEN = "<!--".encodeToByteArray()
    private val COMMENT_CLOSE = "-->".encodeToByteArray()

    private fun bodyStart(bytes: ByteArray): Int? {
        var index = 0
        while (index + 5 <= bytes.size) {
            if (bytes[index] == '<'.code.toByte() &&
                lowercase(bytes, index + 1, index + 5) == "body" &&
                (index + 5 == bytes.size || !isNameByte(bytes[index + 5].toInt() and 0xFF))
            ) {
                return index
            }
            index++
        }
        return null
    }

    private fun tagName(bytes: ByteArray, start: Int, stop: Int): String {
        var end = start
        while (end < stop && isNameByte(bytes[end].toInt() and 0xFF)) end++
        return lowercase(bytes, start, end)
    }

    private fun idAttribute(bytes: ByteArray, start: Int, stop: Int): String? {
        var index = start
        while (index + 2 < stop) {
            val candidate = index++
            if (!isSpace(bytes[candidate].toInt() and 0xFF) ||
                (bytes[candidate + 1].toInt() or 0x20) != 'i'.code ||
                (bytes[candidate + 2].toInt() or 0x20) != 'd'.code
            ) {
                continue
            }
            var cursor = candidate + 3
            while (cursor < stop && isSpace(bytes[cursor].toInt() and 0xFF)) cursor++
            if (cursor >= stop || bytes[cursor] != '='.code.toByte()) continue
            cursor++
            while (cursor < stop && isSpace(bytes[cursor].toInt() and 0xFF)) cursor++
            if (cursor >= stop) continue
            val quote = bytes[cursor]
            if (quote != '"'.code.toByte() && quote != '\''.code.toByte()) continue
            val valueStart = cursor + 1
            var valueEnd = valueStart
            while (valueEnd < stop && bytes[valueEnd] != quote) valueEnd++
            if (valueEnd >= stop) return null
            return bytes.decodeToString(valueStart, valueEnd)
        }
        return null
    }

    private fun end(marker: ByteArray, bytes: ByteArray, from: Int): Int {
        var index = from
        while (index + marker.size <= bytes.size) {
            if (hasPrefix(bytes, index, marker, caseInsensitive = true)) {
                if (marker[0] == '<'.code.toByte()) {
                    var close = index
                    while (close < bytes.size && bytes[close] != '>'.code.toByte()) close++
                    return minOf(close + 1, bytes.size)
                }
                return index + marker.size
            }
            index++
        }
        return bytes.size
    }

    private fun hasPrefix(bytes: ByteArray, at: Int, prefix: ByteArray, caseInsensitive: Boolean = false): Boolean {
        if (at + prefix.size > bytes.size) return false
        for (offset in prefix.indices) {
            val lhs = bytes[at + offset].toInt() and 0xFF
            val rhs = prefix[offset].toInt() and 0xFF
            if (lhs == rhs) continue
            if (!caseInsensitive || !isLetter(lhs) || (lhs or 0x20) != (rhs or 0x20)) return false
        }
        return true
    }

    private fun lowercase(bytes: ByteArray, start: Int, end: Int): String =
        String(CharArray(end - start) { offset ->
            val byte = bytes[start + offset].toInt() and 0xFF
            (if (isLetter(byte)) byte or 0x20 else byte).toChar()
        })

    private fun isLetter(byte: Int): Boolean = (byte or 0x20) in 'a'.code..'z'.code

    private fun isNameByte(byte: Int): Boolean =
        isLetter(byte) || byte in '0'.code..'9'.code || byte == '-'.code || byte == ':'.code

    private fun isSpace(byte: Int): Boolean = byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
}
