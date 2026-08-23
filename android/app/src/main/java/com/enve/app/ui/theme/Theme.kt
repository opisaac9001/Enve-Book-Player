package com.enve.app.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LocalRippleConfiguration
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RippleConfiguration
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.graphics.Color

enum class AppTheme(val displayName: String) {
    SYSTEM("System"),
    LIGHT("Light"),
    DARK("Dark"),
    OLED("OLED"),
    PAPER_WHITE("Paper White"),
    EINK("E-Ink");

    companion object {
        fun fromString(value: String): AppTheme {
            return entries.find { it.name.equals(value, ignoreCase = true) } ?: DARK
        }
    }
}

val LocalEnveColors = staticCompositionLocalOf { EnveColorScheme.dark() }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EnveTheme(
    appTheme: AppTheme = AppTheme.DARK,
    themeColor: Color = EnveColors.DefaultAccent,
    dynamicBackgroundEnabled: Boolean = true,
    einkProfile: EinkProfile = EinkProfile.Inactive,
    content: @Composable () -> Unit,
) {
    val isDark = when (appTheme) {
        AppTheme.SYSTEM -> isSystemInDarkTheme()
        AppTheme.LIGHT, AppTheme.PAPER_WHITE, AppTheme.EINK -> false
        AppTheme.DARK, AppTheme.OLED -> true
    }

    val isEink = einkProfile.active || appTheme == AppTheme.EINK

    val enveColors = when (appTheme) {
        AppTheme.OLED -> EnveColorScheme.oled(themeColor)
        AppTheme.PAPER_WHITE -> EnveColorScheme.paperWhite()
        AppTheme.EINK -> EnveColorScheme.eink()
        AppTheme.LIGHT -> EnveColorScheme.light(themeColor)
        AppTheme.SYSTEM -> if (isDark) EnveColorScheme.dark(themeColor) else EnveColorScheme.light(themeColor)
        AppTheme.DARK -> EnveColorScheme.dark(themeColor)
    }

    val materialColors = if (isDark) {
        darkColorScheme(
            primary = themeColor,
            onPrimary = enveColors.onAccent,
            surface = enveColors.background,
            onSurface = enveColors.primaryText,
            surfaceVariant = enveColors.cardBackground,
            onSurfaceVariant = enveColors.secondaryText,
            background = enveColors.background,
            onBackground = enveColors.primaryText,
            outline = enveColors.separator,
            secondaryContainer = enveColors.secondaryBackground,
            onSecondaryContainer = enveColors.primaryText,
        )
    } else {
        lightColorScheme(
            primary = themeColor,
            onPrimary = enveColors.onAccent,
            surface = enveColors.background,
            onSurface = enveColors.primaryText,
            surfaceVariant = enveColors.cardBackground,
            onSurfaceVariant = enveColors.secondaryText,
            background = enveColors.background,
            onBackground = enveColors.primaryText,
            outline = enveColors.separator,
            secondaryContainer = enveColors.secondaryBackground,
            onSecondaryContainer = enveColors.primaryText,
        )
    }

    val themeBody = @Composable {
        MaterialTheme(
            colorScheme = materialColors,
            typography = enveTypography(),
            content = content,
        )
    }

    val rippleConfig: RippleConfiguration? = if (isEink || einkProfile.active) null else RippleConfiguration()
    CompositionLocalProvider(
        LocalEnveColors provides enveColors,
        LocalEinkMode provides isEink,
        LocalEinkProfile provides einkProfile,
        LocalDynamicBackgroundEnabled provides dynamicBackgroundEnabled,
        LocalIsDarkTheme provides isDark,
        LocalRippleConfiguration provides rippleConfig,
    ) { themeBody() }
}

val LocalEinkMode = staticCompositionLocalOf { false }
val LocalDynamicBackgroundEnabled = staticCompositionLocalOf { true }
val LocalIsDarkTheme = staticCompositionLocalOf { true }

object EnveTheme {
    val colors: EnveColorScheme
        @Composable
        @ReadOnlyComposable
        get() = LocalEnveColors.current

    val isEink: Boolean
        @Composable
        @ReadOnlyComposable
        get() = LocalEinkMode.current

    val dynamicBackgroundEnabled: Boolean
        @Composable
        @ReadOnlyComposable
        get() = LocalDynamicBackgroundEnabled.current

    val isDark: Boolean
        @Composable
        @ReadOnlyComposable
        get() = LocalIsDarkTheme.current
}
