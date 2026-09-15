package com.enve.app.data.reader.search

import java.io.File
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.zip.ZipFile

internal object EbookSearchFingerprint {

    private const val SCHEMA_VERSION = 2

    fun compute(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        val scratch = ByteBuffer.allocate(8)
        digest.update("enve-ebook-search/$SCHEMA_VERSION".toByteArray(Charsets.UTF_8))
        digest.update(scratch, file.length())
        ZipFile(file).use { zip ->
            val entries = zip.entries()
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                digest.update(entry.name.toByteArray(Charsets.UTF_8))
                digest.update(scratch, entry.crc)
                digest.update(scratch, entry.size)
                digest.update(scratch, entry.compressedSize)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun MessageDigest.update(scratch: ByteBuffer, value: Long) {
        scratch.clear()
        scratch.putLong(value)
        update(scratch.array())
    }
}
