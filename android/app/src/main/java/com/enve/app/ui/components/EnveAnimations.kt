package com.enve.app.ui.components

import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition

object EnveAnimations {

    fun enterSlideFade(): EnterTransition =
        slideInHorizontally(
            animationSpec = tween(250),
            initialOffsetX = { it / 8 }
        ) + fadeIn(animationSpec = tween(250))

    fun exitSlideFade(): ExitTransition =
        slideOutHorizontally(
            animationSpec = tween(200),
            targetOffsetX = { -it / 12 }
        ) + fadeOut(animationSpec = tween(200))

    fun popEnterSlideFade(): EnterTransition =
        slideInHorizontally(
            animationSpec = tween(250),
            initialOffsetX = { -it / 8 }
        ) + fadeIn(animationSpec = tween(250))

    fun popExitSlideFade(): ExitTransition =
        slideOutHorizontally(
            animationSpec = tween(200),
            targetOffsetX = { it / 12 }
        ) + fadeOut(animationSpec = tween(200))

}
