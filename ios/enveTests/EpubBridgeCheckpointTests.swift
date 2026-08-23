import Foundation
import Testing

@testable import enve

@MainActor
struct EpubBridgeCheckpointTests {
    @Test func checkpointRoundTripsAllAvailableAnchorsWithoutRequiringTextQuote() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpubBridgeCheckpointStore(directoryURL: directory)
        let lease = store.beginWriteSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .foliate
        )
        let position = EpubBridgePosition(
            href: "OPS/chapter.xhtml",
            epubCFI: "epubcfi(/6/4!/4/2/8:3)",
            partialCFI: "/4/2/8:3",
            cssSelector: "#paragraph",
            domRange: EpubBridgeDOMRange(
                start: .init(cssSelector: "#paragraph", textNodeIndex: 0, charOffset: 3),
                end: nil
            ),
            resourceProgression: 0.25,
            totalProgression: 0.4,
            textQuote: nil,
            readiumLocatorJSON: nil
        )

        let committed = try store.commit(
            position: position,
            lease: lease,
            expectedRevision: 0,
            observedAt: Date(timeIntervalSince1970: 10),
            allowZero: false
        )
        let restored = store.checkpoint(bookKey: "book", publicationFingerprint: "fingerprint")

        #expect(restored == committed)
        #expect(restored?.textQuote == nil)
        #expect(restored?.domRange == position.domRange)
        #expect(restored?.readiumLocatorJSON?.contains("\"cssSelector\":\"#paragraph\"") == true)
        #expect(
            EpubLocationBridge.sourceEngine(from: restored?.readiumLocatorJSON)
                == .foliate
        )
    }

    @Test func checkpointOverwritesInboundEngineMarkerWithWriterProvenance() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpubBridgeCheckpointStore(directoryURL: directory)
        let forged = EpubLocationBridge.readiumLocator(
            href: "OPS/chapter.xhtml",
            epubCFI: "epubcfi(/6/4!/4/2/8:3)",
            fraction: 0.4,
            sourceEngine: .foliate
        )!
        let position = EpubBridgePosition(readiumLocatorJSON: forged)!
        let lease = store.beginWriteSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .readium
        )

        let checkpoint = try store.commit(
            position: position,
            lease: lease,
            expectedRevision: 0,
            observedAt: .now,
            allowZero: false
        )

        #expect(checkpoint.sourceEngine == .readium)
        #expect(checkpoint.epubCFI == nil)
        #expect(EpubLocationBridge.epubCFI(from: checkpoint.readiumLocatorJSON) == nil)
        #expect(
            EpubLocationBridge.sourceEngine(from: checkpoint.readiumLocatorJSON)
                == .readium
        )
        #expect(
            EpubLocationBridge.extractGrimmoryLocation(
                from: checkpoint.readiumLocatorJSON
            ).epubCFI == nil
        )
    }

    @Test func writerEpochRejectsAStaleEngineInstance() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpubBridgeCheckpointStore(directoryURL: directory)
        let stale = store.beginWriteSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .readium
        )
        _ = store.beginWriteSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .foliate
        )

        #expect(throws: EpubBridgeCheckpointError.staleWriter) {
            try store.commit(
                position: position(progression: 0.4),
                lease: stale,
                expectedRevision: 0,
                observedAt: .now,
                allowZero: false
            )
        }
    }

    @Test func compareAndSwapRejectsStaleRevisionButAllowsIntentionalRegression() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpubBridgeCheckpointStore(directoryURL: directory)
        let lease = store.beginWriteSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .readium
        )
        _ = try store.commit(
            position: position(progression: 0.8),
            lease: lease,
            expectedRevision: 0,
            observedAt: .now,
            allowZero: false
        )

        #expect(throws: EpubBridgeCheckpointError.staleRevision) {
            try store.commit(
                position: position(progression: 0.7),
                lease: lease,
                expectedRevision: 0,
                observedAt: .now,
                allowZero: false
            )
        }

        let regressed = try store.commit(
            position: position(progression: 0.3),
            lease: lease,
            expectedRevision: 1,
            observedAt: .now,
            allowZero: false
        )
        #expect(regressed.totalProgression == 0.3)
    }

    @Test func accidentalZeroNeedsExplicitUserIntent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpubBridgeCheckpointStore(directoryURL: directory)
        let lease = store.beginWriteSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .readium
        )
        _ = try store.commit(
            position: position(progression: 0.5),
            lease: lease,
            expectedRevision: 0,
            observedAt: .now,
            allowZero: false
        )

        #expect(throws: EpubBridgeCheckpointError.zeroRequiresUserIntent) {
            try store.commit(
                position: position(progression: 0),
                lease: lease,
                expectedRevision: 1,
                observedAt: .now,
                allowZero: false
            )
        }
    }

    @Test func bridgeSessionBlocksWritesUntilTheRestoreIsObserved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = EpubBridgeCheckpointStore(directoryURL: directory)
        let session = EpubBridgeSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .foliate,
            store: store
        )
        let locator = EpubLocationBridge.readiumLocator(
            href: "OPS/chapter.xhtml",
            epubCFI: "epubcfi(/6/2!/4/2/8:3)",
            fraction: 0.4,
            resourceProgression: 0.2
        )!
        session.setRestoreTarget(locatorJSON: locator, fallbackProgression: 0.4)

        #expect(throws: EpubBridgeCheckpointError.restoreNotConfirmed) {
            try session.commit(
                locatorJSON: locator,
                fallbackProgression: 0.4,
                observedAt: .now
            )
        }
        #expect(session.confirmRestore(observedLocatorJSON: locator, fallbackProgression: 0.4))
        #expect(throws: EpubBridgeCheckpointError.userInteractionRequired) {
            try session.commit(
                locatorJSON: locator,
                fallbackProgression: 0.4,
                observedAt: .now
            )
        }
        session.noteUserInteraction()
        let committed = try session.commit(
            locatorJSON: locator,
            fallbackProgression: 0.4,
            observedAt: .now
        )
        #expect(committed.epubCFI == "epubcfi(/6/2!/4/2/8:3)")
    }

    @Test func userNavigationSupersedesAnUnconfirmedRestoreTarget() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = EpubBridgeSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .readium,
            store: EpubBridgeCheckpointStore(directoryURL: directory)
        )
        let initial = EpubLocationBridge.readiumLocator(
            href: "OPS/chapter.xhtml",
            epubCFI: "epubcfi(/6/2!/4/2)",
            fraction: 0.2
        )!
        let userLocation = EpubLocationBridge.readiumLocator(
            href: "OPS/chapter.xhtml",
            epubCFI: "epubcfi(/6/2!/4/8)",
            fraction: 0.7
        )!
        session.setRestoreTarget(locatorJSON: initial, fallbackProgression: 0.2)
        session.noteUserInteraction()

        #expect(session.confirmRestore(observedLocatorJSON: userLocation, fallbackProgression: 0.7))
        let committed = try session.commit(
            locatorJSON: userLocation,
            fallbackProgression: 0.7,
            observedAt: .now
        )
        #expect(committed.totalProgression == 0.7)
    }

    @Test func totalProgressionAloneCannotConfirmARestore() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = EpubBridgeSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .foliate,
            store: EpubBridgeCheckpointStore(directoryURL: directory)
        )
        let target = """
            {"href":"OPS/chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.4}}
            """
        let nearby = """
            {"href":"OPS/chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.401}}
            """
        session.setRestoreTarget(locatorJSON: target, fallbackProgression: 0.4)

        #expect(
            !session.confirmRestore(
                observedLocatorJSON: nearby,
                fallbackProgression: 0.401
            )
        )
    }

    @Test func portableRestoreConfirmationAcceptsAFreshAnchorInTheSameResource() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = EpubBridgeSession(
            bookKey: "book",
            publicationFingerprint: "fingerprint",
            engine: .readium,
            store: EpubBridgeCheckpointStore(directoryURL: directory)
        )
        let target = position(
            href: "OPS/chapter.xhtml",
            progression: 0.4,
            quote: EpubBridgeTextQuote(
                exact: "The sentence used to restore.",
                prefix: nil,
                suffix: nil
            )
        )
        let observed = position(
            href: "chapter.xhtml",
            progression: 0.41,
            quote: EpubBridgeTextQuote(
                exact: "A centered sentence on the restored page.",
                prefix: nil,
                suffix: nil
            )
        )
        session.setRestoreTarget(
            locatorJSON: EpubLocationBridge.readiumLocator(from: target),
            fallbackProgression: target.totalProgression
        )

        #expect(
            session.confirmPortableRestore(
                observedLocatorJSON: EpubLocationBridge.readiumLocator(from: observed),
                fallbackProgression: observed.totalProgression
            )
        )
    }

    @Test func portableRestoreConfirmationRejectsTheWrongResourceOrMissingCapture() {
        let target = position(
            href: "OPS/chapter.xhtml",
            progression: 0.4,
            quote: EpubBridgeTextQuote(
                exact: "The sentence used to restore.",
                prefix: nil,
                suffix: nil
            )
        )
        let wrongResource = position(
            href: "OPS/other.xhtml",
            progression: 0.4,
            quote: EpubBridgeTextQuote(
                exact: "A centered sentence.",
                prefix: nil,
                suffix: nil
            )
        )
        let missingCapture = position(
            href: "OPS/chapter.xhtml",
            progression: 0.4,
            quote: nil
        )

        for observed in [wrongResource, missingCapture] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let session = EpubBridgeSession(
                bookKey: "book",
                publicationFingerprint: "fingerprint",
                engine: .readium,
                store: EpubBridgeCheckpointStore(directoryURL: directory)
            )
            session.setRestoreTarget(
                locatorJSON: EpubLocationBridge.readiumLocator(from: target),
                fallbackProgression: target.totalProgression
            )

            #expect(
                !session.confirmPortableRestore(
                    observedLocatorJSON: EpubLocationBridge.readiumLocator(from: observed),
                    fallbackProgression: observed.totalProgression
                )
            )
        }
    }

    @Test func textQuoteComparisonNormalizesNFCWhitespaceAndContextOverlap() {
        let decomposed = "Cafe\u{301}   au lait"
        let lhs = position(
            quote: EpubBridgeTextQuote(
                exact: decomposed,
                prefix: "earlier words before",
                suffix: "after words later"
            )
        )
        let rhs = position(
            quote: EpubBridgeTextQuote(
                exact: "Café au lait",
                prefix: "words before",
                suffix: "after words"
            )
        )

        #expect(lhs.sharesSemanticLocation(with: rhs))
    }

    @Test func fullCFIConfirmsWithoutTrustingASeparateHrefColumn() {
        let lhs = position(progression: 0.4)
        let rhs = EpubBridgePosition(
            href: "",
            epubCFI: lhs.epubCFI,
            partialCFI: nil,
            cssSelector: nil,
            domRange: nil,
            resourceProgression: nil,
            totalProgression: 0.4,
            textQuote: nil,
            readiumLocatorJSON: nil
        )

        #expect(lhs.sharesSemanticLocation(with: rhs))
    }

    private func position(progression: Double) -> EpubBridgePosition {
        EpubBridgePosition(
            href: "OPS/chapter.xhtml",
            epubCFI: "epubcfi(/6/2!/4/2)",
            partialCFI: "/4/2",
            cssSelector: nil,
            domRange: nil,
            resourceProgression: progression,
            totalProgression: progression,
            textQuote: nil,
            readiumLocatorJSON: nil
        )
    }

    private func position(quote: EpubBridgeTextQuote?) -> EpubBridgePosition {
        position(
            href: "OPS/chapter.xhtml",
            progression: 0.4,
            quote: quote
        )
    }

    private func position(
        href: String,
        progression: Double,
        quote: EpubBridgeTextQuote?
    ) -> EpubBridgePosition {
        EpubBridgePosition(
            href: href,
            epubCFI: nil,
            partialCFI: nil,
            cssSelector: nil,
            domRange: nil,
            resourceProgression: nil,
            totalProgression: progression,
            textQuote: quote,
            readiumLocatorJSON: nil
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("EpubBridgeCheckpointTests-\(UUID().uuidString)", isDirectory: true)
    }
}
