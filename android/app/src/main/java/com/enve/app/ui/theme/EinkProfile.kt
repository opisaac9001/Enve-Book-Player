package com.enve.app.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import com.enve.app.eink.EinkDisplayMode

data class EinkProfile(
    val active: Boolean,
    val monochrome: Boolean,
    val displayMode: EinkDisplayMode,
    val boldText: Boolean,
    val refreshStrength: Int,
) {
    val suppressAnimations: Boolean get() = active
    val suppressShadows: Boolean get() = active
    val suppressGradients: Boolean get() = active
    val borderInsteadOfShadow: Boolean get() = active
    val sharpCorners: Boolean get() = monochrome
    val marginTapNavigation: Boolean get() = active
    val singleColumnReader: Boolean get() = active
    val flatTabBar: Boolean get() = active
    val denseListLibrary: Boolean get() = active

    companion object {
        val Inactive = EinkProfile(
            active = false,
            monochrome = false,
            displayMode = EinkDisplayMode.OFF,
            boldText = false,
            refreshStrength = 0,
        )
    }
}

val LocalEinkProfile = staticCompositionLocalOf { EinkProfile.Inactive }

val EnveTheme.eink: EinkProfile
    @Composable
    @ReadOnlyComposable
    get() = LocalEinkProfile.current
