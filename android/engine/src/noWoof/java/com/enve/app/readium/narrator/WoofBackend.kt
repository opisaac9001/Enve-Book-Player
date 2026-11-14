package com.enve.app.readium.narrator

import android.content.Context
import java.io.File

internal object WoofBackend {
    const val available = false

    @Suppress("UNUSED_PARAMETER")
    fun open(context: Context, directory: File): NarratorBackend =
        error("Underdog Woof is unavailable in this build")
}
