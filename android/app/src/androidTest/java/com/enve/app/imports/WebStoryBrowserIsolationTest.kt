package com.enve.app.imports

import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.ui.webbrowser.WebStoryBrowser
import com.enve.app.ui.webbrowser.isWebStoryBrowserAvailable
import com.enve.hearth.design.HearthTheme
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.util.concurrent.CopyOnWriteArrayList

@RunWith(AndroidJUnit4::class)
class WebStoryBrowserIsolationTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun captureDropsHiddenContentAndEachVisitGetsItsOwnCookies() {
        assumeTrue(isWebStoryBrowserAvailable())
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val visit = request.requestUrl?.queryParameter("visit") ?: return MockResponse().setResponseCode(404)
                val cookies = request.getHeader("Cookie").orEmpty()
                val body = """<!doctype html><html><head><title>Loading</title>
                    <style>.decoration{display:none}</style></head><body><main>
                    <p class="decoration">Hidden margin note</p>
                    <p>${if ("fixture_visit=" in cookies) "Previous visit" else "Fresh visit"}</p>
                    </main><script>
                    addEventListener('load', () => setTimeout(() => {
                      const p=document.createElement('p');
                      p.textContent='The orchard comes into view.';
                      document.querySelector('main').appendChild(p);
                      document.cookie='fixture_visit=seen; path=/';
                      document.title='Rendered visit $visit';
                    }, 100));
                    </script></body></html>"""
                return MockResponse().setHeader("Content-Type", "text/html; charset=utf-8").setBody(body)
            }
        }
        server.start(InetAddress.getByName("127.0.0.1"), 0)
        try {
            val baseUrl = server.url("/story").toString()
            val visit = mutableIntStateOf(1)
            val captures = CopyOnWriteArrayList<Pair<String, String>>()
            compose.setContent {
                HearthTheme {
                    key(visit.intValue) {
                        WebStoryBrowser("$baseUrl?visit=${visit.intValue}", onClose = {}) { url, html ->
                            captures += url to html
                        }
                    }
                }
            }
            for (number in 1..2) {
                compose.waitUntil(20_000) {
                    compose.onAllNodes(hasText("Rendered visit $number")).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
                }
                compose.onNodeWithText("Import this page").performClick()
                compose.waitUntil(10_000) { captures.size == number }
                val (url, html) = captures[number - 1]
                assertEquals(server.url("/story?visit=$number").toString(), url)
                assertTrue("The orchard comes into view." in html)
                assertTrue("Fresh visit" in html)
                assertFalse("Hidden margin note" in html)
                assertFalse("document.cookie" in html)
                if (number == 1) compose.runOnIdle { visit.intValue = 2 }
            }
        } finally {
            server.shutdown()
        }
    }
}
