package com.enve.app.ui.webbrowser

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WebStoryBrowserTest {

    @Test
    fun browsableUrlAcceptsOnlyHttpAndHttpsWithoutCredentials() {
        assertEquals("https://example.com/story", browsableUrl(" https://example.com/story "))
        assertEquals("http://example.com/", browsableUrl("http://example.com"))
        assertNull(browsableUrl("file:///sdcard/book.html"))
        assertNull(browsableUrl("content://com.enve.app/book"))
        assertNull(browsableUrl("javascript:alert(1)"))
        assertNull(browsableUrl("intent://scan/#Intent;scheme=zxing;end"))
        assertNull(browsableUrl("data:text/html,<p>hi</p>"))
        assertNull(browsableUrl("about:blank"))
        assertNull(browsableUrl("https://user:secret@example.com/"))
        assertNull(browsableUrl("example.com"))
    }

    @Test
    fun capturedPageIsReturned() {
        val outcome = parseCaptureResult("""{"s":"ok","h":"<!DOCTYPE html><html><body><p>Hi</p></body></html>"}""")
        assertEquals(CaptureOutcome.Captured("<!DOCTYPE html><html><body><p>Hi</p></body></html>"), outcome)
    }

    @Test
    fun scriptStatusesMapToNotices() {
        assertEquals(CaptureOutcome.Failed(BrowserNotice.NAVIGATED), parseCaptureResult("""{"s":"navigated"}"""))
        assertEquals(CaptureOutcome.Failed(BrowserNotice.EMPTY), parseCaptureResult("""{"s":"empty"}"""))
        assertEquals(CaptureOutcome.Failed(BrowserNotice.TOO_LARGE), parseCaptureResult("""{"s":"too_large"}"""))
        assertEquals(CaptureOutcome.Failed(BrowserNotice.CAPTURE_FAILED), parseCaptureResult("""{"s":"failed"}"""))
    }

    @Test
    fun malformedOrMissingResultsFail() {
        val failed = CaptureOutcome.Failed(BrowserNotice.CAPTURE_FAILED)
        assertEquals(failed, parseCaptureResult(null))
        assertEquals(failed, parseCaptureResult("null"))
        assertEquals(failed, parseCaptureResult("\"ok\""))
        assertEquals(failed, parseCaptureResult("{not json"))
        assertEquals(failed, parseCaptureResult("""{"s":"ok"}"""))
        assertEquals(failed, parseCaptureResult("""{"s":"ok","h":42}"""))
        assertEquals(failed, parseCaptureResult("""{"s":"ok","h":"   "}"""))
    }

    @Test
    fun oversizedCaptureIsRejected() {
        val outcome = parseCaptureResult("""{"s":"ok","h":"${"a".repeat(11)}"}""", maxChars = 10)
        assertEquals(CaptureOutcome.Failed(BrowserNotice.TOO_LARGE), outcome)
    }

    @Test
    fun captureScriptEmbedsExpectedUrlAsJsonString() {
        val script = captureScript("https://example.com/a\"b\\c')")
        assertTrue(script.contains("""("https://example.com/a\"b\\c')", $MAX_CAPTURE_CHARS, """))
        assertTrue(script.startsWith("(function (expected, maxChars, maxElements, chapters)"))
        assertTrue(script.endsWith(", null)"))
    }

    @Test
    fun captureScriptEmbedsCollectedChaptersAsJson() {
        val script = captureScript(INDEX, listOf(RoyalRoadChapter("11", chapterUrl("11"), "One \"quoted\"")))
        assertTrue(script.endsWith(""", [{"url":"${chapterUrl("11")}","title":"One \"quoted\""}])"""))
    }

    @Test
    fun tableScriptEscapesArguments() {
        val script = tableScript(INDEX, "123", "next")
        assertTrue(script.endsWith("""("$INDEX", "123", "next", $MAX_TABLE_CHAPTERS)"""))
    }

    @Test
    fun chaptersStatusMapsToUnreadableNotice() {
        assertEquals(CaptureOutcome.Failed(BrowserNotice.CHAPTERS_UNREADABLE), parseCaptureResult("""{"s":"chapters"}"""))
    }

    @Test
    fun royalRoadFictionIdRecognizesOnlyHttpsFictionIndexes() {
        assertEquals("123", royalRoadFictionId("https://www.royalroad.com/fiction/123/a-story"))
        assertEquals("123", royalRoadFictionId("https://royalroad.com/fiction/123"))
        assertEquals("123", royalRoadFictionId("https://www.royalroad.com/fiction/123/a-story?tab=chapters"))
        assertNull(royalRoadFictionId("http://www.royalroad.com/fiction/123/a-story"))
        assertNull(royalRoadFictionId(chapterUrl("11")))
        assertNull(royalRoadFictionId("https://www.royalroad.com/fiction/123/a-story/reviews"))
        assertNull(royalRoadFictionId("https://royalroad.com.example.net/fiction/123/a-story"))
        assertNull(royalRoadFictionId("https://user@www.royalroad.com/fiction/123/a-story"))
    }

    @Test
    fun tableStateParsesVisiblePageAndControls() {
        val step = parseTableState(tableJson(active = 2, pages = 3, rows = chapters("21", "22"), next = true), "123")
        val state = (step as TableStep.Ready).state
        assertEquals(2, state.active)
        assertEquals(3, state.pages)
        assertEquals(listOf("21", "22"), state.chapterIds)
        assertEquals("Chapter 21", state.chapters.first().title)
        assertTrue(state.hasNext)
        assertNull(state.embedded)
    }

    @Test
    fun tableStateRejectsForeignInvalidOrDuplicateChapters() {
        val unreadable = TableStep.Failed(BrowserNotice.CHAPTERS_UNREADABLE)
        val foreign = """[{"id":"11","url":"https://www.royalroad.com/fiction/999/other/chapter/11/x","title":"x"}]"""
        val insecure = """[{"id":"11","url":"http://www.royalroad.com/fiction/123/a-story/chapter/11/x","title":"x"}]"""
        val mismatched = """[{"id":"12","url":"${chapterUrl("11")}","title":"x"}]"""
        assertEquals(unreadable, parseTableState(tableJson(rows = foreign), "123"))
        assertEquals(unreadable, parseTableState(tableJson(rows = insecure), "123"))
        assertEquals(unreadable, parseTableState(tableJson(rows = mismatched), "123"))
        assertEquals(unreadable, parseTableState(tableJson(rows = chapters("11", "11")), "123"))
        assertEquals(unreadable, parseTableState(tableJson(active = 3, pages = 2), "123"))
    }

    @Test
    fun embeddedChaptersAcceptedOnlyWhenCountAndFirstPageMatch() {
        fun embedded(json: String, pages: Int, visible: String = chapters("1", "2")) =
            (parseTableState(tableJson(pages = pages, rows = visible, embedded = json), "123") as TableStep.Ready).state.embedded

        assertEquals(listOf("1", "2"), embedded(chapters("1", "2"), pages = 1)?.map { it.id })
        assertEquals(5, embedded(chapters("1", "2", "3", "4", "5"), pages = 3)?.size)
        assertNull(embedded(chapters("1", "2", "3"), pages = 1))
        assertNull(embedded(chapters("1", "2", "3", "4", "5", "6", "7"), pages = 3))
        assertNull(embedded(chapters("1", "2", "3", "4"), pages = 3))
        assertNull(embedded(chapters("2", "1", "3"), pages = 2))
        assertNull(embedded("""[{"id":"1","url":"javascript:alert(1)","title":"x"}]""", pages = 1, visible = chapters("1")))
    }

    @Test
    fun embeddedChaptersIgnoredAwayFromFirstPage() {
        val step = parseTableState(tableJson(active = 2, pages = 2, embedded = chapters("1", "2", "3", "4")), "123")
        assertNull((step as TableStep.Ready).state.embedded)
    }

    @Test
    fun tableStatusesMapToSteps() {
        assertEquals(TableStep.Clicked, parseTableState("""{"s":"clicked"}""", "123"))
        assertEquals(TableStep.Failed(BrowserNotice.NAVIGATED), parseTableState("""{"s":"navigated"}""", "123"))
        assertEquals(TableStep.Failed(BrowserNotice.CHAPTERS_UNREADABLE), parseTableState("""{"s":"unsafe"}""", "123"))
        assertEquals(TableStep.Failed(BrowserNotice.CHAPTERS_UNREADABLE), parseTableState("""{"s":"missing"}""", "123"))
        assertEquals(TableStep.Failed(BrowserNotice.CHAPTERS_UNREADABLE), parseTableState(null, "123"))
    }

    private companion object {
        const val INDEX = "https://www.royalroad.com/fiction/123/a-story"

        fun chapterUrl(id: String) = "https://www.royalroad.com/fiction/123/a-story/chapter/$id/part-$id"

        fun chapters(vararg ids: String) =
            ids.joinToString(",", "[", "]") { """{"id":"$it","url":"${chapterUrl(it)}","title":"Chapter $it"}""" }

        fun tableJson(
            active: Int = 1,
            pages: Int = 1,
            rows: String = chapters("1", "2"),
            embedded: String = "null",
            next: Boolean = false,
        ) = """{"s":"ok","active":$active,"pages":$pages,"chapters":$rows,"embedded":$embedded,"first":true,"next":$next}"""
    }
}
