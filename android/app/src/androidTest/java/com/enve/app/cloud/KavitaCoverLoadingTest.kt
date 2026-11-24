package com.enve.app.cloud

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import androidx.core.graphics.drawable.toBitmap
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import coil.ImageLoader
import coil.decode.DataSource
import coil.disk.DiskCache
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.enve.app.data.kavita.KavitaCoverInterceptor
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test
import org.junit.runner.RunWith

@OptIn(coil.annotation.ExperimentalCoilApi::class)
@RunWith(AndroidJUnit4::class)
class KavitaCoverLoadingTest {
    @Test
    fun changedArtworkReplacesCachedImageAndRemainsAvailableOffline() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val directory = File(context.cacheDir, "kavita-cover-test-${System.nanoTime()}")
        val disk = DiskCache.Builder().directory(directory).maxSizeBytes(5L * 1024 * 1024).build()
        MockWebServer().use { server ->
            server.start()
            server.enqueue(MockResponse().setResponseCode(400))
            server.enqueue(MockResponse().setBody("""{"apiKey":"test-image-key"}"""))
            server.enqueue(image(Color.RED))
            server.enqueue(image(Color.BLUE))
            val client = OkHttpClient.Builder()
                .addInterceptor { chain -> chain.proceed(chain.request().newBuilder().header("Authorization", "Bearer fixture").build()) }
                .addInterceptor(KavitaCoverInterceptor()).build()
            val loader = ImageLoader.Builder(context).okHttpClient(client).diskCache(disk).respectCacheHeaders(false).build()
            fun request(revision: String) = ImageRequest.Builder(context)
                .data(server.url("/api/image/volume-cover?volumeId=7&v=$revision&enveCoverRevision=volume:7:$revision").toString())
                .allowHardware(false).build()
            try {
                val first = loader.execute(request("first")) as SuccessResult
                assertEquals(Color.RED, first.drawable.toBitmap().getPixel(0, 0))
                val changed = loader.execute(request("changed")) as SuccessResult
                assertEquals(Color.BLUE, changed.drawable.toBitmap().getPixel(0, 0))
                assertEquals(4, server.requestCount)
                loader.memoryCache?.clear()
                val offline = loader.execute(request("changed")) as SuccessResult
                assertEquals(DataSource.DISK, offline.dataSource)
                assertEquals(Color.BLUE, offline.drawable.toBitmap().getPixel(0, 0))
                assertEquals(4, server.requestCount)
                assertNotNull(offline.diskCacheKey)
            } finally {
                loader.shutdown()
                disk.clear()
                directory.deleteRecursively()
            }
        }
    }

    private fun image(color: Int): MockResponse {
        val bitmap = Bitmap.createBitmap(32, 48, Bitmap.Config.ARGB_8888).apply { eraseColor(color) }
        val bytes = ByteArrayOutputStream().use { stream ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            stream.toByteArray()
        }
        bitmap.recycle()
        return MockResponse().setHeader("Content-Type", "image/png").setBody(Buffer().write(bytes))
    }
}
