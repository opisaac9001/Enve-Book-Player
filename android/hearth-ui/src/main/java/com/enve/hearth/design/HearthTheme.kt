package com.enve.hearth.design

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LocalRippleConfiguration
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.RippleConfiguration
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import com.enve.engine.theme.HearthThemeMode

val LocalHearth = staticCompositionLocalOf { HearthPalette.ink() }
val LocalHearthReducedMotion = staticCompositionLocalOf { false }

val LocalMantelInset = compositionLocalOf { 0.dp }

object Hearth {
    val palette: HearthPalette
        @Composable @ReadOnlyComposable get() = LocalHearth.current

    val eink: HearthEink
        @Composable @ReadOnlyComposable get() = LocalHearthEink.current

    val typeCompact: Boolean
        @Composable @ReadOnlyComposable get() = LocalDensity.current.fontScale >= 1.15f

    val reduceMotion: Boolean
        @Composable @ReadOnlyComposable get() = LocalHearthReducedMotion.current

    object Radius {
        val Cover = 12.dp
        val Inner = 14.dp
        val Card = 20.dp
        val Bar = 30.dp
    }

    object Spacing {
        val XXS = 2.dp
        val XS = 4.dp
        val S = 8.dp
        val M = 12.dp
        val L = 16.dp
        val XL = 20.dp
        val XXL = 24.dp
        val XXXL = 32.dp
    }

    object Motion {
        const val Snappy = 250
        const val Smooth = 350
        const val GlowCycleMs = 7000
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HearthTheme(
    mode: HearthThemeMode = HearthThemeMode.SYSTEM,
    accent: Color = EmberAccent,
    oledEnabled: Boolean = false,
    uiTextScale: Float = 1f,
    reduceMotion: Boolean = false,
    eink: HearthEink = HearthEink.Inactive,
    content: @Composable () -> Unit,
) {
    val isDark = when (mode) {
        HearthThemeMode.SYSTEM -> isSystemInDarkTheme()
        HearthThemeMode.INK -> true
        HearthThemeMode.PAPER -> false
    }

    val palette = when {
        eink.monochrome -> HearthPalette.eink()
        !isDark -> HearthPalette.paper(accent)
        oledEnabled -> HearthPalette.oled(accent)
        else -> HearthPalette.ink(accent)
    }

    val material = if (palette.isInk) {
        darkColorScheme(
            primary = palette.ember,
            onPrimary = palette.readableOnEmber,
            background = palette.bg,
            onBackground = palette.text,
            surface = palette.bgElevated,
            onSurface = palette.text,
            surfaceVariant = palette.bgElevated,
            onSurfaceVariant = palette.textSecondary,
            outline = palette.hairline,
            error = palette.statusError,
        )
    } else {
        lightColorScheme(
            primary = palette.ember,
            onPrimary = palette.readableOnEmber,
            background = palette.bg,
            onBackground = palette.text,
            surface = palette.bgElevated,
            onSurface = palette.text,
            surfaceVariant = palette.bgElevated,
            onSurfaceVariant = palette.textSecondary,
            outline = palette.hairline,
            error = palette.statusError,
        )
    }

    val ripple: RippleConfiguration? = if (eink.active) null else RippleConfiguration()

    HearthUiTextScale(uiTextScale) {
        CompositionLocalProvider(
            LocalHearth provides palette,
            LocalHearthEink provides eink,
            LocalHearthReducedMotion provides reduceMotion,
            LocalRippleConfiguration provides ripple,
        ) {
            MaterialTheme(
                colorScheme = material,
                typography = hearthMaterialTypography(),
                content = content,
            )
        }
    }
}

@Composable
fun HearthUiTextScale(scale: Float, content: @Composable () -> Unit) {
    val density = LocalDensity.current
    val scaledDensity = remember(density, scale) {
        Density(density.density, density.fontScale * scale.coerceIn(1f, 1.3f))
    }
    CompositionLocalProvider(LocalDensity provides scaledDensity, content = content)
}
