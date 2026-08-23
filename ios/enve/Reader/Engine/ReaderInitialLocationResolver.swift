import Foundation
import Logging
@preconcurrency import ReadiumShared

struct ReaderInitialLocation: Equatable {
    let locator: Locator?
    let locatorJSON: String?

    static let unresolved = ReaderInitialLocation(locator: nil, locatorJSON: nil)
}

@MainActor
final class ReaderInitialLocationResolver {
    struct BridgeCheckpoint {
        let observedAt: Date?
        let locatorJSON: String?
    }

    struct Request {
        let publication: Publication
        let pendingSelection: EbookReaderInitialSelection?
        let bridge: BridgeCheckpoint?
        let engineKind: ReaderEngineKind
        let usesMediaOverlayPosition: Bool
    }

    private let book: Book
    private let libraryCache: LibraryBookCache
    private let tocIndex: ReaderTOCIndex
    private let readAloud: ReaderReadAloudController

    init(
        book: Book,
        libraryCache: LibraryBookCache,
        tocIndex: ReaderTOCIndex,
        readAloud: ReaderReadAloudController
    ) {
        self.book = book
        self.libraryCache = libraryCache
        self.tocIndex = tocIndex
        self.readAloud = readAloud
    }

    func resolve(_ request: Request) async -> ReaderInitialLocation {
        var location = ReaderInitialLocation.unresolved
        if let selection = request.pendingSelection {
            location = await selectedLocation(for: selection, in: request.publication)
        }
        if location.locator == nil {
            location = await restoredLocation(request)
        }
        return Self.validating(location, readingOrderHrefs: request.publication.readingOrder.map(\.href))
    }

    static func selectedLocation(from selection: EbookReaderInitialSelection) -> ReaderInitialLocation? {
        guard let locatorJSON = selection.locatorJSON,
            let locator = try? Locator(jsonString: locatorJSON)
        else { return nil }
        return ReaderInitialLocation(locator: locator, locatorJSON: locatorJSON)
    }

    static func validating(
        _ location: ReaderInitialLocation,
        readingOrderHrefs: [String]
    ) -> ReaderInitialLocation {
        guard let locator = location.locator else { return .unresolved }

        let targetHref = ReaderLocationController.normalizedHref(locator.href.string)
        if !targetHref.isEmpty,
            !readingOrderHrefs.contains(where: { ReaderLocationController.normalizedHref($0) == targetHref })
        {
            AppLogger.library.warning("Ignoring stale initial locator href: \(locator.href.string)")
            return .unresolved
        }

        return ReaderInitialLocation(
            locator: locator,
            locatorJSON: location.locatorJSON ?? (try? locator.jsonString())
        )
    }

    private func selectedLocation(
        for selection: EbookReaderInitialSelection,
        in publication: Publication
    ) async -> ReaderInitialLocation {
        if let selected = Self.selectedLocation(from: selection) {
            return selected
        }
        if let entry = tocIndex.matchingEntry(for: selection),
            let link = entry.link,
            let locator = await publication.locate(link)
        {
            return ReaderInitialLocation(locator: locator, locatorJSON: nil)
        }
        return ReaderInitialLocation(
            locator: tocIndex.positionLocator(atChapter: selection.chapterIndex),
            locatorJSON: nil
        )
    }

    private func restoredLocation(_ request: Request) async -> ReaderInitialLocation {
        let freshestBook = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        if ReaderInitialLocationPolicy.bridgeCheckpointIsCurrent(
            observedAt: request.bridge?.observedAt,
            bookLastUpdate: freshestBook.lastUpdate
        ),
            let bridgeLocatorJSON = request.bridge?.locatorJSON,
            let bridgeLocator = try? Locator(jsonString: bridgeLocatorJSON)
        {
            return ReaderInitialLocation(locator: bridgeLocator, locatorJSON: bridgeLocatorJSON)
        }

        let preferred = await preferredLocation(in: request.publication)
        let latestBook = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        guard !request.usesMediaOverlayPosition,
            request.engineKind == .foliate,
            let rawLocatorJSON = latestBook.epubLocator,
            !rawLocatorJSON.isEmpty,
            EpubLocationBridge.canStoreAlongsidePercentageSync(rawLocatorJSON),
            let rawLocator = try? Locator(jsonString: rawLocatorJSON)
        else {
            return ReaderInitialLocation(locator: preferred, locatorJSON: nil)
        }

        let rawProgress =
            rawLocator.locations.totalProgression
            ?? rawLocator.locations.progression
            ?? 0
        guard ReaderInitialLocationPolicy.acceptsRawEngineLocator(
            canonicalProgress: latestBook.canonicalEbookProgress,
            rawProgress: rawProgress
        ) else {
            return ReaderInitialLocation(locator: preferred, locatorJSON: nil)
        }
        return ReaderInitialLocation(locator: rawLocator, locatorJSON: rawLocatorJSON)
    }

