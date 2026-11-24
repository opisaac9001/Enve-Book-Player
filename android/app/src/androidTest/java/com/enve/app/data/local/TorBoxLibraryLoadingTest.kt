package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.model.BookSource
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class TorBoxLibraryLoadingTest {
    @Test
    fun rejectedTokenDoesNotReplaceSavedCredentials() = runBlocking {
        val runtimes = ProfileRuntimeRegistry(ApplicationProvider.getApplicationContext<Context>())
        val id = UUID.randomUUID().toString()
        val component = runtimes.open(id)
        val locations = component.storageLocations()
        try {
            val originalSource = component.preferences().getActiveBookSourceSync()
            component.vault().put(CredentialVault.KEY_ACCESS_TOKEN, "existing-fixture")
            val repository = component.grimmoryRepository()
            MockWebServer().use { server ->
                for (status in listOf(401, 403, 200)) {
                    server.enqueue(MockResponse().setResponseCode(status)
                        .setBody("""{"success":false,"error":"BAD_TOKEN","detail":"private-fixture"}"""))
                    val result = repository.loginWithToken(BookSource.TORBOX, server.url("/v1/api").toString(), "", "rejected-fixture")
                    assertEquals("Bearer rejected-fixture", server.takeRequest(5, TimeUnit.SECONDS)?.getHeader("Authorization"))
                    assertTrue(result.isFailure)
                    assertTrue(!result.exceptionOrNull()!!.message!!.contains("private-fixture"))
                    assertEquals("existing-fixture", component.vault().get(CredentialVault.KEY_ACCESS_TOKEN))
                    assertTrue(component.connections().getConnectionsSync().isEmpty())
                    assertEquals(originalSource, component.preferences().getActiveBookSourceSync())
                }
            }
        } finally {
            runtimes.close(id)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

    @Test
    fun downloadedTorBoxTrackMeasuresDurationWhenApiHasNone() = runBlocking {
        val runtimes = ProfileRuntimeRegistry(ApplicationProvider.getApplicationContext<Context>())
        val id = UUID.randomUUID().toString()
        val component = runtimes.open(id)
        val locations = component.storageLocations()
        try {
            val dataSize = 32_000
            val wav = ByteBuffer.allocate(44 + dataSize).order(ByteOrder.LITTLE_ENDIAN)
                .put("RIFF".toByteArray()).putInt(36 + dataSize).put("WAVEfmt ".toByteArray())
                .putInt(16).putShort(1).putShort(1).putInt(16_000).putInt(32_000)
                .putShort(2).putShort(16).put("data".toByteArray()).putInt(dataSize).array()
            val file = File(locations.cacheDirectory, "duration-fixture.wav").apply {
                check(parentFile!!.isDirectory || parentFile!!.mkdirs())
                writeBytes(wav)
            }
            val method = component.downloads().javaClass.getDeclaredMethod(
                "downloadedTrackDuration", BookSource::class.java, Long::class.javaPrimitiveType, File::class.java,
            ).apply { isAccessible = true }
            assertEquals(1000L, method.invoke(component.downloads(), BookSource.TORBOX, 0L, file))
        } finally {
            runtimes.close(id)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

}
