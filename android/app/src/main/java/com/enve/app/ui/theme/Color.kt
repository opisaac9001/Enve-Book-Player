package com.enve.app.ui.theme

import androidx.compose.ui.graphics.Color

object EnveColors {

    val DefaultAccent = Color(0xFFEF4444)

    val FixedAccent = Color(0xFF007AFF)

    val Primary = Color(0xFFCC4DFF)

    val DarkBackground = Color.Black
    val DarkCardBackground = Color(0xFF262626)
    val DarkSecondaryBackground = Color(0xFF1A1A1A)
    val DarkPrimaryText = Color.White
    val DarkSecondaryText = Color(0xFFCCCCCC)
    val DarkTertiaryText = Color(0xFF999999)
    val DarkPlaceholderText = Color(0xFF737373)
    val DarkSeparator = Color(0xFF333333)

    val OledBackground = Color(0xFF000000)
    val OledCardBackground = Color(0xFF141414)
    val OledSecondaryBackground = Color(0xFF0D0D0D)
    val OledSecondaryText = Color(0xFFB3B3B3)
    val OledTertiaryText = Color(0xFF808080)
    val OledSeparator = Color(0xFF333333)

    val LightBackground = Color(0xFFFFFFFF)
    val LightCardBackground = Color(0xFFFFFFFF)
    val LightSecondaryBackground = Color(0xFFF2F2F7)
    val LightPrimaryText = Color(0xFF000000)
    val LightSecondaryText = Color(0xFF8E8E93)
    val LightTertiaryText = Color(0xFFAEAEB2)
    val LightPlaceholderText = Color(0xFFC7C7CC)
    val LightSeparator = Color(0xFFC6C6C8)

    val PaperBackground = Color(0xFFF5F0E8)
    val PaperCardBackground = Color(0xFFFAF7F2)
    val PaperSecondaryBackground = Color(0xFFEDE8DF)
    val PaperPrimaryText = Color(0xFF2C2416)
    val PaperSecondaryText = Color(0xFF5C4E3C)
    val PaperTertiaryText = Color(0xFF8A7B68)
    val PaperPlaceholderText = Color(0xFFA69882)
    val PaperSeparator = Color(0xFFD8D0C4)
    val PaperAccent = Color(0xFF7C5C3C)

    val EinkBackground = Color.White
    val EinkCardBackground = Color(0xFFF5F5F5)
    val EinkSecondaryBackground = Color(0xFFEEEEEE)
    val EinkPrimaryText = Color.Black
    val EinkSecondaryText = Color(0xFF333333)
    val EinkTertiaryText = Color(0xFF555555)
    val EinkPlaceholderText = Color(0xFF777777)
    val EinkSeparator = Color(0xFF999999)
    val EinkAccent = Color.Black

    val SplashBackground = Color(0xFF262626)

    val Success = Color(0xFF34C759)
    val Warning = Color(0xFFFF9500)
    val Error = Color(0xFFFF3B30)

    val GlassBackground = Color.White.copy(alpha = 0.08f)
    val GlassBorder = Color.White.copy(alpha = 0.15f)

    val ThemePresets = listOf(
        Color(0xFF2A0003),
        Color(0xFFE89B05),
        Color(0xFFFF2E33),
        Color(0xFFF24693),
        Color(0xFFB347E6),
        Color(0xFF3D91E6),
        Color(0xFF3EC2D9),
        Color(0xFF4DD861),
        Color(0xFFEED810),
    )
}

data class EnveColorScheme(
    val background: Color,
    val cardBackground: Color,
    val secondaryBackground: Color,
    val primaryText: Color,
    val secondaryText: Color,
    val tertiaryText: Color,
    val placeholderText: Color,
    val separator: Color,
    val accent: Color,
    val onAccent: Color,
) {
    companion object {
        fun dark(accent: Color = EnveColors.DefaultAccent) = EnveColorScheme(
            background = EnveColors.DarkBackground,
            cardBackground = EnveColors.DarkCardBackground,
            secondaryBackground = EnveColors.DarkSecondaryBackground,
            primaryText = EnveColors.DarkPrimaryText,
            secondaryText = EnveColors.DarkSecondaryText,
            tertiaryText = EnveColors.DarkTertiaryText,
            placeholderText = EnveColors.DarkPlaceholderText,
            separator = EnveColors.DarkSeparator,
            accent = accent,
            onAccent = computeOnAccent(accent),
        )

        fun oled(accent: Color = EnveColors.DefaultAccent) = EnveColorScheme(
            background = EnveColors.OledBackground,
            cardBackground = EnveColors.OledCardBackground,
            secondaryBackground = EnveColors.OledSecondaryBackground,
            primaryText = EnveColors.DarkPrimaryText,
            secondaryText = EnveColors.OledSecondaryText,
            tertiaryText = EnveColors.OledTertiaryText,
            placeholderText = EnveColors.DarkPlaceholderText,
            separator = EnveColors.OledSeparator,
            accent = accent,
            onAccent = computeOnAccent(accent),
        )

        fun light(accent: Color = EnveColors.DefaultAccent) = EnveColorScheme(
            background = EnveColors.LightBackground,
            cardBackground = EnveColors.LightCardBackground,
            secondaryBackground = EnveColors.LightSecondaryBackground,
            primaryText = EnveColors.LightPrimaryText,
            secondaryText = EnveColors.LightSecondaryText,
            tertiaryText = EnveColors.LightTertiaryText,
            placeholderText = EnveColors.LightPlaceholderText,
            separator = EnveColors.LightSeparator,
            accent = accent,
            onAccent = computeOnAccent(accent),
        )

        fun paperWhite(accent: Color = EnveColors.PaperAccent) = EnveColorScheme(
            background = EnveColors.PaperBackground,
            cardBackground = EnveColors.PaperCardBackground,
            secondaryBackground = EnveColors.PaperSecondaryBackground,
            primaryText = EnveColors.PaperPrimaryText,
            secondaryText = EnveColors.PaperSecondaryText,
            tertiaryText = EnveColors.PaperTertiaryText,
            placeholderText = EnveColors.PaperPlaceholderText,
            separator = EnveColors.PaperSeparator,
            accent = accent,
            onAccent = computeOnAccent(accent),
        )

        fun eink() = EnveColorScheme(
            background = EnveColors.EinkBackground,
            cardBackground = EnveColors.EinkCardBackground,
            secondaryBackground = EnveColors.EinkSecondaryBackground,
            primaryText = EnveColors.EinkPrimaryText,
            secondaryText = EnveColors.EinkSecondaryText,
            tertiaryText = EnveColors.EinkTertiaryText,
            placeholderText = EnveColors.EinkPlaceholderText,
            separator = EnveColors.EinkSeparator,
            accent = EnveColors.EinkAccent,
            onAccent = Color.White,
        )

        private fun computeOnAccent(color: Color): Color {
            val luminance = 0.299f * color.red + 0.587f * color.green + 0.114f * color.blue
            return if (luminance > 0.5f) Color.Black else Color.White
        }
    }
}
