package com.enve.hearth.design

import androidx.compose.runtime.Immutable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import com.enve.engine.theme.HearthPaletteStyle

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
    val decorated: Boolean = false,
    val outline: Color = hairline,
    val wood: Color = Color.Transparent,
    val pageEdge: Color = Color.Transparent,
) {

    val readableOnEmber: Color get() = readableForeground(ember, onEmber)

    companion object {
        fun ink(accent: Color = EmberAccent, style: HearthPaletteStyle = HearthPaletteStyle.PARCHMENT) = when (style) {
            HearthPaletteStyle.PARCHMENT -> HearthPalette(
                isInk = true,
                bg = Color(0xFF2D2322),
                bgElevated = Color(0xFF3A2B26),
                bgSunken = Color(0xFF1C1513),
                text = Color(0xFFF6DEAA),
                textSecondary = Color(0xFFD4BE98),
                textTertiary = Color(0xFFB09878),
                ember = accent,
                emberSoft = accent.copy(alpha = 0.16f),
                hairline = Color(0xFFF6DEAA).copy(alpha = 0.12f),
                onEmber = Color(0xFF1C1513),
                statusOK = Color(0xFF8FBF7F),
                statusWarn = Color(0xFFE0A458),
                statusError = Color(0xFFD06A5C),
                decorated = true,
                outline = Color(0xFF1C1513),
                wood = Color(0xFF794B31),
                pageEdge = Color(0xFFF6DEAA),
            )
            HearthPaletteStyle.CLASSIC -> HearthPalette(
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
        }

        fun oled(accent: Color = EmberAccent, style: HearthPaletteStyle = HearthPaletteStyle.PARCHMENT): HearthPalette {
            val base = HearthPalette(
                isInk = true,
                bg = Color.Black,
                bgElevated = Color(0xFF0C0C0D),
                bgSunken = Color.Black,
                text = Color(0xFFF0E9DC),
                textSecondary = Color(0xFFA99F92),
                textTertiary = Color(0xFF80786D),
                ember = accent,
                emberSoft = accent.copy(alpha = 0.16f),
                hairline = Color.White.copy(alpha = 0.11f),
                onEmber = Color(0xFF1C1513),
                statusOK = Color(0xFF8FBF7F),
                statusWarn = Color(0xFFE0A458),
                statusError = Color(0xFFD06A5C),
            )
            return when (style) {
                HearthPaletteStyle.PARCHMENT -> base.copy(
                    decorated = true,
                    outline = Color(0xFFF6DEAA).copy(alpha = 0.3f),
                    wood = Color(0xFF794B31),
                    pageEdge = Color(0xFFC9B48A),
                )
                HearthPaletteStyle.CLASSIC -> base
            }
        }

        fun paper(accent: Color = EmberAccent, style: HearthPaletteStyle = HearthPaletteStyle.PARCHMENT) = when (style) {
            HearthPaletteStyle.PARCHMENT -> HearthPalette(
                isInk = false,
                bg = Color(0xFFF6DEAA),
                bgElevated = Color(0xFFFBEBC8),
                bgSunken = Color(0xFFEFD199),
                text = Color(0xFF1C1513),
                textSecondary = Color(0xFF5A4535),
                textTertiary = Color(0xFF6A5240),
                ember = deepened(accent, paper = Color(0xFFF6DEAA)),
                emberSoft = accent.copy(alpha = 0.12f),
                hairline = Color(0xFF1C1513).copy(alpha = 0.12f),
                onEmber = Color(0xFF1C1513),
                statusOK = Color(0xFF4F7942),
                statusWarn = Color(0xFFA8762A),
                statusError = Color(0xFFA8453A),
                decorated = true,
                outline = Color(0xFF1C1513),
                wood = Color(0xFF794B31),
                pageEdge = Color(0xFFFFF6E2),
            )
            HearthPaletteStyle.CLASSIC -> HearthPalette(
                isInk = false,
                bg = Color(0xFFF7F2E9),
                bgElevated = Color.White,
                bgSunken = Color(0xFFEFE8DB),
                text = Color(0xFF231F1B),
                textSecondary = Color(0xFF7A7064),
                textTertiary = Color(0xFFA89D8F),
                ember = deepened(accent, paper = Color(0xFFF7F2E9)),
                emberSoft = accent.copy(alpha = 0.12f),
                hairline = Color.Black.copy(alpha = 0.08f),
                onEmber = Color(0xFF1A120A),
                statusOK = Color(0xFF4F7942),
                statusWarn = Color(0xFFA8762A),
                statusError = Color(0xFFA8453A),
            )
        }

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
            outline = Color.Black,
            wood = Color.Black,
            pageEdge = Color.White,
        )

        private fun deepened(color: Color, paper: Color): Color {
            val target = paper.luminance()
            var scale = 1f
            var candidate = color
            while ((target + 0.05f) / (candidate.luminance() + 0.05f) < 5.6f && scale > 0.1f) {
                scale -= 0.02f
                candidate = Color(color.red * scale, color.green * scale, color.blue * scale, color.alpha)
            }
            return candidate
        }

        private fun readableForeground(on: Color, dark: Color): Color {
            val light = Color(0xFFFFF7EA)
            return if (on.luminance() < 0.18f) light else dark
        }
    }
}
