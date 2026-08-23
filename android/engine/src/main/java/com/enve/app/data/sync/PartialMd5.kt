package com.enve.app.data.sync

import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

object PartialMd5 {

    private const val SAMPLE_SIZE = 1024

    fun compute(file: File): String {
        val digest = MessageDigest.getInstance("MD5")
        val step = 1024L

        RandomAccessFile(file, "r").use { raf ->
            val length = raf.length()
            for (i in -1..10) {
                val offset = if (i == -1) 0L else step shl (2 * i)
                if (offset >= length) break
                raf.seek(offset)
                val buffer = ByteArray(SAMPLE_SIZE)
                val read = raf.read(buffer)
                if (read <= 0) break
                if (read < SAMPLE_SIZE) digest.update(buffer, 0, read) else digest.update(buffer)
            }
        }
        return digest.digest().toHexLower()
    }
}
