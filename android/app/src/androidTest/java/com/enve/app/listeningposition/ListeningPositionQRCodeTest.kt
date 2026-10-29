package com.enve.app.listeningposition

import android.content.Context
import android.graphics.Bitmap
import androidx.core.content.FileProvider
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.hearth.listeningposition.ListeningPositionQRCode
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import com.enve.core.listeningposition.ListeningPositionPayloadException
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListeningPositionQRCodeTest {
    @Test fun androidUnicodeCodeRoundTripsThroughTheFileImporter() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val payload = ListeningPositionPayload(1234500, 5400000, "Le \"Petit\" Prince \\ Édition", listOf("Antoine de Saint-Exupéry"))
        val bitmap = ListeningPositionQRCode.image(payload.encoded())
        val data = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bitmap.recycle()
        val file = File(context.cacheDir, "listening-position-share/android-interop.png").apply { parentFile!!.mkdirs(); writeBytes(data) }
        val uri = FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", file)
        assertEquals(listOf(payload.encoded()), ListeningPositionQRCode.messages(context, uri))
        savePositionEvidence("enve-position-interop-oct28.png", data)
    }

    @Test fun importsActualIosScreenCapture() {
        val context = InstrumentationRegistry.getInstrumentation().context
        val data = context.assets.open("listening-position/ios.png").use { it.readBytes() }
        val messages = ListeningPositionQRCode.decode(data)
        assertEquals(1, messages.size)
        val payload = ListeningPositionPayload.decode(messages.single())
        assertEquals("Chapter Grouping Fixture", payload.title)
        assertEquals(0L, payload.positionMilliseconds)
        assertEquals(2000000L, payload.durationMilliseconds)
    }

    @Test fun rejectsOversizedAndMalformedImages() {
        assertThrows(IllegalArgumentException::class.java) { ListeningPositionQRCode.decode(ByteArray(20 * 1024 * 1024 + 1)) }
        assertThrows(IllegalArgumentException::class.java) { ListeningPositionQRCode.decode(byteArrayOf(1, 2, 3)) }
    }

    @Test fun malformedUnicodeAndNestedPayloadsAreRejectedOnAndroid() {
        val malformed = """{"dur":3600000,"k":"enve.position","pos":0,"t":"\uD800","v":1}"""
        assertThrows(ListeningPositionPayloadException::class.java) { ListeningPositionPayload.decode(malformed) }
        for (depth in listOf(8, 64, 256, 500)) {
            assertThrows(ListeningPositionPayloadException::class.java) { ListeningPositionPayload.decode("[".repeat(depth) + "0" + "]".repeat(depth)) }
        }
    }


    @Test fun importerRejectsUrlAndPrivateFileSources() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        for (uri in listOf("https://evil.example/code.png", "file:///data/user/0/com.enve.app.debug/private.png")) {
            try {
                ListeningPositionQRCode.messages(context, android.net.Uri.parse(uri))
                fail("Only a selected content URI may be imported")
            } catch (_: IllegalArgumentException) { }
        }
    }

    @Test fun richReadingCodeAtTheByteLimitRoundTrips() {
        val cfi = "epubcfi(/6/4!/4/2/1:7)"
        val locator = """{"href":"OPS/chapter.xhtml","locations":{"cfi":"$cfi","cssSelector":"#p3","progression":0.5,"totalProgression":0.25},"text":{"highlight":"A passage"},"type":"application/xhtml+xml"}"""
        val payload = ListeningPositionPayload(0, 0, "A Book", readingLocation = com.enve.core.listeningposition.SharedReadingLocation(
            "epub", 250000, "OPS/chapter.xhtml", 500000, epubCfi = cfi, readiumLocatorJson = locator,
        ))
        val encoded = payload.encoded()
        val boundary = encoded + " ".repeat(ListeningPositionPayload.MAX_ENCODED_BYTES - encoded.toByteArray(Charsets.UTF_8).size)
        val bitmap = ListeningPositionQRCode.image(boundary)
        val data = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        bitmap.recycle()
        val decoded = ListeningPositionQRCode.decode(data).single()
        assertEquals(boundary, decoded)
        assertEquals(payload, ListeningPositionPayload.decode(decoded))
        savePositionEvidence("enve-rich-reading-position.png", data)
    }

}
