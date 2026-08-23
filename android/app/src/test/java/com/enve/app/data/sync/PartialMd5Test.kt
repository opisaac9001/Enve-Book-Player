package com.enve.app.data.sync

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.io.RandomAccessFile
import java.security.MessageDigest

class PartialMd5Test {

    private fun reference(file: File): String {
        val digest = MessageDigest.getInstance("MD5")
        RandomAccessFile(file, "r").use { raf ->
            val length = raf.length()
            for (i in -1..10) {
                val offset = if (i == -1) 0L else 1024L shl (2 * i)
                if (offset >= length) break
                raf.seek(offset)
                val buf = ByteArray(1024)
                val read = raf.read(buf)
                if (read <= 0) break
                if (read < 1024) digest.update(buf, 0, read) else digest.update(buf)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun makeFile(size: Int): File {
        val f = File.createTempFile("kosync_md5", ".bin").apply { deleteOnExit() }

        val bytes = ByteArray(size) { ((it * 31 + 7) and 0xFF).toByte() }
        f.writeBytes(bytes)
        return f
    }

    @Test
    fun matches_reference_for_small_file_only_first_two_windows() {

        val f = makeFile(5 * 1024)
        assertEquals(reference(f), PartialMd5.compute(f))
    }

    @Test
    fun matches_reference_for_large_file_multiple_windows() {

        val f = makeFile(5 * 1024 * 1024)
        assertEquals(reference(f), PartialMd5.compute(f))
    }

    @Test
    fun produces_32_char_lowercase_hex() {
        val hash = PartialMd5.compute(makeFile(64 * 1024))
        assertEquals(32, hash.length)
        assertEquals(hash, hash.lowercase())
        assert(hash.all { it.isDigit() || it in 'a'..'f' })
    }
}
