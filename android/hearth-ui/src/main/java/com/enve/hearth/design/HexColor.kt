package com.enve.hearth.design

import androidx.compose.ui.graphics.Color

fun parseHexColor(hex: String): Color? {
    val digits = hex.trim().removePrefix("#")
    if (!digits.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
    val argb = when (digits.length) {
        3 -> "FF" + digits.map { "$it$it" }.joinToString("")
        6 -> "FF$digits"
        8 -> digits
        else -> return null
    }
    return Color(argb.toLong(16))
}
