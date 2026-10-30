package com.enve.app.listeningposition

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider

internal fun savePositionEvidence(name: String, data: ByteArray) {
    if (Build.VERSION.SDK_INT < 29) return
    val resolver = ApplicationProvider.getApplicationContext<Context>().contentResolver
    val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, ContentValues().apply {
        put(MediaStore.Downloads.DISPLAY_NAME, name)
        put(MediaStore.Downloads.MIME_TYPE, "image/png")
        put(MediaStore.Downloads.IS_PENDING, 1)
    })!!
    resolver.openOutputStream(uri)!!.use { it.write(data) }
    resolver.update(uri, ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }, null, null)
}
