package com.enve.app.data.kavita

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class KavitaCoverInterceptorTest {
    @Test fun currentServersUseHeadersWithoutFetchingOrPersistingAnImageKey() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setBody("cover"))
            val client = OkHttpClient.Builder().addInterceptor(KavitaCoverInterceptor()).build()
            client.newCall(Request.Builder()
                .url(server.url("/api/image/series-cover?seriesId=3&enveCoverRevision=series:3:r"))
                .header("Authorization", "Bearer fixture").build()).execute().close()
            val request = server.takeRequest()
            assertEquals("Bearer fixture", request.getHeader("Authorization"))
            assertNull(request.requestUrl!!.queryParameter("apiKey"))
            assertEquals(1, server.requestCount)
        }
    }

    @Test fun bearerConnectionsFetchOneImageKeyAndPreserveCoverVersion() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setResponseCode(400))
            server.enqueue(MockResponse().setBody("""{"apiKey":"fixture-image-key"}"""))
            repeat(2) { server.enqueue(MockResponse().setBody("cover")) }
            val client = OkHttpClient.Builder().addInterceptor(KavitaCoverInterceptor()).build()
            repeat(2) {
                val request = Request.Builder()
                    .url(server.url("/prefix/api/image/volume-cover?volumeId=7&v=revision&enveCoverRevision=volume:7:revision"))
                    .header("Authorization", "Bearer header.payload.signature")
                    .header("X-Fixture-Proxy", "proxy-session").build()
                client.newCall(request).execute().use { assertEquals("cover", it.body!!.string()) }
            }
            assertNull(server.takeRequest().requestUrl!!.queryParameter("apiKey"))
            val account = server.takeRequest()
            assertEquals("/prefix/api/Account", account.path)
            assertEquals("Bearer header.payload.signature", account.getHeader("Authorization"))
            assertEquals("proxy-session", account.getHeader("X-Fixture-Proxy"))
            repeat(2) {
                val image = server.takeRequest()
                assertEquals("fixture-image-key", image.requestUrl!!.queryParameter("apiKey"))
                assertEquals("7", image.requestUrl!!.queryParameter("volumeId"))
                assertEquals("revision", image.requestUrl!!.queryParameter("v"))
                assertTrue(image.getHeader("Cache-Control")!!.contains("no-store"))
            }
            assertEquals(4, server.requestCount)
        }
    }

    @Test fun apiKeyConnectionsDoNotRequestAccountAndUnrelatedImagesRemainUntouched() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setResponseCode(400))
            repeat(2) { server.enqueue(MockResponse().setBody("image")) }
            val client = OkHttpClient.Builder().addInterceptor(KavitaCoverInterceptor()).build()
            val url = server.url("/api/image/chapter-cover?chapterId=11&enveCoverRevision=chapter:11:revision&apiKey=expired")
            client.newCall(Request.Builder().url(url).header("X-API-Key", "current-key").build()).execute().close()
            server.takeRequest()
            val image = server.takeRequest()
            assertEquals(listOf("current-key"), image.requestUrl!!.queryParameterValues("apiKey"))
            client.newCall(Request.Builder().url(server.url("/other/image")).header("Authorization", "Bearer other-token").build()).execute().close()
            assertNull(server.takeRequest().requestUrl!!.queryParameter("apiKey"))
            assertEquals(3, server.requestCount)
        }
    }
    @Test fun rejectedLegacyKeyIsRefetchedOnTheNextCoverLoad() {
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setResponseCode(400))
            server.enqueue(MockResponse().setBody("""{"apiKey":"old-key"}"""))
            server.enqueue(MockResponse().setBody("first"))
            server.enqueue(MockResponse().setResponseCode(400))
            server.enqueue(MockResponse().setResponseCode(400))
            server.enqueue(MockResponse().setBody("""{"apiKey":"new-key"}"""))
            server.enqueue(MockResponse().setBody("updated"))
            val client = OkHttpClient.Builder().addInterceptor(KavitaCoverInterceptor()).build()
            val request = Request.Builder()
                .url(server.url("/api/image/series-cover?seriesId=3&enveCoverRevision=series:3:r"))
                .header("Authorization", "Bearer fixture").build()
            client.newCall(request).execute().use { assertEquals("first", it.body!!.string()) }
            client.newCall(request).execute().use { assertEquals(400, it.code) }
            client.newCall(request).execute().use { assertEquals("updated", it.body!!.string()) }
            repeat(6) { server.takeRequest() }
            assertEquals("new-key", server.takeRequest().requestUrl!!.queryParameter("apiKey"))
        }
    }

}
