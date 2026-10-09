package com.enve.local

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.util.AtomicFile
import java.io.File
import java.security.MessageDigest

internal object LocalAudioCoverExtractor {
    fun extract(context: Context, filesDirectory: File, uri: Uri): String? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            val artwork = retriever.embeddedPicture ?: return null
            val name = MessageDigest.getInstance("SHA-256").digest(uri.toString().toByteArray())
                .joinToString("") { "%02x".format(it) }
            val directory = File(filesDirectory, "local_audio_covers").apply { mkdirs() }
            val file = File(directory, "${name}.img")
            val atomic = AtomicFile(file)
            val output = atomic.startWrite()
            try {
                output.write(artwork)
                atomic.finishWrite(output)
            } catch (error: Exception) {
                atomic.failWrite(output)
                throw error
            }
            Uri.fromFile(file).toString()
        } catch (_: Exception) {
            null
        } finally {
            retriever.release()
        }
    }
}
