package com.enve.app.data.hardcover

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import okhttp3.Headers.Companion.headersOf
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

class HardcoverRequestPacerTest {
    private class FakeTime(var now: Long = 0L, val advances: Boolean = true) {
        val sleeps = mutableListOf<Long>()
        var hang = false

        suspend fun sleep(ms: Long) {
            if (hang) awaitCancellation()
            sleeps += ms
            if (advances) now += ms
            yield()
        }
    }

    private fun pacer(time: FakeTime, maxWaitMs: Long = 30_000) =
        HardcoverRequestPacer({ time.now }, time::sleep, maxWaitMs)

    private fun result(code: Int, retryAfterMs: Long? = null, limit: Int? = null, remaining: Int? = null) =
        HardcoverHttpResult(code, "{}", HardcoverRateObservation(limit, remaining, retryAfterMs, throttled = code == 429))

    @Test fun rootFieldsAreCountedLikeHardcoverBillsThem() {
        assertEquals(1, hardcoverRootFieldCount("query { me { id username } }"))
        assertEquals(2, hardcoverRootFieldCount("query Test {\n  me { username }\n  m2:me { name }\n}"))
        assertEquals(1, hardcoverRootFieldCount("query { __typename me { id } }"))
        assertEquals(1, hardcoverRootFieldCount("""query S(${'$'}q: String!) { search(query: "a { b ) c", query_type: "Book") { results } }"""))
        assertEquals(1, hardcoverRootFieldCount("mutation U(${'$'}id: Int!, ${'$'}object: DatesReadInput!) { update_user_book_read(id: ${'$'}id, object: ${'$'}object) { id error } }"))
        assertEquals(
            3,
            hardcoverRootFieldCount(
                "query B(${'$'}bookId: Int!, ${'$'}editionId: Int!) { me { user_books { id } } books_by_pk(id: ${'$'}bookId) { id } " +
                    "selected_edition: editions_by_pk(id: ${'$'}editionId) { id } }",
            ),
        )
    }

    @Test fun retryAfterAcceptsSecondsAndHttpDates() {
        assertEquals(120_000L, hardcoverRetryAfterMs("120", serverNowMs = 0))
        assertEquals(3_600_000L, hardcoverRetryAfterMs(" 3600 ", serverNowMs = 0))
        assertEquals(0L, hardcoverRetryAfterMs("-4", serverNowMs = 0))
        val format = SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss 'GMT'", Locale.US).apply { timeZone = TimeZone.getTimeZone("GMT") }
        val serverNow = 1_445_412_390_000L
        assertEquals(90_000L, hardcoverRetryAfterMs(format.format(serverNow + 90_000), serverNow))
        assertEquals(7_200_000L, hardcoverRetryAfterMs(format.format(serverNow + 7_200_000), serverNow))
        assertEquals(0L, hardcoverRetryAfterMs(format.format(serverNow - 60_000), serverNow))
        assertNull(hardcoverRetryAfterMs("soon", serverNow))
        assertNull(hardcoverRetryAfterMs(null, serverNow))
    }

    @Test fun rateHeadersAreRead() {
        val observation = hardcoverRateObservation(
            429,
            headersOf("x-ratelimit-limit", "10", "X-RateLimit-Remaining", "0", "Retry-After", "7"),
            nowMs = 0,
        )
        assertEquals(HardcoverRateObservation(limit = 10, remaining = 0, retryAfterMs = 7_000, throttled = true, cooldownMs = 60_000), observation)
    }

    @Test fun concurrentCallersAreSpacedAboutOneRootFieldPerSecond() = runBlocking {
        val time = FakeTime(advances = false)
        val pacer = pacer(time)
        coroutineScope { repeat(3) { launch { pacer.acquire(1) } } }
        assertEquals(listOf(1_000L, 2_000L), time.sleeps)
    }

    @Test fun multiRootRequestsConsumeOneTokenPerField() = runBlocking {
        val time = FakeTime(advances = false)
        val pacer = pacer(time)
        pacer.acquire(3)
        pacer.acquire(1)
        assertEquals(listOf(3_000L), time.sleeps)
    }

    @Test fun reportedBurstIsAdoptedOnceNothingElseIsOutstanding() = runBlocking {
        val time = FakeTime(advances = false)
        val pacer = pacer(time)
        pacer.acquire(1)
        pacer.complete(HardcoverRateObservation(limit = 10, remaining = 9, retryAfterMs = null, throttled = false))
        repeat(9) { pacer.acquire(1) }
        assertTrue(time.sleeps.isEmpty())
        pacer.acquire(1)
        assertEquals(listOf(1_000L), time.sleeps)
    }

