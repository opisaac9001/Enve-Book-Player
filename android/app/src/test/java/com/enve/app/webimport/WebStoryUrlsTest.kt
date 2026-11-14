package com.enve.app.webimport

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WebStoryUrlsTest {

    @Test
    fun acceptsOnlyExplicitHttpAndHttps() {
        assertEquals("https://example.com/story", WebStoryUrls.parseInput("  https://example.com/story ").toString())
        assertEquals("http://127.0.0.1:44877/index.html", WebStoryUrls.parseInput("http://127.0.0.1:44877/index.html").toString())
        assertEquals("https://example.com/story", WebStoryUrls.parseInput("HTTPS://Example.com/story#comments").toString())
    }

    @Test
    fun rejectsMalformedSchemesAndUserInfo() {
        listOf(
            "",
            "example.com/story",
            "www.royalroad.com/fiction/1",
            "https:/example.com",
            "https:example.com",
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "content://com.example/secret",
            "ftp://example.com/file",
            "intent://example#Intent;end",
            "mailto:someone@example.com",
            "https://user:secret@example.com/story",
            "https://user@example.com/story",
            "https://example.com/a story",
            "https://example.com\\@evil.example/",
            "https://example.com:99999/",
            "https://exa\u0000mple.com/",
            "https://" + "a".repeat(3000) + ".com",
        ).forEach { input ->
            val error = assertThrows(input, WebStoryImportException::class.java) { WebStoryUrls.parseInput(input) }
            assertEquals(input, WebStoryImportException.Reason.INVALID_URL, error.reason)
        }
    }

    @Test
    fun chapterIdsComeFromChapterPathSegments() {
        assertEquals("21", WebStoryUrls.chapterId("http://127.0.0.1:44877/chapter/21/".toHttpUrl()))
        assertEquals("1001", WebStoryUrls.chapterId("https://www.royalroad.com/fiction/77/story/chapter/1001/one".toHttpUrl()))
        assertNull(WebStoryUrls.chapterId("https://example.com/chapters/21".toHttpUrl()))
        assertNull(WebStoryUrls.chapterId("https://example.com/story?chapter=21".toHttpUrl()))
    }

    @Test
    fun royalRoadLinksMapToTheirFiction() {
        val chapter = "https://www.royalroad.com/fiction/21220/mother-of-learning/chapter/301778/one?x=1".toHttpUrl()
        assertEquals("21220", WebStoryUrls.royalRoadFictionId(chapter))
        assertEquals("https://www.royalroad.com/fiction/21220", WebStoryUrls.royalRoadFictionUrl(chapter, "21220").toString())
        assertNull(WebStoryUrls.royalRoadFictionId("https://www.royalroad.com/fictions/best-rated".toHttpUrl()))
        assertNull(WebStoryUrls.royalRoadFictionId("https://royalroad.com.evil.example/fiction/1".toHttpUrl()))
    }

    @Test
    fun originComparesSchemeHostAndPort() {
        val origin = "http://127.0.0.1:44877/index.html".toHttpUrl()
        assertTrue(WebStoryUrls.sameOrigin(origin, "http://127.0.0.1:44877/chapter/21/".toHttpUrl()))
        assertFalse(WebStoryUrls.sameOrigin(origin, "https://127.0.0.1:44877/chapter/21/".toHttpUrl()))
        assertFalse(WebStoryUrls.sameOrigin(origin, "http://127.0.0.1:44878/chapter/21/".toHttpUrl()))
        assertFalse(WebStoryUrls.sameOrigin(origin, "http://localhost:44877/chapter/21/".toHttpUrl()))
    }
}
