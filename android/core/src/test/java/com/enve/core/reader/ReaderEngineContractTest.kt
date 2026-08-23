package com.enve.core.reader

import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class ReaderEngineContractTest {
    @Test
    fun ordinaryReflowableCfiBackedEpubsUseFoliate() {
        assertEquals(
            ReaderEngineKind.FOLIATE,
            ReaderEnginePolicy.select(request(BookSource.GRIMMORY)),
        )
        assertEquals(
            ReaderEngineKind.FOLIATE,
            ReaderEnginePolicy.select(request(BookSource.SILO, format = "epub")),
        )
        assertEquals(
            ReaderEngineKind.FOLIATE,
            ReaderEnginePolicy.select(request(BookSource.BOOKORBIT)),
        )
    }

    @Test
    fun StorytellerAndOtherProvidersStayOnReadium() {
        assertEquals(
            ReaderEngineKind.READIUM,
            ReaderEnginePolicy.select(request(BookSource.STORYTELLER)),
        )
        assertEquals(
            ReaderEngineKind.READIUM,
            ReaderEnginePolicy.select(request(BookSource.AUDIOBOOKSHELF)),
        )
    }

    @Test
    fun readAlongFixedLayoutAndNonEpubBooksStayOnReadium() {
        assertEquals(
            ReaderEngineKind.READIUM,
            ReaderEnginePolicy.select(request(BookSource.GRIMMORY, readAlong = true)),
        )
        assertEquals(
            ReaderEngineKind.READIUM,
            ReaderEnginePolicy.select(request(BookSource.SILO, isReflowable = false)),
        )
        assertEquals(
            ReaderEngineKind.READIUM,
            ReaderEnginePolicy.select(request(BookSource.GRIMMORY, format = "PDF")),
        )
    }

    @Test
    fun overridesApplyOnlyToOrdinaryReflowableEpubs() {
        assertEquals(
            ReaderEngineKind.READIUM,
            ReaderEnginePolicy.select(
                request(
                    source = BookSource.GRIMMORY,
                    override = ReaderEngineKind.READIUM,
                ),
            ),
        )
        assertEquals(
            ReaderEngineKind.FOLIATE,
            ReaderEnginePolicy.select(
                request(
                    source = BookSource.LOCAL,
                    override = ReaderEngineKind.FOLIATE,
                ),
            ),
        )
        assertEquals(
            ReaderEngineKind.READIUM,
            ReaderEnginePolicy.select(
                request(
                    source = BookSource.GRIMMORY,
                    format = "PDF",
                    override = ReaderEngineKind.FOLIATE,
                ),
            ),
        )
    }

    @Test
    fun ReadiumLocatorRoundTripPreservesPortableAnchors() {
        val locatorJson = """
            {
              "href": "OEBPS/chapter-02.xhtml",
              "type": "application/xhtml+xml",
              "locations": {
                "fragments": ["epubcfi(/6/8!/4/2/6:12)"],
                "cssSelector": "#paragraph-7",
                "domRange": {
                  "start": {
                    "cssSelector": "#paragraph-7",
                    "textNodeIndex": 0,
                    "charOffset": 4
                  },
                  "end": {
                    "cssSelector": "#paragraph-7",
                    "textNodeIndex": 0,
                    "charOffset": 21
                  }
                },
                "progression": 0.42,
                "totalProgression": 0.27
              },
              "text": {
                "before": "  The sea was quiet.  ",
                "highlight": " waves\nrose   quickly ",
                "after": "  Beyond the reef.  "
              }
            }
        """.trimIndent()

        val checkpoint = requireNotNull(
            EpubBridgeCheckpointCodec.fromReadiumLocator(
                locatorJson = locatorJson,
                publicationSha256 = "abc123",
                providerFileId = "17",
                writerEpoch = 8,
                revision = 5,
                observedAt = 1_234,
            ),
        )

        assertEquals("OEBPS/chapter-02.xhtml", checkpoint.href)
        assertNull(checkpoint.epubCfi)
        assertEquals("#paragraph-7", checkpoint.cssSelector)
        assertEquals(4, checkpoint.domRange?.start?.charOffset)
        assertEquals(21, checkpoint.domRange?.end?.charOffset)
        assertEquals(0.42, checkpoint.resourceProgression ?: Double.NaN, 0.000_001)
        assertEquals(0.27, checkpoint.totalProgression ?: Double.NaN, 0.000_001)
        assertEquals(
            ReaderTextQuote(
                exact = "waves rose quickly",
                prefix = "The sea was quiet.",
                suffix = "Beyond the reef.",
            ),
            checkpoint.textQuote,
        )
        assertTrue(checkpoint.hasPreciseAnchor)

        val roundTripped = requireNotNull(
            EpubBridgeCheckpointCodec.fromReadiumLocator(
                locatorJson = requireNotNull(EpubBridgeCheckpointCodec.toReadiumLocatorJson(checkpoint)),
                publicationSha256 = checkpoint.publicationSha256,
                providerFileId = checkpoint.providerFileId,
                writerEpoch = checkpoint.writerEpoch,
                revision = checkpoint.revision,
                observedAt = checkpoint.observedAt,
            ),
        )

        assertEquals(checkpoint.href, roundTripped.href)
        assertNull(roundTripped.epubCfi)
        assertEquals(checkpoint.cssSelector, roundTripped.cssSelector)
        assertEquals(checkpoint.domRange, roundTripped.domRange)
        assertEquals(checkpoint.resourceProgression, roundTripped.resourceProgression)
        assertEquals(checkpoint.totalProgression, roundTripped.totalProgression)
        assertEquals(checkpoint.textQuote, roundTripped.textQuote)
    }

    @Test
    fun publicationIdentityChangeInvalidatesPublicationSpecificAnchors() {
        val checkpoint = EpubBridgeCheckpoint(
            publicationSha256 = "old-sha",
            providerFileId = "4",
            revision = 3,
            writerEpoch = 9,
            observedAt = 456,
            sourceEngine = ReaderEngineKind.FOLIATE,
            href = "EPUB/chapter.xhtml",
            epubCfi = "epubcfi(/6/4!/4/2:8)",
            cssSelector = "#sentence",
            domRange = ReaderDomRange(
                start = ReaderDomPoint("#sentence", textNodeIndex = 0, charOffset = 2),
            ),
            resourceProgression = 0.3,
            totalProgression = 0.4,
            textQuote = ReaderTextQuote("selected words", "before", "after"),
            nativeReadiumLocatorJson = """{"href":"EPUB/chapter.xhtml"}""",
        )

        val rebound = checkpoint.forPublication(sha256 = "new-sha", fileId = "8")

        assertEquals("new-sha", rebound.publicationSha256)
        assertEquals("8", rebound.providerFileId)
        assertNull(rebound.href)
        assertNull(rebound.epubCfi)
        assertNull(rebound.cssSelector)
        assertNull(rebound.domRange)
        assertNull(rebound.resourceProgression)
        assertNull(rebound.textQuote)
        assertNull(rebound.nativeReadiumLocatorJson)
        assertFalse(rebound.hasPreciseAnchor)

        val oldIdentity = ReaderCheckpointIdentity.key(
            source = BookSource.SILO,
            connectionId = "connection",
            bookId = "book",
            providerFileId = checkpoint.providerFileId,
            publicationSha256 = checkpoint.publicationSha256,
        )
        val newIdentity = ReaderCheckpointIdentity.key(
            source = BookSource.SILO,
            connectionId = "connection",
            bookId = "book",
            providerFileId = rebound.providerFileId,
            publicationSha256 = rebound.publicationSha256,
        )

        assertNotEquals(oldIdentity, newIdentity)
    }

    @Test
    fun noCanonicalCfiIsInjectedIntoReadiumFragments() {
        val checkpoint = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            providerFileId = "12",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.FOLIATE,
            href = "EPUB/chapter.xhtml",
            epubCfi = "epubcfi(/6/4!/4/2:8)",
            cssSelector = "#sentence",
            domRange = ReaderDomRange(
                start = ReaderDomPoint("#sentence", textNodeIndex = 0, charOffset = 2),
            ),
            textQuote = ReaderTextQuote("selected words", "before", "after"),
        )

        val locator = Json.parseToJsonElement(
            requireNotNull(EpubBridgeCheckpointCodec.toReadiumLocatorJson(checkpoint)),
        ).jsonObject
        val locations = requireNotNull(locator["locations"]).jsonObject

        assertFalse("fragments" in locations)
        assertFalse("cfi" in locations)
        assertEquals("#sentence", locations.getValue("cssSelector").jsonPrimitive.content)
        assertTrue("domRange" in locations)
        assertEquals(
            "selected words",
            locator.getValue("text").jsonObject.getValue("highlight").jsonPrimitive.content,
        )

        val readiumCheckpoint = checkpoint.copy(sourceEngine = ReaderEngineKind.READIUM)
        val readiumLocations = Json.parseToJsonElement(
            requireNotNull(EpubBridgeCheckpointCodec.toReadiumLocatorJson(readiumCheckpoint)),
        ).jsonObject.getValue("locations").jsonObject
        assertFalse("fragments" in readiumLocations)
        assertFalse("cfi" in readiumLocations)
    }

    @Test
    fun fullCfiValidationRequiresPackageAndContentPaths() {
        assertTrue(
            EpubBridgeCheckpointCodec.isFullEpubCfi(
                "epubcfi(/6/8!/4/2:10)",
            ),
        )
        assertTrue(
            EpubBridgeCheckpointCodec.isFullEpubCfi(
                "epubcfi(/6/8!/4/2,/1:0,/1:12)",
            ),
        )
        assertTrue(
            EpubBridgeCheckpointCodec.isFullEpubCfi(
                "epubcfi(/6/2!/2/2,,/6/1:44)",
            ),
        )
        assertFalse(EpubBridgeCheckpointCodec.isFullEpubCfi("epubcfi(/6/8)"))
        assertFalse(EpubBridgeCheckpointCodec.isFullEpubCfi("epubcfi(!/4/2)"))
        assertFalse(EpubBridgeCheckpointCodec.isFullEpubCfi("epubcfi(/6/8!)"))
        assertFalse(EpubBridgeCheckpointCodec.isFullEpubCfi("epubcfi(/6/8!/4/2,,)"))
        assertNull(EpubBridgeCheckpointCodec.foliateCfi("epubcfi(/6/8!/4/2:10)"))

        val foliateCheckpoint = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.FOLIATE,
            epubCfi = "epubcfi(/6/8!/4/2:10)",
        )
        assertTrue(foliateCheckpoint.hasPreciseAnchor)
        assertTrue(
            foliateCheckpoint.copy(
                epubCfi = "epubcfi(/6/2!/2/2,,/6/1:44)",
            ).hasPreciseAnchor,
        )
        assertFalse(
            foliateCheckpoint.copy(
                sourceEngine = ReaderEngineKind.READIUM,
            ).hasPreciseAnchor,
        )
        assertFalse(
            foliateCheckpoint.copy(
                epubCfi = "epubcfi(/6/8)",
            ).hasPreciseAnchor,
        )
    }

    @Test
    fun visibleSentenceAnchorIsMergedIntoReadiumCheckpoint() {
        val rawLocator = """
            {
              "href": "EPUB/chapter.xhtml",
              "type": "application/xhtml+xml",
              "locations": {
                "fragments": ["epubcfi(/6/4!/4/2:8)"],
                "progression": 0.31,
                "totalProgression": 0.42
              }
            }
        """.trimIndent()
        val anchorJson = """
            {
              "cssSelector": "#paragraph-12",
              "domRange": {
                "start": {
                  "cssSelector": "#paragraph-12",
                  "textNodeIndex": 0,
                  "charOffset": 18
                },
                "end": {
                  "cssSelector": "#paragraph-12",
                  "textNodeIndex": 0,
                  "charOffset": 74
                }
              },
              "textQuote": {
                "exact": "The water folded over itself beneath the moon.",
                "prefix": "Behind them,",
                "suffix": "No one spoke."
              }
            }
        """.trimIndent()
        val anchor = requireNotNull(EpubBridgeCheckpointCodec.decodeVisibleAnchor(anchorJson))
        val enriched = requireNotNull(
            EpubBridgeCheckpointCodec.withVisibleAnchor(rawLocator, anchor),
        )
        val checkpoint = requireNotNull(
            EpubBridgeCheckpointCodec.fromReadiumLocator(
                locatorJson = enriched,
                publicationSha256 = "sha",
                providerFileId = "7",
                writerEpoch = 3,
                revision = 4,
                observedAt = 500,
            ),
        )

        assertEquals("#paragraph-12", checkpoint.cssSelector)
        assertEquals(18, checkpoint.domRange?.start?.charOffset)
        assertEquals(
            "The water folded over itself beneath the moon.",
            checkpoint.textQuote?.exact,
        )
        assertTrue(checkpoint.hasPortableAnchor)
        assertNull(checkpoint.epubCfi)
        val mergedLocations = Json.parseToJsonElement(enriched)
            .jsonObject.getValue("locations").jsonObject
        assertFalse("fragments" in mergedLocations)
        assertFalse("cfi" in mergedLocations)
    }

    @Test
    fun restoreConfirmationRequiresSamePortableAnchorAndNearbyProgress() {
        val expected = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.FOLIATE,
            href = "EPUB/chapter.xhtml",
            cssSelector = "#paragraph-12",
            domRange = ReaderDomRange(
                start = ReaderDomPoint("#paragraph-12", 0, 18),
                end = ReaderDomPoint("#paragraph-12", 0, 74),
            ),
            totalProgression = 0.42,
            textQuote = ReaderTextQuote(
                exact = "The water folded over itself beneath the moon.",
                prefix = "Behind them,",
                suffix = "No one spoke.",
            ),
        )

        assertTrue(
            EpubBridgeRestoreMatcher.matches(
                expected,
                expected.copy(
                    sourceEngine = ReaderEngineKind.READIUM,
                    totalProgression = 0.425,
                ),
            ),
        )
        assertTrue(
            EpubBridgeRestoreMatcher.matches(
                expected.copy(
                    textQuote = ReaderTextQuote(
                        exact = "The cafe\u0301 folded over itself beneath the moon.",
                    ),
                ),
                expected.copy(
                    sourceEngine = ReaderEngineKind.READIUM,
                    totalProgression = 0.425,
                    textQuote = ReaderTextQuote(
                        exact = "The   café folded over itself beneath the moon.",
                    ),
                ),
            ),
        )
        assertFalse(
            EpubBridgeRestoreMatcher.matches(
                expected,
                expected.copy(
                    sourceEngine = ReaderEngineKind.READIUM,
                    textQuote = ReaderTextQuote("A different sentence on the same page."),
                ),
            ),
        )
        assertFalse(
            EpubBridgeRestoreMatcher.matches(
                expected,
                expected.copy(
                    sourceEngine = ReaderEngineKind.READIUM,
                    totalProgression = 0.50,
                ),
            ),
        )
    }

    @Test
    fun progressionOnlyRestoreAcceptsResolvedChapterHref() {
        val expected = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.READIUM,
            totalProgression = 0.10,
        )
        val actual = expected.copy(
            sourceEngine = ReaderEngineKind.FOLIATE,
            href = "EPUB/chapter-04.xhtml",
            totalProgression = 0.102,
        )

        assertTrue(EpubBridgeRestoreMatcher.matches(expected, actual))
    }

    @Test
    fun portableAnchorConfirmsRestoreWhenRendererCannotReportProgress() {
        val expected = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.READIUM,
            href = "EPUB/chapter-04.xhtml",
            totalProgression = 0.10,
            textQuote = ReaderTextQuote("The same sentence appears at the restored location."),
        )
        val actual = expected.copy(
            sourceEngine = ReaderEngineKind.FOLIATE,
            totalProgression = null,
        )

        assertTrue(EpubBridgeRestoreMatcher.matches(expected, actual))
        assertFalse(
            EpubBridgeRestoreMatcher.matches(
                expected,
                actual.copy(textQuote = ReaderTextQuote("A different sentence.")),
            ),
        )
    }

    @Test
    fun portableRestoreMethodMustExistOnExpectedCheckpoint() {
        val checkpoint = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.READIUM,
            href = "EPUB/chapter-04.xhtml",
            cssSelector = "#paragraph-12",
            textQuote = ReaderTextQuote("The restored sentence."),
        )

        assertTrue(EpubBridgeRestoreMatcher.restoredWithPortableAnchor(checkpoint, "textQuote"))
        assertTrue(EpubBridgeRestoreMatcher.restoredWithPortableAnchor(checkpoint, "cssSelector"))
        assertFalse(EpubBridgeRestoreMatcher.restoredWithPortableAnchor(checkpoint, "domRange"))
        assertFalse(EpubBridgeRestoreMatcher.restoredWithPortableAnchor(checkpoint, "progression"))
    }

    @Test
    fun exactCfiRestoreRequiresFoliateProvenanceAndFullPackageCfi() {
        val foliate = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.FOLIATE,
            epubCfi = "epubcfi(/6/20[chapter]!/4/2/8:12)",
        )

        assertTrue(EpubBridgeRestoreMatcher.restoredWithFoliateCfi(foliate, "cfi"))
        assertFalse(
            EpubBridgeRestoreMatcher.restoredWithFoliateCfi(
                foliate.copy(sourceEngine = ReaderEngineKind.READIUM),
                "cfi",
            ),
        )
        assertFalse(
            EpubBridgeRestoreMatcher.restoredWithFoliateCfi(
                foliate.copy(epubCfi = "epubcfi(/4/2/8:12)"),
                "cfi",
            ),
        )
        assertFalse(EpubBridgeRestoreMatcher.restoredWithFoliateCfi(foliate, "progression"))
    }

    @Test
    fun progressionOnlyCheckpointCanBootstrapToExactFoliateCfi() {
        val progressionOnly = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.FOLIATE,
            totalProgression = 0.051,
        )
        val foliateCapture = progressionOnly.copy(
            epubCfi = "epubcfi(/6/20!/4/2,,/6/1:44)",
            href = "OEBPS/chapter.xhtml",
            totalProgression = 0.058,
        )

        assertTrue(
            EpubBridgeRestoreMatcher.canBootstrapFoliateCfi(
                progressionOnly,
                foliateCapture,
                "progression",
            ),
        )
        assertFalse(
            EpubBridgeRestoreMatcher.canBootstrapFoliateCfi(
                progressionOnly.copy(href = "OEBPS/chapter.xhtml"),
                foliateCapture,
                "progression",
            ),
        )
        assertFalse(
            EpubBridgeRestoreMatcher.canBootstrapFoliateCfi(
                progressionOnly,
                foliateCapture.copy(sourceEngine = ReaderEngineKind.READIUM),
                "progression",
            ),
        )
    }

    @Test
    fun semanticReadiumRestoreCaptureRequiresSameChapterAndFreshAnchor() {
        val expected = EpubBridgeCheckpoint(
            publicationSha256 = "sha",
            observedAt = 100,
            sourceEngine = ReaderEngineKind.FOLIATE,
            href = "OEBPS/chapter.xhtml",
            textQuote = ReaderTextQuote("The sentence used to restore."),
        )
        val capture = expected.copy(
            sourceEngine = ReaderEngineKind.READIUM,
            textQuote = ReaderTextQuote("A centered sentence on the restored page."),
        )

        assertTrue(EpubBridgeRestoreMatcher.matchesPortableRestoreCapture(expected, capture))
        assertFalse(
            EpubBridgeRestoreMatcher.matchesPortableRestoreCapture(
                expected,
                capture.copy(href = "OEBPS/other.xhtml"),
            ),
        )
        assertFalse(
            EpubBridgeRestoreMatcher.matchesPortableRestoreCapture(
                expected,
                capture.copy(textQuote = null),
            ),
        )
    }

    private fun request(
        source: BookSource,
        format: String = "EPUB",
        readAlong: Boolean = false,
        isReflowable: Boolean = true,
        override: ReaderEngineKind? = null,
    ) = ReaderEngineRequest(
        source = source,
        format = format,
        readAlong = readAlong,
        isReflowable = isReflowable,
        override = override,
    )
}
