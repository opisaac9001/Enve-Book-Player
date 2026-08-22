import Testing

@testable import enve

@MainActor
struct EpubLocationBridgeTests {
    @Test func sparseProgressionLocatorIsNotDirectRestorable() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42}}
            """

        #expect(EpubLocationBridge.totalProgression(from: locator) == 0.42)
        #expect(!EpubLocationBridge.canRestoreDirectly(locator))
    }

    @Test func chapterProgressionIsRestorableButNotWholeBookProgress() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"progression":0.42}}
            """

        #expect(EpubLocationBridge.totalProgression(from: locator) == nil)
        #expect(EpubLocationBridge.canRestoreDirectly(locator))
    }

    @Test func textAnchoredLocatorIsDirectRestorable() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42},"text":{"highlight":"a stable text anchor"}}
            """

        #expect(EpubLocationBridge.canRestoreDirectly(locator))
        #expect(EpubLocationBridge.canStoreAlongsidePercentageSync(locator))
    }

    @Test func readiumPositionLocatorIsNotDirectRestorable() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"position":128}}
            """

        #expect(!EpubLocationBridge.canRestoreDirectly(locator))
        #expect(!EpubLocationBridge.canStoreAlongsidePercentageSync(locator))
    }

    @Test func cfiFragmentIsStoredButNeverSentToReadiumAsAnHTMLID() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"fragments":["epubcfi(/6/2!/4/1:8)"]}}
            """

        #expect(!EpubLocationBridge.canRestoreDirectly(locator))
        #expect(EpubLocationBridge.canStoreAlongsidePercentageSync(locator))
        #expect(EpubLocationBridge.locatorForReadiumRestore(locator) == nil)
    }

    @Test func cfiExtensionIsNotDirectlyRestoredByReadium() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"cfi":"epubcfi(/6/2!/4/1:8)"}}
            """

        #expect(!EpubLocationBridge.canRestoreDirectly(locator))
        #expect(EpubLocationBridge.canStoreAlongsidePercentageSync(locator))
        #expect(EpubLocationBridge.epubCFI(from: locator) == "epubcfi(/6/2!/4/1:8)")
    }

    @Test func textFragmentLocatorIsDirectRestorable() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"fragments":["para-12"]}}
            """

        #expect(EpubLocationBridge.canRestoreDirectly(locator))
        #expect(EpubLocationBridge.canStoreAlongsidePercentageSync(locator))
    }

    @Test func audioTimeFragmentIsNotAReadiumHTMLIDAnchor() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"fragments":["t=123.4"]}}
            """

        #expect(!EpubLocationBridge.canRestoreDirectly(locator))
    }

    @Test func totalProgressionIsClamped() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":1.4}}
            """

        #expect(EpubLocationBridge.totalProgression(from: locator) == 1)
    }

    @Test func invalidLocatorIsIgnored() {
        #expect(EpubLocationBridge.totalProgression(from: "epubcfi(/6/2)") == nil)
        #expect(!EpubLocationBridge.canRestoreDirectly("epubcfi(/6/2)"))
        #expect(EpubLocationBridge.epubCFI(from: "epubcfi(/6/2)") == "epubcfi(/6/2)")
    }

    @Test func bareCFIStringsRoundTripForProviderAnnotationUploads() {
        #expect(EpubLocationBridge.epubCFI(from: "epubcfi(/6/14!/4/2/6:0)") == "epubcfi(/6/14!/4/2/6:0)")
        #expect(EpubLocationBridge.epubCFI(from: "") == nil)
        #expect(EpubLocationBridge.epubCFI(from: nil) == nil)
    }

    @Test func cfiIsRecoveredFromAFragmentsOnlyLocator() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"fragments":["page=12","epubcfi(/6/14!/4/2/6:0)"]}}
            """

        #expect(EpubLocationBridge.epubCFI(from: locator) == "epubcfi(/6/14!/4/2/6:0)")
    }

    @Test func providerUploadPreservesLegacyFragmentPrecedence() {
        let locator = """
            {"locations":{"cfi":"epubcfi(/6/2!/4/2:0)","fragments":["page=12","epubcfi(/6/8!/4/4:0)"]}}
            """

        #expect(EpubLocationBridge.epubCFIForProviderUpload(from: locator) == "epubcfi(/6/8!/4/4:0)")
    }

    @Test func providerUploadPreservesBareLegacyCFIString() {
        #expect(EpubLocationBridge.epubCFIForProviderUpload(from: "epubcfi(/6/4") == "epubcfi(/6/4")
        #expect(EpubLocationBridge.epubCFIForProviderUpload(from: "/6/4") == nil)
    }

    @Test func sparseReadiumLocatorIsNotCFI() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"position":128}}
            """

        #expect(EpubLocationBridge.epubCFI(from: locator) == nil)
    }

    @Test func onlyPackageQualifiedCFIIsCanonicalForProviderSync() {
        #expect(
            EpubLocationBridge.canonicalFullEPUBCFI("epubcfi(/6/4!/4/2:3)")
                == "epubcfi(/6/4!/4/2:3)"
        )
        #expect(EpubLocationBridge.canonicalFullEPUBCFI("epubcfi(/4/2:3)") == nil)
        #expect(EpubLocationBridge.canonicalFullEPUBCFI("/4/2:3") == nil)
    }

    @Test func generatedLocatorStoresCFIOnlyInTheExtensionField() {
        let locator = EpubLocationBridge.readiumLocator(
            href: "chapter.xhtml",
            epubCFI: "epubcfi(/6/6!/4/2/8:3)",
            fraction: 0.4,
            resourceProgression: 0.2
        )!

        #expect(EpubLocationBridge.epubCFI(from: locator) == "epubcfi(/6/6!/4/2/8:3)")
        #expect(!locator.contains("\"fragments\""))
        #expect(EpubLocationBridge.locatorForReadiumRestore(locator) != nil)
    }

    @Test func providerCFIRequiresTrustedFoliateProvenance() {
        let rawLocator = EpubLocationBridge.readiumLocator(
            href: "chapter.xhtml",
            epubCFI: "epubcfi(/6/6!/4/2/8:3)",
            fraction: 0.4
        )!
        let readiumLocator = EpubLocationBridge.markingSourceEngine(
            .readium,
            in: rawLocator
        )!
        let foliateLocator = EpubLocationBridge.markingSourceEngine(
            .foliate,
            in: rawLocator
        )!

        #expect(EpubLocationBridge.extractGrimmoryLocation(from: rawLocator).epubCFI == nil)
        #expect(EpubLocationBridge.extractGrimmoryLocation(from: readiumLocator).epubCFI == nil)
        #expect(
            EpubLocationBridge.extractGrimmoryLocation(from: foliateLocator).epubCFI
                == "epubcfi(/6/6!/4/2/8:3)"
        )
        #expect(EpubLocationBridge.sourceEngine(from: foliateLocator) == .foliate)
        #expect(
            EpubLocationBridge.sourceEngine(
                from: EpubLocationBridge.locatorForReadiumRestore(foliateLocator)
            ) == nil
        )
    }

    @Test func hrefAndResourceProgressionAreDirectlyRestorable() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"progression":0.2}}
            """

        #expect(EpubLocationBridge.canRestoreDirectly(locator))
    }

    @Test func cssSelectorAndDOMRangeSurviveLocatorRoundTrip() {
        let position = EpubBridgePosition(
            href: "chapter.xhtml",
            epubCFI: nil,
            partialCFI: "/4/2",
            cssSelector: "#target",
            domRange: .init(
                start: .init(cssSelector: "#target", textNodeIndex: 1, charOffset: 2),
                end: .init(cssSelector: "#target", textNodeIndex: 1, charOffset: 9)
            ),
            resourceProgression: 0.2,
            totalProgression: 0.4,
            textQuote: .init(exact: "stable words", prefix: "the", suffix: "after"),
            readiumLocatorJSON: nil
        )
        let locator = EpubLocationBridge.readiumLocator(from: position)!
        let restored = EpubBridgePosition(readiumLocatorJSON: locator)!

        #expect(restored.cssSelector == position.cssSelector)
        #expect(restored.domRange == position.domRange)
        #expect(restored.textQuote == position.textQuote)
    }

    @Test func foliateReturnLocatorKeepsExactCFIWithoutSelectionPayload() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","title":"Chapter 4","locations":{"totalProgression":0.42,"progression":0.2,"cfi":"epubcfi(/6/6!/4/2/8:3)","cssSelector":"#paragraph","domRange":{"start":{"cssSelector":"#paragraph","textNodeIndex":0,"charOffset":12}},"enveSourceEngine":"foliate"},"text":{"highlight":"A long selected passage that should not be duplicated.","before":"Before","after":"After"}}
            """

        let compact = EpubLocationBridge.compactReturnLocator(from: locator)!

        #expect(compact.count < locator.count)
        #expect(
            EpubLocationBridge.epubCFI(from: compact)
                == "epubcfi(/6/6!/4/2/8:3)"
        )
        #expect(compact.contains("\"enveSourceEngine\":\"foliate\""))
        #expect(!compact.contains("\"text\""))
        #expect(!compact.contains("\"domRange\""))
        #expect(!compact.contains("\"cssSelector\""))
        #expect(EpubLocationBridge.sourceEngine(from: compact) == .foliate)
        #expect(EpubLocationBridge.canStoreAlongsidePercentageSync(compact))
    }

    @Test func nonFoliateReturnLocatorIsPreserved() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"progression":0.2},"text":{"highlight":"a stable text anchor"}}
            """

        #expect(EpubLocationBridge.compactReturnLocator(from: locator) == locator)
    }

    @Test func readerDeepLinkRoundTripsCompactFoliateLocator() {
        let locator = """
            {"href":"chapter.xhtml","type":"application/xhtml+xml","locations":{"totalProgression":0.42,"cfi":"epubcfi(/6/6!/4/2/8:3)","enveSourceEngine":"foliate"}}
            """
        let url = EnveBookLink.readerURL(bookID: "book-42", locator: locator)
        guard let request = EnveBookLink.readerRequest(from: url) else {
            Issue.record("Reader deep link did not parse.")
            return
        }

        #expect(request.bookID == "book-42")
        #expect(
            EpubLocationBridge.epubCFI(from: request.locator)
                == "epubcfi(/6/6!/4/2/8:3)"
        )
        #expect(EpubLocationBridge.sourceEngine(from: request.locator) == .foliate)
    }
}
