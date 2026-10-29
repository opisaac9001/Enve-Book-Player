package com.enve.core.listeningposition

import org.junit.Assert.*
import org.junit.Test
import kotlin.random.Random

class ListeningPositionPayloadTest {
    private val fixtures = listOf(
        """{"a":["Brandon Sanderson"],"asin":"B003ZWFO7E","dur":163980000,"k":"enve.position","n":["Michael Kramer","Kate Reading"],"pos":3723500,"q":"1","s":"The Stormlight Archive","t":"The Way of Kings","v":1}""",
        """{"dur":3600000,"k":"enve.position","pos":0,"t":"Untitled Recording","v":1}""",
        """{"a":["Antoine de Saint-Exupéry"],"dur":5400000,"isbn":"9782070612758","k":"enve.position","pos":1,"t":"Le \"Petit\" Prince \\ Édition","v":1}""",
    )

    @Test fun iosFixturesRoundTripByteForByte() {
        fixtures.forEach { assertEquals(it, ListeningPositionPayload.decode(it).encoded()) }
    }

    @Test fun rejectsUntrustedMalformedFields() {
        val base = fixtures[1]
        listOf(
            base.replace("\"v\":1", "\"v\":true"),
            base.replace("\"v\":1", "\"v\":2"),
            base.replace("\"pos\":0", "\"pos\":-1"),
            base.replace("\"pos\":0", "\"pos\":3600001"),
            base.replace("\"pos\":0", "\"pos\":1.5"),
            base.replace("\"pos\":0", "\"pos\":1e400"),
            base.replace("\"dur\":3600000", "\"dur\":0"),
            base.replace("Untitled Recording", "A\\nB"),
            base.replace("Untitled Recording", "A  B"),
            base.replace("Untitled Recording", "\\uD800"),
            base.replace("Untitled Recording", "A\u202eB"),
            base + " ".repeat(ListeningPositionPayload.MAX_ENCODED_BYTES), "https://evil.example/run", "[]",
        ).forEach { input -> assertThrows(input, ListeningPositionPayloadException::class.java) { ListeningPositionPayload.decode(input) } }
    }

    @Test fun ignoresUnknownFieldsWithoutResolvingThem() {
        val input = fixtures[1].dropLast(1) + ",\"url\":\"https://evil.example\",\"token\":\"fake\"}"
        assertEquals(fixtures[1], ListeningPositionPayload.decode(input).encoded())
    }

    @Test fun randomizedMalformedInputIsRejected() {
        val random = Random(42)
        repeat(2000) {
            val text = String(random.nextBytes(128), Charsets.UTF_8)
            assertThrows(ListeningPositionPayloadException::class.java) { ListeningPositionPayload.decode(text) }
        }
        listOf(8, 64, 256, 500).forEach { depth ->
            assertThrows(ListeningPositionPayloadException::class.java) { ListeningPositionPayload.decode("[".repeat(depth) + "0" + "]".repeat(depth)) }
        }
    }
    @Test fun readingFixturesRoundTripByteForByte() {
        listOf(
            """{"f":"epub","k":"enve.position","m":"reading","p":250000,"t":"A Book","v":2}""",
            """{"f":"epub","h":"OPS/chapter%201.xhtml","k":"enve.position","m":"reading","o":500000,"p":250000,"t":"A Book","v":2}""",
            """{"f":"comic","k":"enve.position","m":"reading","p":250000,"page":5,"pages":20,"t":"A Book","v":2}""",
            """{"f":"pdf","k":"enve.position","m":"reading","p":0,"page":1,"t":"A Book","v":2}""",
        ).forEach { assertEquals(it, ListeningPositionPayload.decode(it).encoded()) }
    }

