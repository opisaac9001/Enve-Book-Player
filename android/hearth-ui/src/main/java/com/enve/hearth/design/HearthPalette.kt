package com.enve.hearth.design

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.toArgb

val EmberAccent = Color(0xFFF5921A)

@Immutable
data class HearthPalette(
    val isInk: Boolean,
    val bg: Color,
    val bgElevated: Color,
    val bgSunken: Color,
    val text: Color,
    val textSecondary: Color,
    val textTertiary: Color,
    val ember: Color,
    val emberSoft: Color,
    val hairline: Color,

    val onEmber: Color,
    val statusOK: Color,
    val statusWarn: Color,
    val statusError: Color,
) {

    val readableOnEmber: Color get() = readableForeground(ember, onEmber)

    companion object {
        fun ink(accent: Color = EmberAccent) = HearthPalette(
            isInk = true,
            bg = Color(0xFF0C0A09),
            bgElevated = Color(0xFF191512),
            bgSunken = Color.Black,
            text = Color(0xFFF0E9DC),
            textSecondary = Color(0xFFA99F92),
            textTertiary = Color(0xFF6E665C),
            ember = accent,
            emberSoft = accent.copy(alpha = 0.14f),
            hairline = Color.White.copy(alpha = 0.08f),
            onEmber = Color(0xFF1A120A),
            statusOK = Color(0xFF8FBF7F),
            statusWarn = Color(0xFFE0A458),
            statusError = Color(0xFFD06A5C),
        )

        fun oled(accent: Color = EmberAccent) = HearthPalette(
            isInk = true,
            bg = Color.Black,
            bgElevated = Color(0xFF0C0C0D),
            bgSunken = Color.Black,
            text = Color(0xFFF0E9DC),
            textSecondary = Color(0xFFA99F92),
            textTertiary = Color(0xFF6E665C),
            ember = accent,
            emberSoft = accent.copy(alpha = 0.16f),
            hairline = Color.White.copy(alpha = 0.11f),
            onEmber = Color(0xFF1A120A),
            statusOK = Color(0xFF8FBF7F),
            statusWarn = Color(0xFFE0A458),
            statusError = Color(0xFFD06A5C),
        )

        fun paper(accent: Color = EmberAccent) = HearthPalette(
            isInk = false,
            bg = Color(0xFFF7F2E9),
            bgElevated = Color.White,
            bgSunken = Color(0xFFEFE8DB),
            text = Color(0xFF231F1B),
            textSecondary = Color(0xFF7A7064),
            textTertiary = Color(0xFFA89D8F),
            ember = deepened(accent),
            emberSoft = accent.copy(alpha = 0.12f),
            hairline = Color.Black.copy(alpha = 0.08f),
            onEmber = Color(0xFF1A120A),
            statusOK = Color(0xFF4F7942),
            statusWarn = Color(0xFFA8762A),
            statusError = Color(0xFFA8453A),
        )

        fun eink() = HearthPalette(
            isInk = false,
            bg = Color.White,
            bgElevated = Color.White,
            bgSunken = Color.White,
            text = Color.Black,
            textSecondary = Color(0xFF333333),
            textTertiary = Color(0xFF555555),
            ember = Color.Black,
            emberSoft = Color.Transparent,
            hairline = Color.Black,
            onEmber = Color.White,
            statusOK = Color.Black,
            statusWarn = Color.Black,
            statusError = Color.Black,
        )

        private fun deepened(color: Color): Color {
            val hsv = FloatArray(3)
            android.graphics.Color.colorToHSV(color.toArgb(), hsv)
            hsv[1] = (hsv[1] * 1.08f).coerceAtMost(1f)
            hsv[2] = hsv[2] * 0.91f
            return Color(android.graphics.Color.HSVToColor(hsv))
        }

        private fun readableForeground(on: Color, dark: Color): Color {
            val light = Color(0xFFFFF7EA)
            return if (on.luminance() < 0.52f) light else dark
        }
    }
}
