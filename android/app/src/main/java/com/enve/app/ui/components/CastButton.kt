package com.enve.app.ui.components

import android.app.Activity
import android.annotation.SuppressLint
import android.content.Context
import android.content.ContextWrapper
import android.util.Log
import android.view.ContextThemeWrapper
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.mediarouter.app.MediaRouteButton
import androidx.mediarouter.app.MediaRouteChooserDialog
import androidx.mediarouter.app.MediaRouteControllerDialog
import androidx.fragment.app.FragmentActivity
import com.enve.app.R
import com.google.android.gms.cast.framework.CastButtonFactory
import com.google.android.gms.cast.framework.CastContext

@Composable
fun CastButton(modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val activity = remember(context) { unwrapActivity(context) }
    if (activity == null) return

    val playServicesOk = remember {
        runCatching {
            val availability = com.google.android.gms.common.GoogleApiAvailability.getInstance()
            availability.isGooglePlayServicesAvailable(activity) ==
                com.google.android.gms.common.ConnectionResult.SUCCESS
        }.getOrDefault(false)
    }
    if (!playServicesOk) return

    AndroidView(
        modifier = modifier,
        factory = {
            val themedCtx = ContextThemeWrapper(activity, R.style.Theme_EnveCast)
            val button = SafeMediaRouteButton(themedCtx, activity as? FragmentActivity)
            runCatching {
                CastButtonFactory.setUpMediaRouteButton(themedCtx, button)
            }.onFailure { error ->
                Log.w("CastButton", "MediaRouteButton setup failed", error)
            }
            button
        },
    )
}

private const val TAG = "CastButton"

@SuppressLint("ViewConstructor")
private class SafeMediaRouteButton(
    context: Context,
    private val fragmentActivity: FragmentActivity?,
) : MediaRouteButton(context) {
    override fun performClick(): Boolean {
        val openedNativePicker = if (fragmentActivity != null) {
            runCatching {
                super.performClick()
            }.getOrElse { error ->
                Log.w(TAG, "MediaRoute built-in chooser failed; using fallback", error)
                false
            }
        } else {
            false
        }
        if (openedNativePicker) {
            return true
        }

        return runCatching {
            showFallbackRouteDialog()
        }.getOrElse { error ->
            Log.w(TAG, "Failed to show cast fallback dialog", error)
            false
        }
    }

    private fun showFallbackRouteDialog(): Boolean {
        val themedContext = ContextThemeWrapper(context, R.style.Theme_EnveCastDialog)

        val connected = runCatching {
            CastContext.getSharedInstance()?.sessionManager?.currentCastSession?.isConnected == true
        }.getOrDefault(false)
        val dialog = if (connected) {
            MediaRouteControllerDialog(themedContext, androidx.appcompat.R.style.Theme_AppCompat_Dialog)
        } else {
            MediaRouteChooserDialog(themedContext, androidx.appcompat.R.style.Theme_AppCompat_Dialog)
                .apply { routeSelector = this@SafeMediaRouteButton.routeSelector }
        }
        dialog.show()
        return true
    }
}

private fun unwrapActivity(context: Context): Activity? {
    var current: Context? = context
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}