    @Test fun malformedOrMixedReadingLocationsAreRejected() {
        val base = """{"f":"epub","k":"enve.position","m":"reading","p":250000,"t":"A Book","v":2}"""
        listOf(
            base.replace("\"p\":250000", "\"p\":-1"),
            base.replace("\"p\":250000", "\"p\":1000001"),
            base.replace("\"p\":250000", "\"p\":true"),
            base.replace("\"p\":250000", "\"p\":1.25"),
            base.replace("\"m\":\"reading\"", "\"m\":\"audio\""),
            base.replace("\"f\":\"epub\"", "\"f\":\"EPUB\""),
            base.dropLast(1) + ",\"pos\":0,\"dur\":1}",
            base.dropLast(1) + ",\"page\":5,\"pages\":4}",
            base.dropLast(1) + ",\"page\":10}",
            base.replace("\"epub\"", "\"pdf\"").dropLast(1) + ",\"h\":\"chapter.xhtml\",\"o\":500000}",
            base.dropLast(1) + ",\"pages\":5}",
            base.dropLast(1) + ",\"h\":\"chapter.xhtml\"}",
            base.dropLast(1) + ",\"o\":10}",
        ).forEach { input -> assertThrows(input, ListeningPositionPayloadException::class.java) { ListeningPositionPayload.decode(input) } }
        listOf("https://host.example/book", "/chapter.xhtml", "../chapter.xhtml", "%2e%2e/chapter.xhtml", "chapter.xhtml?token=test", "chapter.xhtml#private", "chapter%00.xhtml", "%FF.xhtml", "%C3.xhtml", "A\u2028B", "e\u0301.xhtml").forEach { href ->
            assertFalse(href, SharedReadingLocation.validHref(href))
        }
        assertTrue(SharedReadingLocation.validHref("OPS/Chapter 1.xhtml"))
        assertTrue(SharedReadingLocation.validHref("%C3%A9.xhtml"))
        assertTrue(SharedReadingLocation.validHref("chapter+one.xhtml"))
    }

    @Test fun sourceReadingLocationsUseNativePageAndResourceMetadata() {
        val book = com.enve.core.data.model.Book("reading", "A Book", mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
            primaryFileType = "PDF", pageCount = 20, epubProgress = 0.25f, epubLocator = """{"page":5}""")
        val reading = ListeningPositionPayload.from(book)!!.readingLocation!!
        assertEquals(SharedReadingLocation("pdf", 250000, page = 5, pageCount = 20), reading)
        val withoutCount = ListeningPositionPayload.from(book.copy(pageCount = null))!!.readingLocation!!
        assertEquals(5, withoutCount.page)
        assertNull(withoutCount.pageCount)
        val comic = ListeningPositionPayload.from(book.copy(primaryFileType = "CBR", epubLocator = "cbr-page:5"))!!.readingLocation!!
        assertEquals("comic", comic.format)
        assertEquals(5, comic.page)
        val epub = ListeningPositionPayload.from(book.copy(primaryFileType = "EPUB", epubLocator = """{"href":"OPS/chapter.xhtml","locations":{"progression":0.5}}"""))!!.readingLocation!!
        assertEquals("OPS/chapter.xhtml", epub.href)
        assertEquals(500000L, epub.resourceProgressionUnits)
        assertNull(epub.page)
        assertEquals(0L, ListeningPositionPayload.from(book.copy(epubProgress = 0f, epubLocator = null))!!.readingLocation!!.progressionUnits)
        assertEquals(1000000L, ListeningPositionPayload.from(book.copy(epubProgress = 1f))!!.readingLocation!!.progressionUnits)
    }

    @Test fun podcastPositionsUseTheAudioContract() {
        val podcast = com.enve.core.data.model.Book("episode", "An Episode", mediaType = com.enve.core.data.model.AppMediaType.PODCAST,
            duration = 60, currentTime = 15, episodeId = "episode", podcastName = "A Podcast")
        val payload = ListeningPositionPayload.from(podcast)!!
        assertNull(payload.readingLocation)
        assertEquals(15000L, payload.positionMilliseconds)
        assertTrue(payload.encoded().endsWith("\"v\":1}"))
    }

    @Test fun richLocatorFixtureRoundTripsAndPreservesEveryAnchor() {
        val fixture = """{"c":"epubcfi(/6/4!/4/2/1:7)","f":"epub","h":"OPS/chapter.xhtml","k":"enve.position","l":"{\"href\":\"OPS/chapter.xhtml\",\"locations\":{\"cssSelector\":\"#p3\",\"domRange\":{\"start\":{\"charOffset\":7,\"cssSelector\":\"#p3\",\"textNodeIndex\":0}},\"fragments\":[\"p3\"],\"position\":12,\"progression\":0.5,\"totalProgression\":0.25},\"text\":{\"after\":\" after\",\"before\":\"before \",\"highlight\":\"A passage\"},\"type\":\"application/xhtml+xml\"}","m":"reading","o":500000,"p":250000,"t":"A Book","v":2}"""
        val payload = ListeningPositionPayload.decode(fixture)
        assertEquals(fixture, payload.encoded())
        val location = payload.readingLocation!!
        assertEquals("epubcfi(/6/4!/4/2/1:7)", location.epubCfi)
        val target = com.enve.core.data.model.Book("copy", "A Book", mediaType = com.enve.core.data.model.AppMediaType.EBOOK, primaryFileType = "EPUB")
        val restored = kotlinx.serialization.json.Json.parseToJsonElement(location.locatorFor(target)!!).toString()
        assertTrue(restored.contains("domRange"))
        assertTrue(restored.contains("A passage"))
        assertTrue(restored.contains("epubcfi(/6/4!/4/2/1:7)"))
        val checkpoint = com.enve.core.reader.EpubBridgeCheckpointCodec.fromReadiumLocator(restored, "local-copy", null, 1, 0, 0)!!
        assertEquals(location.epubCfi, checkpoint.epubCfi)
        assertEquals("#p3", checkpoint.cssSelector)
        assertEquals("A passage", checkpoint.textQuote!!.exact)
        val other = location.locatorFor(target.copy(primaryFileType = "TXT"))!!
        assertFalse(other.contains("href"))
        assertFalse(other.contains("cfi"))
        assertFalse(other.contains("A passage"))
        assertTrue(other.contains("0.25"))
    }

