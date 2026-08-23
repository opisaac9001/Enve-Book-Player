package com.enve.app.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.platform.LocalView
import com.enve.app.eink.EpdRefreshManager

val LocalEpdRefreshManager = staticCompositionLocalOf<EpdRefreshManager?> { null }

@Composable
fun RefreshEinkOnDismiss() {
    val view = LocalView.current
    val manager = LocalEpdRefreshManager.current
    val active = LocalEinkProfile.current.active
    DisposableEffect(active, manager, view) {
        onDispose {
            if (active && manager != null) {
                manager.requestPartialRefresh(view.rootView ?: view)
            }
        }
    }
}
