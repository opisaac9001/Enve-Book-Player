package com.enve.core.reader

private val HIGHLIGHT_COLOR_NAMES = mapOf(
    "yellow" to "#FACC15",
    "green" to "#4ADE80",
    "blue" to "#38BDF8",
    "pink" to "#F472B6",
    "orange" to "#FB923C",
    "red" to "#F87171",
    "olive" to "#84CC16",
    "cyan" to "#22D3EE",
    "purple" to "#C084FC",
    "gray" to "#9CA3AF",
)

fun highlightColorHex(value: String): String? {
    val trimmed = value.trim()
    val digits = trimmed.removePrefix("#")
    if (digits.length in setOf(3, 6, 8) && digits.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) return "#$digits"
    return HIGHLIGHT_COLOR_NAMES[trimmed.lowercase()]
}