    @Test fun checkpointSharingRemovesPrivateIdentityButKeepsPrecisePositions() {
        val checkpoint = com.enve.core.reader.EpubBridgeCheckpoint(
            publicationSha256 = "private-hash", providerFileId = "private-file", revision = 8, writerEpoch = 4,
            observedAt = 1234, sourceEngine = com.enve.core.reader.ReaderEngineKind.FOLIATE,
            href = "OPS/chapter.xhtml", epubCfi = "epubcfi(/6/4!/4/2/1:7)", cssSelector = "#p3",
            domRange = com.enve.core.reader.ReaderDomRange(com.enve.core.reader.ReaderDomPoint("#p3", 0, 7)),
            resourceProgression = 0.5, totalProgression = 0.25,
            textQuote = com.enve.core.reader.ReaderTextQuote("A passage", "before ", " after"),
            nativeReadiumLocatorJson = """{"href":"OPS/chapter.xhtml","locations":{"fragments":["p3"],"position":12},"server":"https://private.example","token":"private-token"}""",
        )
        val book = com.enve.core.data.model.Book("reading", "A Book", mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
            primaryFileType = "EPUB", epubProgress = 0.25f, epubLocator = com.enve.core.reader.EpubBridgeCheckpointCodec.encode(checkpoint))
        val payload = ListeningPositionPayload.from(book)!!
        val reading = payload.readingLocation!!
        assertEquals(checkpoint.epubCfi, reading.epubCfi)
        assertEquals(250000L, reading.progressionUnits)
        assertEquals(500000L, reading.resourceProgressionUnits)
        assertTrue(reading.readiumLocatorJson!!.contains("domRange"))
        assertTrue(reading.readiumLocatorJson.contains("p3"))
        assertTrue(reading.readiumLocatorJson.contains("A passage"))
        assertFalse(payload.encoded().contains("private"))
        assertFalse(payload.encoded().contains("revision"))
        assertEquals(payload, ListeningPositionPayload.decode(payload.encoded()))
        val cfiOnly = ListeningPositionPayload.from(book.copy(epubLocator = checkpoint.epubCfi))!!.readingLocation!!
        assertEquals(checkpoint.epubCfi, cfiOnly.epubCfi)
        assertNull(cfiOnly.readiumLocatorJson)
        val nativeOnly = checkpoint.copy(epubCfi = null,
            nativeReadiumLocatorJson = """{"href":"OPS/chapter.xhtml","locations":{"cfi":"${checkpoint.epubCfi}","partialCfi":"/4/2/1:7"}}""")
        val fromNative = ListeningPositionPayload.from(book.copy(epubLocator = com.enve.core.reader.EpubBridgeCheckpointCodec.encode(nativeOnly)))!!.readingLocation!!
        assertEquals(checkpoint.epubCfi, fromNative.epubCfi)
        assertTrue(fromNative.readiumLocatorJson!!.contains("partialCfi"))
    }

    @Test fun cfiAssertionsSurviveSharingAndReceiving() {
        val book = com.enve.core.data.model.Book("reading", "A Book", mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
            primaryFileType = "EPUB", epubProgress = 0.25f)
        for (cfi in listOf(
            "epubcfi(/6/4[chapter^,one]!/4/2[part/one]/1:7)",
            "epubcfi(/6/4[chapter!one]!/4/2/1:7[before,after])",
            "epubcfi(/6/4!/4/2,/1:7[before/word,after],/1:12[one,two!three])",
        )) {
            val sent = ListeningPositionPayload.from(book.copy(epubLocator = cfi))!!
            val received = ListeningPositionPayload.decode(sent.encoded())
            assertEquals(cfi, received.readingLocation!!.epubCfi)
            val locator = received.readingLocation.locatorFor(book)!!
            val checkpoint = com.enve.core.reader.EpubBridgeCheckpointCodec.fromReadiumLocator(locator, "local", null, 1, 0, 0)!!
            assertEquals(cfi, checkpoint.epubCfi)
            assertTrue(checkpoint.hasPreciseAnchor)
        }
    }

