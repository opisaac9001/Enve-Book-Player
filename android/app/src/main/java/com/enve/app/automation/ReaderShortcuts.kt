package com.enve.app.automation

import android.content.Context
import android.content.Intent
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import com.enve.app.MainActivity
import com.enve.app.R

object ReaderShortcuts {
    const val CONTINUE = "continue-reading"
    const val LIBRARY = "open-library"

    fun request(context: Context, intent: Intent?): String? =
        listOf(CONTINUE, LIBRARY).firstOrNull { intent?.action == "${context.packageName}.$it" }

    fun publish(context: Context) {
        val existing = ShortcutManagerCompat.getDynamicShortcuts(context).map { it.id }.toSet()
        val shortcuts = listOf(CONTINUE to "Read", LIBRARY to "Library")
            .filterNot { it.first in existing }
            .map { (id, label) ->
                ShortcutInfoCompat.Builder(context, id)
                    .setShortLabel(label)
                    .setLongLabel(if (id == CONTINUE) "Continue reading" else "Find a book")
                    .setIcon(IconCompat.createWithResource(context, R.mipmap.ic_launcher))
                    .setIntent(Intent(context, MainActivity::class.java)
                        .setAction("${context.packageName}.$id")
                        .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                    .build()
            }
        if (shortcuts.isNotEmpty()) ShortcutManagerCompat.addDynamicShortcuts(context, shortcuts)
    }
}
