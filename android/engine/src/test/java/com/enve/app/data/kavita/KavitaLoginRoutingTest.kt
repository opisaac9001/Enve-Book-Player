package com.enve.app.data.kavita

import com.enve.app.data.remote.GrimmoryApi
import com.enve.core.data.remote.dto.LoginRequest
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Test
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

class KavitaLoginRoutingTest {
    @Test
    fun loginTargetsTheEnteredServerIncludingItsBasePath() = runBlocking {
        val existing = MockWebServer()
        val kavita = MockWebServer()
        existing.start()
        kavita.start()
        try {
            kavita.enqueue(MockResponse().setBody("""{"token":"fixture-token"}"""))
            val api = Retrofit.Builder()
                .baseUrl(existing.url("/jellyfin/"))
                .addConverterFactory(Json.asConverterFactory("application/json".toMediaType()))
                .build()
                .create(GrimmoryApi::class.java)

            val response = api.kavitaLogin(
                kavita.url("/kavita/api/Account/login").toString(),
                LoginRequest("fixture-user", "fixture-password"),
            )

            assertEquals(200, response.code())
            val request = kavita.takeRequest()
            assertEquals("POST", request.method)
            assertEquals("/kavita/api/Account/login", request.path)
            assertEquals(0, existing.requestCount)
        } finally {
            kavita.shutdown()
            existing.shutdown()
        }
    }
}