    @Test fun invalidRichLocatorsAreRejectedAndUnknownFieldsAreRemoved() {
        val base = """{"f":"epub","k":"enve.position","m":"reading","p":250000,"t":"A Book","v":2}"""
        fun withLocator(locator: String) = base.dropLast(1) + ",\"l\":" + kotlinx.serialization.json.JsonPrimitive(locator) + "}"
        val native = """{"href":"OPS/chapter.xhtml","locations":{"progression":0.5},"type":"application/xhtml+xml"}"""
        for (bad in listOf(
            native.replace("OPS/chapter.xhtml", "https://private.example/book"),
            native.replace("OPS/chapter.xhtml", "../book.xhtml"),
            native.replace("0.5", "true"), native.replace("0.5", "1.1"),
            native.replace("0.5", "1e400"), native.replace("0.5", "\"0.5\""),
            native.replace("application/xhtml+xml", "text/javascript"),
            native.replace("\"progression\":0.5", "\"domRange\":{}"),
            native.replace("\"progression\":0.5", "\"cfi\":\"javascript:alert(1)\""),
        )) assertThrows(ListeningPositionPayloadException::class.java) { ListeningPositionPayload.decode(withLocator(bad)) }
        val extras = native.dropLast(1) + ",\"server\":\"https://private.example\",\"token\":\"private\"}"
        val clean = ListeningPositionPayload.decode(withLocator(extras)).encoded()
        assertFalse(clean.contains("private"))
        assertThrows(ListeningPositionPayloadException::class.java) {
            ListeningPositionPayload.decode(base.dropLast(1) + ",\"c\":\"epubcfi(/4/2)\"}")
        }
    }

    @Test fun locatorFractionsRetainSubMillionthPrecision() {
        val native = """{"href":"OPS/chapter.xhtml","locations":{"progression":1e-7,"totalProgression":0.25},"type":"application/xhtml+xml"}"""
        val normalized = SharedReadiumLocator.sanitize(native)
        assertTrue(normalized.contains("\"progression\":0.0000001"))
        val payload = ListeningPositionPayload(0, 0, "A Book", readingLocation = SharedReadingLocation(
            "epub", 250000, href = "OPS/chapter.xhtml", resourceProgressionUnits = 0, readiumLocatorJson = normalized,
        ))
        assertEquals(payload, ListeningPositionPayload.decode(payload.encoded()))
        val book = com.enve.core.data.model.Book("reading", "A Book", mediaType = com.enve.core.data.model.AppMediaType.EBOOK, primaryFileType = "EPUB")
        val restored = payload.readingLocation!!.locatorFor(book)!!
        val checkpoint = com.enve.core.reader.EpubBridgeCheckpointCodec.fromReadiumLocator(restored, "local", null, 1, 0, 0)!!
        assertEquals(0.0000001, checkpoint.resourceProgression!!, 0.0)
        assertThrows(IllegalArgumentException::class.java) {
            payload.readingLocation.copy(href = "different.xhtml")
        }
    }

    @Test fun sizeLimitNeverSilentlyDropsReadingAnchors() {
        val book = com.enve.core.data.model.Book("reading", "A Book", mediaType = com.enve.core.data.model.AppMediaType.EBOOK,
            primaryFileType = "EPUB", epubProgress = 0.25f,
            epubLocator = """{"href":"OPS/chapter.xhtml","locations":{"cssSelector":"#p3","progression":0.5},"text":{"highlight":"${"a".repeat(2000)}"}}""")
        assertNull(ListeningPositionPayload.from(book))
        val short = book.copy(epubLocator = book.epubLocator!!.replace("a".repeat(2000), "a".repeat(900)))
        val payload = ListeningPositionPayload.from(short)!!
        assertTrue(payload.encoded().toByteArray().size > 1024)
        assertNotNull(payload.readingLocation!!.readiumLocatorJson)
        assertNotNull(payload.readingLocation.href)
        assertEquals(payload, ListeningPositionPayload.decode(payload.encoded()))
    }

}
