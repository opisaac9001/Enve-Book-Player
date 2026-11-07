package com.enve.app.data.fileimport

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class DropboxSharedLinkTest {
    private fun rejected(input: String): String {
        try {
            DropboxSharedLink.parse(input)
        } catch (expected: IllegalArgumentException) {
            val message = expected.message.orEmpty()
            assertFalse(message.contains("SECRETKEY"))
            assertFalse(message.contains("shareid123"))
            return message
        }
        fail("Expected $input to be rejected")
        error("unreachable")
    }

    @Test
    fun rewritesCurrentLinksToDirectDownloadsAndKeepsTheirQuery() {
        val link = DropboxSharedLink.parse("https://www.dropbox.com/scl/fi/shareid123/My%20Book.epub?rlkey=SECRETKEY&st=abc&dl=0")

        assertEquals("www.dropbox.com", link.downloadUrl.host)
        assertEquals(listOf("1"), link.downloadUrl.queryParameterValues("dl"))
        assertEquals("SECRETKEY", link.downloadUrl.queryParameter("rlkey"))
        assertEquals("abc", link.downloadUrl.queryParameter("st"))
        assertEquals("My Book.epub", link.fileName)
    }

    @Test
    fun acceptsLegacyFileLinksOnTheBareHost() {
        val link = DropboxSharedLink.parse("  HTTPS://Dropbox.com/s/shareid123/Chapter%2001.mp3  ")

        assertEquals("dropbox.com", link.downloadUrl.host)
        assertEquals("/s/shareid123/Chapter%2001.mp3", link.downloadUrl.encodedPath)
        assertEquals(listOf("1"), link.downloadUrl.queryParameterValues("dl"))
        assertEquals("Chapter 01.mp3", link.fileName)
    }

    @Test
    fun keepsSupportedAudioAndEbookExtensions() {
        listOf("a.m4b", "a.m4a", "a.opus", "a.flac", "a.pdf", "a.cbz", "a.kepub", "a.azw3").forEach { name ->
            assertEquals(name, DropboxSharedLink.parse("https://www.dropbox.com/s/shareid123/$name").fileName)
        }
    }

    @Test
    fun rejectsSchemesCredentialsPortsAndFragments() {
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("http://www.dropbox.com/s/shareid123/a.epub"))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("https://user:pass@www.dropbox.com/s/shareid123/a.epub"))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("https://www.dropbox.com:443/s/shareid123/a.epub"))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("https://www.dropbox.com:8443/s/shareid123/a.epub"))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("https://www.dropbox.com/s/shareid123/a.epub#SECRETKEY"))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("ftp://www.dropbox.com/s/shareid123/a.epub"))
    }

    @Test
    fun rejectsLookalikeShortenedAndContentHosts() {
        listOf(
            "https://www.dropbox.com.evil.test/s/shareid123/a.epub",
            "https://evildropbox.com/s/shareid123/a.epub",
            "https://www.dropbox.com./s/shareid123/a.epub",
            "https://dl.dropboxusercontent.com/s/shareid123/a.epub",
            "https://db.tt/shareid123",
            "https://xn--dropbx-3ya.com/s/shareid123/a.epub",
        ).forEach { assertEquals(DropboxSharedLink.INVALID_LINK, rejected(it)) }
    }

    @Test
    fun rejectsFolderAndMalformedPaths() {
        listOf(
            "https://www.dropbox.com/sh/shareid123/AAA?dl=0",
            "https://www.dropbox.com/scl/fo/shareid123/folder?rlkey=SECRETKEY",
            "https://www.dropbox.com/s/shareid123/a.epub/",
            "https://www.dropbox.com/s/shareid123",
            "https://www.dropbox.com/s/shareid123/sub/a.epub",
            "https://www.dropbox.com/s/share%20id/a.epub",
            "https://www.dropbox.com/home/a.epub",
        ).forEach { assertEquals(DropboxSharedLink.FILE_LINKS_ONLY, rejected(it)) }
    }

    @Test
    fun rejectsUnsupportedFilesAndUnreadableInput() {
        assertEquals(DropboxSharedLink.UNSUPPORTED_FILE, rejected("https://www.dropbox.com/s/shareid123/Folder.zip?rlkey=SECRETKEY"))
        assertEquals(DropboxSharedLink.UNSUPPORTED_FILE, rejected("https://www.dropbox.com/s/shareid123/notes.docx"))
        assertEquals(DropboxSharedLink.UNSUPPORTED_FILE, rejected("https://www.dropbox.com/s/shareid123/..epub"))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected(""))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("https://www.dropbox.com/s/shareid123/a b.epub"))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("https://www.dropbox.com/s/shareid123/a.epub\nhttps://evil.test"))
        assertEquals(DropboxSharedLink.INVALID_LINK, rejected("not a link"))
    }

    @Test
    fun neverExposesTheLinkSecretInTextOrIdentity() {
        val link = DropboxSharedLink.parse("https://www.dropbox.com/scl/fi/shareid123/Book.epub?rlkey=SECRETKEY&dl=0")
        val rotated = DropboxSharedLink.parse("https://www.dropbox.com/scl/fi/shareid123/Book.epub?rlkey=OTHER&st=1")
        val other = DropboxSharedLink.parse("https://www.dropbox.com/scl/fi/differentid/Book.epub?rlkey=SECRETKEY")

        listOf(link.toString(), link.identity).forEach { text ->
            assertFalse(text.contains("SECRETKEY"))
            assertFalse(text.contains("shareid123"))
            assertFalse(text.contains("dropbox.com/"))
        }
        assertEquals(link.identity, rotated.identity)
        assertNotEquals(link.identity, other.identity)
    }

    @Test
    fun sanitizesFileNames() {
        assertEquals("_x.epub", DropboxSharedLink.sanitizedFileName("../x.epub"))
        assertEquals("a_b.mp3", DropboxSharedLink.sanitizedFileName("a\\b.mp3"))
        assertEquals("ab.pdf", DropboxSharedLink.sanitizedFileName("a\u0000b.pdf"))
        assertEquals("x".repeat(120) + ".m4b", DropboxSharedLink.sanitizedFileName("x".repeat(300) + ".m4b"))
        assertNull(DropboxSharedLink.sanitizedFileName("noextension"))
        assertNull(DropboxSharedLink.sanitizedFileName("..."))
        assertTrue(DropboxSharedLink.sanitizedFileName("..%2F..%2Fpasswd.epub".replace("%2F", "/"))!!.none { it == '/' })
    }
}
