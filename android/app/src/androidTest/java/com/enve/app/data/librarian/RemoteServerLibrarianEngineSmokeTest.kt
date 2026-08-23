package com.enve.app.data.librarian

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.auth.CredentialVault
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.net.HttpURLConnection
import java.net.URL

@RunWith(AndroidJUnit4::class)
class RemoteServerLibrarianEngineSmokeTest {

    @Test
    fun configuredServer_listsModels_and_answers() = runBlocking {
        assumeTrue("No OpenAI-compatible server at localhost:11434", serverReachable())
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = LibrarianRemoteServerStore(context, CredentialVault(context))
        store.save(LibrarianRemoteServerSettings(serverUrl = "localhost:11434", model = ""))
        store.saveApiKey(null)
        val engine = RemoteServerLibrarianEngine(store)

        val models = engine.availableModels()
        assertTrue("Expected at least one model from /models", models.isNotEmpty())

        store.save(LibrarianRemoteServerSettings(serverUrl = "localhost:11434", model = models.first()))
        val answer = engine.answer(
            question = "What color is the sky?",
            book = LibrarianBookRef(
                bookId = "remote-smoke-book",
                sourceName = "LOCAL",
                connectionId = null,
                title = "Smoke Test Book",
                author = "Enve",
                formatName = "epub",
                currentProgress = 0.25,
            ),
            context = BookContextResult(
                scope = BookIntelligenceScope.BOOK_SO_FAR,
                rangeStart = 0.0,
                rangeEnd = 0.25,
                text = "The sky is blue.",
                chunkCount = 1,
            ),
        )
        assertEquals("Local Server", answer.engineTitle)
        assertTrue("Expected a non-blank answer", answer.text.isNotBlank())
    }

    private fun serverReachable(): Boolean = runCatching {
        val connection = URL("http://localhost:11434/v1/models").openConnection() as HttpURLConnection
        connection.connectTimeout = 2_000
        connection.readTimeout = 2_000
        connection.responseCode in 200..499
    }.getOrDefault(false)
}
