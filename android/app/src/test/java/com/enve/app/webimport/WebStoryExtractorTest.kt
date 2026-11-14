package com.enve.app.webimport

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.jsoup.Jsoup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WebStoryExtractorTest {

    @Test
    fun genericIndexKeepsSameOriginChapterLinksOnly() {
        val pageUrl = "http://127.0.0.1:44877/index.html".toHttpUrl()
        val doc = Jsoup.parse(
            """
            <html><body>
              <ul id="chapters">
                <li><a href="/chapter/21/">Arrival</a></li>
                <li><a href="/chapter/22/#top"> Departure </a></li>
                <li><a href="http://evil.example/chapter/23/">Off-site</a></li>
                <li><a href="http://127.0.0.1:44878/chapter/24/">Other port</a></li>
                <li><a href="/about">About</a></li>
                <li><a href="javascript:void(0)">Script</a></li>
              </ul>
              <div class="chapter-row"><a href="/chapter/25/"></a></div>
              <a class="chapter-row" href="/chapter/26/">Loose row</a>
              <p><a href="/chapter/99/">Outside the index</a></p>
            </body></html>
            """.trimIndent(),
            pageUrl.toString(),
        )
        val links = WebStoryExtractor.chapterLinks(doc, pageUrl, fictionId = null)
        assertEquals(listOf("21", "22", "25", "26"), links.map { it.id })
        assertEquals(listOf("Arrival", "Departure", null, "Loose row"), links.map { it.title })
        assertEquals("http://127.0.0.1:44877/chapter/22/", links[1].url.toString())
    }

    @Test
    fun royalRoadIndexKeepsOnlyItsFiction() {
        val pageUrl = "https://www.royalroad.com/fiction/77/the-long-road".toHttpUrl()
        val doc = Jsoup.parse(
            """
            <table id="chapters"><tbody>
              <tr class="chapter-row"><td><a href="/fiction/77/the-long-road/chapter/1/one">1. One</a></td></tr>
              <tr class="chapter-row"><td><a href="/fiction/78/other/chapter/3/three">Other fiction</a></td></tr>
            </tbody></table>
            """.trimIndent(),
            pageUrl.toString(),
        )
        assertEquals(listOf("1"), WebStoryExtractor.chapterLinks(doc, pageUrl, fictionId = "77").map { it.id })
    }

    @Test
    fun metadataPrefersStoryFieldsAndValidatesLanguage() {
        val url = "https://www.royalroad.com/fiction/77/the-long-road".toHttpUrl()
        val doc = Jsoup.parse(
            """
            <html lang="en-GB"><head>
              <title>The Long Road | Royal Road</title>
              <meta property="og:title" content="Ignored">
              <meta property="books:author" content="A. Writer">
            </head><body>
              <div class="fic-title"><h1>The Long Road</h1></div>
              <div class="description"><div class="hidden-content"><p>First.</p><p>Second.</p></div></div>
            </body></html>
            """.trimIndent(),
            url.toString(),
        )
        val metadata = WebStoryExtractor.metadata(doc, url)
        assertEquals("The Long Road", metadata.title)
        assertEquals("A. Writer", metadata.author)
        assertEquals("First.\n\nSecond.", metadata.description)
        assertEquals("en-GB", metadata.language)
        assertEquals("und", WebStoryExtractor.metadata(Jsoup.parse("<html lang=\"en_US x\"></html>"), url).language)
    }

    @Test
    fun contentUsesFirstSelectorWithText() {
        val doc = Jsoup.parse(
            """
            <body><article></article><div class="chapter-inner chapter-content"><p>Story</p></div><main>Other</main></body>
            """.trimIndent(),
        )
        assertEquals("Story", WebStoryExtractor.content(doc).text())
        assertEquals("body", WebStoryExtractor.content(Jsoup.parse("<body><p>Plain</p></body>")).tagName())
    }

    @Test
    fun controlLinksAndHiddenClasses() {
        val doc = Jsoup.parse(
            """
            <html><head>
              <link rel="Next nofollow" href="?page=2">
              <link rel="index" href="/index.html">
              <style>.cjEyNz{display:none;speak:never;} .keep { color: red } .a, .b { display : none } div .nested { display: none }</style>
            </head></html>
            """.trimIndent(),
            "http://127.0.0.1:44877/index.html",
        )
        assertEquals("http://127.0.0.1:44877/index.html?page=2", WebStoryExtractor.nextIndexPage(doc))
        assertEquals("http://127.0.0.1:44877/index.html", WebStoryExtractor.parentIndex(doc))
        assertEquals(setOf("cjEyNz", "a", "b"), WebStoryExtractor.hiddenClasses(doc))
        assertNull(WebStoryExtractor.nextIndexPage(Jsoup.parse("<link rel=\"prefetch\" href=\"/2\">")))
    }
}
