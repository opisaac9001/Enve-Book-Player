package com.enve.hearth.design

import androidx.compose.runtime.staticCompositionLocalOf
import com.enve.engine.eink.EinkState

data class HearthEink(val state: EinkState) {
    val active: Boolean get() = state.active
    val monochrome: Boolean get() = state.monochrome
    val boldText: Boolean get() = state.boldText

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
        val Inactive = HearthEink(EinkState.Inactive)
    }
}

val LocalHearthEink = staticCompositionLocalOf { HearthEink.Inactive }