    @Test fun throttledResponseHoldsEveryCallerUntilRetryAfter() = runBlocking {
        val time = FakeTime()
        val pacer = pacer(time)
        pacer.acquire(1)
        pacer.complete(HardcoverRateObservation(limit = null, remaining = null, retryAfterMs = 5_000, throttled = true))
        pacer.acquire(1)
        assertEquals(5_000L, time.sleeps.sum())
    }

    @Test fun longCooldownFailsFastWithRetryTimeInsteadOfHoldingTheCaller() = runBlocking {
        val time = FakeTime()
        val pacer = pacer(time)
        pacer.acquire(1)
        pacer.complete(HardcoverRateObservation(limit = null, remaining = null, retryAfterMs = 3_600_000, throttled = true))
        val error = assertThrows(HardcoverRateLimitedException::class.java) { runBlocking { pacer.acquire(1) } }
        assertEquals(3_600_000L, error.retryAfterMs)
        assertTrue(error.message!!.contains("60 minutes"))
        assertTrue(time.sleeps.isEmpty())
    }

    @Test fun cancelledWaiterReleasesItsReservation() = runBlocking {
        val time = FakeTime(advances = false)
        val pacer = pacer(time)
        pacer.acquire(1)
        time.hang = true
        val waiter = launch { pacer.acquire(1) }
        yield()
        waiter.cancel()
        waiter.join()
        time.hang = false
        pacer.complete(HardcoverRateObservation(limit = 10, remaining = 5, retryAfterMs = null, throttled = false))
        repeat(5) { pacer.acquire(1) }
        assertTrue(time.sleeps.isEmpty())
    }

    @Test fun throttledExchangeRetriesAfterSharedCooldown() = runBlocking {
        val time = FakeTime()
        val responses = ArrayDeque(listOf(result(429, retryAfterMs = 2_000), result(200)))
        var calls = 0
        val outcome = hardcoverPacedExchange(pacer(time), cost = 1, ensureAccount = {}) {
            calls++
            responses.removeFirst()
        }
        assertEquals(200, outcome.code)
        assertEquals(2, calls)
        assertEquals(2_000L, time.sleeps.sum())
    }

    @Test fun throttledExchangeWithLongRetryAfterIsNotResent() {
        val time = FakeTime()
        var calls = 0
        val error = assertThrows(HardcoverRateLimitedException::class.java) {
            runBlocking {
                hardcoverPacedExchange(pacer(time), cost = 1, ensureAccount = {}) {
                    calls++
                    result(429, retryAfterMs = 600_000)
                }
            }
        }
        assertEquals(1, calls)
        assertEquals(600_000L, error.retryAfterMs)
    }

    @Test fun serverErrorsAreReturnedWithoutBlindRetry() = runBlocking {
        var calls = 0
        val outcome = hardcoverPacedExchange(pacer(FakeTime()), cost = 1, ensureAccount = {}) {
            calls++
            result(503)
        }
        assertEquals(503, outcome.code)
        assertEquals(1, calls)
    }

    @Test fun accountChangeDuringCooldownAbortsTheRetry() {
        val time = FakeTime()
        var calls = 0
        var checks = 0
        assertThrows(HardcoverAccountChangedException::class.java) {
            runBlocking {
                hardcoverPacedExchange(pacer(time), cost = 1, ensureAccount = { if (++checks > 1) throw HardcoverAccountChangedException() }) {
                    calls++
                    result(429, retryAfterMs = 1_000)
                }
            }
        }
        assertEquals(1, calls)
    }

    @Test fun exchangeReadsAndClosesResponseBeforeReturning() = runBlocking {
        val server = MockWebServer()
        server.enqueue(
            MockResponse()
                .setResponseCode(429)
                .setHeader("X-RateLimit-Limit", "10")
                .setHeader("X-RateLimit-Remaining", "0")
                .setHeader("Retry-After", "30")
                .setBody("""{"error":"Too Many Requests"}"""),
        )
        server.start()
        try {
            val exchanged = hardcoverExchange(OkHttpClient(), Request.Builder().url(server.url("/v1/graphql")).build())
            assertEquals(429, exchanged.code)
            assertEquals("""{"error":"Too Many Requests"}""", exchanged.body)
            assertEquals(HardcoverRateObservation(10, 0, 30_000, throttled = true, cooldownMs = 60_000), exchanged.rate)
        } finally {
            server.shutdown()
        }
    }
    @Test fun dailyStructuredLimitsBlockAllRequestsBeforeAnother429() = runBlocking {
        val time = FakeTime()
        val pacer = pacer(time)
        pacer.acquire(1)
        val observation = hardcoverRateObservation(200,
            headersOf("RateLimit", "\"Free\";r=10;t=1, \"daily\";r=0;t=7200"), 0)
        pacer.complete(observation)
        val error = assertThrows(HardcoverRateLimitedException::class.java) { runBlocking { pacer.acquire(1) } }
        assertEquals(7_200_000L, error.retryAfterMs)
        assertTrue(time.sleeps.isEmpty())
    }

}