    private func preferredLocation(in publication: Publication) async -> Locator? {
        MediaOverlayPlaybackService.shared.syncCurrentPlaybackPositionIfActive(for: book)
        let freshestBook = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        let isReadAloudLike = freshestBook.hasEPUB3MediaOverlay || readAloud.hasMediaOverlay
        let rawLocator = freshestBook.epubLocator.flatMap { $0.isEmpty ? nil : $0 }
        let parsed = rawLocator.flatMap { try? Locator(jsonString: $0) }

        if !isReadAloudLike, rawLocator == nil,
            let calibrated = await calibratedLinkedAudioLocation(for: freshestBook, in: publication)
        {
            return calibrated
        }

        let progressLocation = tocIndex.locatorAtOrBefore(progression: freshestBook.canonicalEbookProgress)
        let ranking = ReaderInitialLocationPolicy.storedRanking(
            isReadAloudLike: isReadAloudLike,
            syncedProgress: freshestBook.canonicalEbookProgress,
            hasProgressLocator: progressLocation != nil,
            storedProgress: parsed.map { $0.locations.totalProgression ?? $0.locations.progression ?? 0 },
            highlight: parsed?.text.highlight
        )

        for step in ranking {
            switch step {
            case .overlayRestore:
                if let rawLocator, let parsed,
                    let overlayLocation = await readAloud.resolvedInitialLocation(
                        rawLocator: rawLocator,
                        parsed: parsed,
                        publication: publication
                    )
                {
                    return overlayLocation
                }
            case .progressLocator:
                if let progressLocation { return progressLocation }
            case .snippetSearch:
                if let parsed,
                    let highlight = parsed.text.highlight,
                    let resolved = await resolveLocatorBySnippet(
                        highlight: highlight,
                        preferredHref: parsed.href.string,
                        in: publication
                    )
                {
                    return resolved
                }
            case .storedLocator:
                if let parsed { return ReaderLocationController.strippingCFIFragments(parsed) }
            }
        }
        return nil
    }

    private func calibratedLinkedAudioLocation(
        for freshestBook: Book,
        in publication: Publication
    ) async -> Locator? {
        guard let linkedBook = EbookAudiobookLinker.shared.linkedAudiobook(for: freshestBook) else {
            return nil
        }
        let linked = libraryCache.bookInMemory(stableId: linkedBook.stableId) ?? linkedBook
        let stored = BookProgressStore.shared.loadProgress(for: linked)
        let duration = max(linked.duration ?? 0, stored?.duration ?? 0)
        let linkedDate = linked.lastUpdate
        let storedDate = stored.map { Date(timeIntervalSince1970: $0.lastUpdated) } ?? .distantPast
        let audioDate = max(linkedDate, storedDate)
        let audioTime = storedDate > linkedDate ? (stored?.progress ?? 0) : linked.currentTime
        guard duration > 0,
            audioDate >= freshestBook.lastUpdate,
            let hint = LinkedBookProgressCoordinator.shared.calibratedLocatorHint(
                ebookStableId: freshestBook.stableId,
                audiobookStableId: linked.stableId,
                audioProgress: min(max(audioTime / duration, 0), 1)
            )
        else { return nil }

        return await resolveLocatorBySnippet(
            highlight: hint.quote,
            preferredHref: hint.href ?? "",
            in: publication
        )
    }

    private func resolveLocatorBySnippet(
        highlight: String,
        preferredHref: String,
        in publication: Publication
    ) async -> Locator? {
        switch await publication.search(query: highlight, options: nil) {
        case .success(let iterator):
            var fallbackMatch: Locator?
            while case .success(let collection) = await iterator.next(), let collection {
                for locator in collection.locators {
                    if locator.href.string == preferredHref { return locator }
                    if fallbackMatch == nil { fallbackMatch = locator }
                }
            }
            return fallbackMatch
        case .failure(let error):
            AppLogger.library.warning("Snippet search failed: \(error.localizedDescription)")
            return nil
        }
    }
}
