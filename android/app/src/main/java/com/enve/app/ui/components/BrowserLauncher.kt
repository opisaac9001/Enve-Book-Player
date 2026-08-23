package com.enve.app.ui.components

import android.app.Activity
import android.app.PendingIntent
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color as AndroidColor
import android.graphics.Paint
import android.graphics.Path
import android.net.Uri
import androidx.browser.customtabs.CustomTabColorSchemeParams
import androidx.browser.customtabs.CustomTabsClient
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import com.enve.app.ui.auth.AuthBrowserActivity

fun openInAppBrowser(context: Context, url: String, accent: Color) {
    runCatching {
        context.startActivity(AuthBrowserActivity.createIntent(context, url, accent.toArgb()))
        return
    }
    if (launchExternalBrowser(context, url)) return
    launchCustomTab(context, url, accent)
}

fun openExternalOAuthBrowser(context: Context, url: String, accent: Color) {
    if (launchCustomTab(context, url, accent, returnToApp = true)) return
    if (launchExternalBrowser(context, url)) return
    runCatching {
        context.startActivity(AuthBrowserActivity.createIntent(context, url, accent.toArgb()))
    }
}

private fun launchExternalBrowser(context: Context, url: String): Boolean {

    return runCatching {
        val activity = context.findActivity()
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
            addCategory(Intent.CATEGORY_BROWSABLE)
            if (activity == null) {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        }
        (activity ?: context).startActivity(intent)
        true
    }.getOrElse { false }
}

private fun launchCustomTab(
    context: Context,
    url: String,
    accent: Color,
    returnToApp: Boolean = false,
): Boolean {
    val packageName = CustomTabsClient.getPackageName(context, emptyList()) ?: return false

    return runCatching {
        val activity = context.findActivity()
        val builder = CustomTabsIntent.Builder()
            .setShowTitle(true)
            .setUrlBarHidingEnabled(false)
            .setShareState(CustomTabsIntent.SHARE_STATE_OFF)
            .setDefaultColorSchemeParams(
                CustomTabColorSchemeParams.Builder()
                    .setToolbarColor(accent.toArgb())
                    .build(),
            )
        if (returnToApp) {
            val pendingIntent = returnToEnveIntent(context)
            builder
                .setActionButton(returnToEnveIcon(), "Return to Enve", pendingIntent, false)
                .addMenuItem("Return to Enve", pendingIntent)
        }
        val intent = builder.build()
        if (activity == null) {
            intent.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        intent.intent.setPackage(packageName)
        intent.launchUrl(activity ?: context, Uri.parse(url))
        true
    }.getOrElse { false }
}

private fun Context.findActivity(): Activity? {
    var current = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        val next = current.baseContext
        if (next === current) return null
        current = next
    }
    return current as? Activity
}

private fun returnToEnveIntent(context: Context): PendingIntent {
    val intent = Intent(Intent.ACTION_VIEW, Uri.parse("enve://plex-return")).apply {
        setPackage(context.packageName)
        addCategory(Intent.CATEGORY_BROWSABLE)
        addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }
    return PendingIntent.getActivity(
        context,
        0,
        intent,
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}

private fun returnToEnveIcon(): Bitmap {
    val size = 96
    val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(bitmap)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = AndroidColor.WHITE
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        strokeWidth = 8f
    }

    val arrow = Path().apply {
        moveTo(58f, 24f)
        lineTo(34f, 48f)
        lineTo(58f, 72f)
    }
    canvas.drawPath(arrow, paint)
    canvas.drawLine(36f, 48f, 76f, 48f, paint)
    return bitmap
}
