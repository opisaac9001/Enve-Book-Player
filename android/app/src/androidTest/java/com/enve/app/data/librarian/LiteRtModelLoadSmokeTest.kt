package com.enve.app.data.librarian

import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.InputData
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.SessionConfig
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class LiteRtModelLoadSmokeTest {

    @Test
    fun recommendedModelAtConfiguredPath_directLiteRtReturnsAResponse() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val modelFile = File(context.filesDir, "enve-librarian/models/local-model.litertlm")
        val cacheDir = File(context.cacheDir, "litert-lm-direct").also { it.mkdirs() }
        restoreModelIfNeeded(context, modelFile)

        assumeTrue("LiteRT model is not staged on this device", modelFile.isFile)
        assertEquals(EXPECTED_MODEL_BYTES, modelFile.length())

        val book = LibrarianBookRef(
            bookId = "litert-smoke-book",
            sourceName = "LOCAL",
            connectionId = null,
            title = "Smoke Test Book",
            author = "Enve",
            formatName = "epub",
            currentProgress = 0.25,
        )
        val question = "What color is the sky?"
        val bookContext = BookContextResult(
            scope = BookIntelligenceScope.BOOK_SO_FAR,
            rangeStart = 0.0,
            rangeEnd = 0.25,
            text = "The sky is blue.",
            chunkCount = 1,
        )
        val prompt = mirroredLiteRtPrompt(question, book, bookContext)
        Log.i(TAG, "Direct LiteRT prompt follows:\n$prompt")

        val response = Engine(
            EngineConfig(
                modelPath = modelFile.absolutePath,
                backend = Backend.CPU,
                maxNumTokens = 1024,
                cacheDir = cacheDir.absolutePath,
            )
        ).use { engine ->
            engine.initialize()
            assertTrue(engine.isInitialized())
            engine.createSession(
                SessionConfig(
                    samplerConfig = SamplerConfig(topK = 24, topP = 0.82, temperature = 0.2, seed = 0),
                )
            ).use { session ->
                session.generateContent(listOf(InputData.Text(prompt))).trim()
            }
        }

        Log.i(TAG, "Direct LiteRT answer follows:\n$response")
        assertTrue("Expected a non-blank direct LiteRT response", response.isNotBlank())
        assertFalse(
            "Expected direct LiteRT to do more than echo the prompt scaffold.",
            response.contains("Relevant ebook context:", ignoreCase = true),
        )
    }

    @Test
    fun recommendedModelAtConfiguredPath_initializes_and_returns_a_response() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val modelFile = File(context.filesDir, "enve-librarian/models/local-model.litertlm")
        val cacheDir = File(context.cacheDir, "litert-lm-smoke").also { it.mkdirs() }
        restoreModelIfNeeded(context, modelFile)

        assumeTrue("LiteRT model is not staged on this device", modelFile.isFile)
        assertEquals(EXPECTED_MODEL_BYTES, modelFile.length())

        Engine(
            EngineConfig(
                modelPath = modelFile.absolutePath,
                backend = Backend.CPU,
                maxNumTokens = 1024,
                cacheDir = cacheDir.absolutePath,
            )
        ).use { engine ->
            engine.initialize()
            assertTrue(engine.isInitialized())
        }

        val engine = LiteRtLibrarianEngine(context)
        val book = LibrarianBookRef(
            bookId = "litert-smoke-book",
            sourceName = "LOCAL",
            connectionId = null,
            title = "Smoke Test Book",
            author = "Enve",
            formatName = "epub",
            currentProgress = 0.25,
        )
        val question = "What color is the sky?"
        val bookContext = BookContextResult(
            scope = BookIntelligenceScope.BOOK_SO_FAR,
            rangeStart = 0.0,
            rangeEnd = 0.25,
            text = "The sky is blue.",
            chunkCount = 1,
        )
        val prompt = mirroredLiteRtPrompt(question, book, bookContext)
        Log.i(TAG, "LiteRT prompt follows:\n$prompt")

        val answer = engine.answer(question, book, bookContext)
        Log.i(TAG, "LiteRT answer follows:\n${answer.text}")

        assertEquals("Local Model", answer.engineTitle)
        assertTrue("Expected a non-blank answer from LiteRT", answer.text.isNotBlank())
        assertFalse(
            "Expected LiteRT to do more than echo the prompt scaffold.",
            answer.text.contains("Relevant ebook context:", ignoreCase = true),
        )
    }

}

private fun mirroredLiteRtPrompt(
    question: String,
    book: LibrarianBookRef,
    context: BookContextResult,
): String =
    """
    $LIBRARIAN_SYSTEM_INSTRUCTION

    Book: ${book.title}
    Author: ${book.author.orEmpty()}
    Scope: ${context.scope.promptName}

    Relevant ebook context:
    ${context.text}

    Question:
    $question /no_think
    """.trimIndent()

private fun restoreModelIfNeeded(
    context: android.content.Context,
    target: File,
) {
    if (target.isFile && target.length() == EXPECTED_MODEL_BYTES) return
    val staged = sequence {
        @Suppress("DEPRECATION")
        context.externalMediaDirs
            .filterNotNull()
            .forEach { yield(File(it, STAGED_MODEL_NAME)) }
        yield(File("/sdcard/Android/media/com.enve.app.debug/$STAGED_MODEL_NAME"))
        yield(File("/storage/emulated/0/Android/media/com.enve.app.debug/$STAGED_MODEL_NAME"))
    }.firstOrNull { it.isFile }
        ?: return
    target.parentFile?.mkdirs()
    staged.inputStream().use { input ->
        target.outputStream().use { output -> input.copyTo(output) }
    }
}

private const val TAG = "LiteRtModelLoadSmoke"
private const val EXPECTED_MODEL_BYTES = 614_236_160L
private const val STAGED_MODEL_NAME = "local-model.litertlm"
