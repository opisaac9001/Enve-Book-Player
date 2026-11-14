package com.enve.app.webimport

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.jsoup.Jsoup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebStorySanitizerTest {

    private val baseUrl = "https://example.com/story/".toHttpUrl()

    private val maliciousHtml = """
        <html><head><base href="https://evil.example/"></head><body>
        <div id="story">
          <h1>Chapter One</h1>
          <p>Hello <b onclick="steal()">world</b> &amp; friends ]]&gt; <!-- hidden comment --></p>
          <script>alert(1)</script>
          <p><a href="javascript:alert(1)">bad link</a> <a href="/next" onmouseover="x()">good link</a></p>
          <p><a href="data:text/html;base64,PHNjcmlwdD4=">data link</a> <a href="vbscript:msgbox">vb link</a></p>
          <p>Before <img src="https://tracker.example/pixel.gif" onerror="alert(1)" alt="A &quot;map&quot; of the coast"> after</p>
          <img src="https://tracker.example/decor.png" alt="">
          <img src="data:image/svg+xml;base64,PHN2Zz4=">
          <svg onload="alert(2)"><script>alert(2)</script><text>svg text</text></svg>
          <iframe src="https://evil.example/frame"></iframe>
          <object data="movie.swf"></object><embed src="movie.swf">
          <style>p { color: red }</style>
          <link rel="stylesheet" href="https://evil.example/x.css">
          <meta http-equiv="refresh" content="0;url=https://evil.example">
          <p style="display: none">hidden inline</p>
          <p hidden>hidden attribute</p>
          <p class="cmZjOT anti">Unauthorized usage notice</p>
          <form action="https://evil.example/post"><input name="q"><button>Go</button></form>
          <p><span style="color:red" class="x" id="y">styled</span> <math><mi>x</mi></math></p>
          <p>Escaped &lt;script&gt;alert(3)&lt;/script&gt; stays text</p>
          <p>Entities&nbsp;&copy; &#x1F600;</p>
          <p>CONTROL_PLACEHOLDER</p>
          <table><tr><td colspan="2" onclick="x()" style="width:9px">cell</td></tr></table>
        </div></body></html>
    """.trimIndent().replace("CONTROL_PLACEHOLDER", "Bell\u0007 form\u000C lone\uD800 nul\u0000 end")

    private fun sanitized(): String {
        val doc = Jsoup.parse(maliciousHtml, baseUrl.toString())
        return WebStorySanitizer.sanitize(doc.selectFirst("#story")!!, baseUrl, setOf("cmZjOT"), title = "Chapter One")!!
    }

    @Test
    fun removesActiveContentRemoteImagesAndHiddenText() {
        val xhtml = sanitized()
        listOf(
            "<img", "tracker.example", "<script", "alert(1)", "alert(2)", "onclick", "onerror", "onload", "onmouseover",
            "javascript:", "vbscript:", "data:", "<iframe", "<object", "<embed", "<svg", "<math", "<style", "<link",
            "<meta", "<base", "<form", "<input", "<button", "style=", "class=", "id=", "hidden inline",
            "hidden attribute", "Unauthorized usage", "hidden comment", "evil.example", "<span", "svg text",
        ).forEach { forbidden -> assertFalse("found $forbidden in $xhtml", xhtml.contains(forbidden)) }
    }

    @Test
    fun keepsStructureLinksAltTextAndEscapedText() {
        val xhtml = sanitized()
        assertTrue(xhtml.contains("<b>world</b>"))
        assertTrue(xhtml.contains("<a href=\"https://example.com/next\">good link</a>"))
        assertTrue(xhtml.contains("Before  A \"map\" of the coast  after") || xhtml.contains("Before  A &quot;map&quot; of the coast  after"))
        assertTrue(xhtml.contains("Escaped &lt;script&gt;alert(3)&lt;/script&gt; stays text"))
        assertTrue(xhtml.contains("<td colspan=\"2\">cell</td>"))
        assertTrue(xhtml.contains("bad link"))
        assertFalse(xhtml.contains("Chapter One"))
    }

    @Test
    fun outputIsWellFormedXmlWithoutInvalidCharacters() {
        val xhtml = sanitized()
        listOf('\u0007', '\u000C', '\u0000', '\uD800').forEach { assertFalse(xhtml.contains(it)) }
        assertTrue(xhtml.contains("Bell form lone nul end"))
        assertTrue(xhtml.contains("😀"))
        val root = parseXml("<div xmlns=\"http://www.w3.org/1999/xhtml\">$xhtml</div>").documentElement
        assertTrue(root.textContent.contains("friends ]]>"))
    }

    @Test
    fun contentWithoutReadableTextIsRejected() {
        val doc = Jsoup.parse("<div id=\"c\"><script>x()</script><img src=\"a.png\"><nav>Menu</nav><p> </p></div>")
        assertNull(WebStorySanitizer.sanitize(doc.selectFirst("#c")!!, baseUrl, emptySet(), title = null))
    }

    @Test
    fun plainTextIsCollapsedBoundedAndXmlSafe() {
        assertEquals("A title", WebStorySanitizer.plainText("  A\n\t title\u0001 ", 100))
        assertEquals("abc", WebStorySanitizer.plainText("abcdef", 3))
        assertNull(WebStorySanitizer.plainText("   ", 10))
    }
}
