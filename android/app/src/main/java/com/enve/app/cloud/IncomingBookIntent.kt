package com.enve.app.cloud

import android.content.Intent
import android.net.Uri
import androidx.core.content.IntentCompat
import com.enve.app.data.fileimport.ImportPlanner

object IncomingBookIntent {
    fun files(intent: Intent?, ownAuthority: String): List<Uri> {
        if (intent == null) return emptyList()
        val candidates = when (intent.action) {
            Intent.ACTION_VIEW -> listOfNotNull(intent.data)
            Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE -> IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
            else -> return emptyList()
        }.ifEmpty {
            intent.clipData?.let { clip -> (0 until minOf(clip.itemCount, ImportPlanner.MAX_FILES + 1)).mapNotNull { clip.getItemAt(it).uri } }.orEmpty()
        }
        val ownProviderPrefix = ownAuthority.removeSuffix(".fileprovider") + "."
        return candidates.asSequence()
            .filter { it.scheme == "content" && !it.authority.isNullOrBlank() && !it.authority.orEmpty().startsWith(ownProviderPrefix) }
            .distinct().take(ImportPlanner.MAX_FILES + 1).toList()
    }
}
