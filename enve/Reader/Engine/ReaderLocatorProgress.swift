import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared

@MainActor
final class ReaderLocatorProgress {
    struct Snapshot {
        enum Source {
            case epub
            case pdf
            case comic
        }

        let progression: Double
        let locatorJSON: String?
        let source: Source
    }

    private(set) var lastKnownLocator: Locator?
    private(set) var lastKnownLocatorJSON: String?
    private var lastSavedProgression: Double?

    func update(locator: Locator, fallbackProgress: Double?) -> Double {
        let progression =
            locator.locations.totalProgression
            ?? locator.locations.progression
            ?? fallbackProgress
            ?? 0
        lastKnownLocator = locator
        lastKnownLocatorJSON = try? locator.jsonString()
        return progression
    }

    func updateLocatorJSON(_ locatorJSON: String?) {
        lastKnownLocatorJSON = locatorJSON
    }

    func shouldSkipAutoSave(currentProgress: Double) -> Bool {
        guard let lastSavedProgression else { return false }
        return abs(currentProgress - lastSavedProgression) < 0.0005
    }

    func markSaved(progression: Double) {
        lastSavedProgression = progression
    }

    func snapshot(
        state: ClassicReaderModel.State,
        currentProgress: Double?,
        currentComicPageIndex: Int,
        lastStablePDFPageIndex: Int,
        totalPages: Int,
        pdfController: PDFReaderController?
    ) -> Snapshot? {
        switch state {
        case .readyEPUB(let nav):
            let liveProgression =
                nav.currentLocation?.locations.totalProgression
                ?? nav.currentLocation?.locations.progression
            let liveLocatorJSON = nav.currentLocation.flatMap { try? $0.jsonString() }
            let preferEnriched =
                locatorsShareLocation(liveLocatorJSON, lastKnownLocatorJSON)
                && lastKnownLocatorHasTextAnchor()

            if let live = liveProgression, live > 0.001 {
                return Snapshot(
                    progression: live,
                    locatorJSON: preferEnriched ? lastKnownLocatorJSON : liveLocatorJSON,
                    source: .epub
                )
            }

            if let cached = currentProgress, cached > 0.001 {
                return Snapshot(
                    progression: cached,
                    locatorJSON: lastKnownLocatorJSON,
                    source: .epub
                )
            }

            return Snapshot(
                progression: liveProgression ?? 0,
                locatorJSON: preferEnriched ? lastKnownLocatorJSON : liveLocatorJSON,
                source: .epub
            )

        case .readyFoliate(let adapter):
            let liveLocatorJSON = adapter.currentLocatorJSON
            let liveLocator = liveLocatorJSON.flatMap { try? Locator(jsonString: $0) }
            let liveProgression =
                liveLocator?.locations.totalProgression
                ?? liveLocator?.locations.progression
            if let liveProgression {
                return Snapshot(
                    progression: liveProgression,
                    locatorJSON: liveLocatorJSON,
                    source: .epub
                )
            }
            return Snapshot(
                progression: currentProgress ?? 0,
                locatorJSON: liveLocatorJSON ?? lastKnownLocatorJSON,
                source: .epub
            )

        case .readyPDF:
            let stablePageIndex = pdfController?.currentPageIndex() ?? lastStablePDFPageIndex
            return Snapshot(
                progression: Self.pdfProgress(pageIndex: stablePageIndex, totalPages: totalPages),
                locatorJSON: Self.makePDFLocator(pageIndex: stablePageIndex),
                source: .pdf
            )

        case .readyComic:
            return Snapshot(
                progression: Self.comicProgress(pageIndex: currentComicPageIndex, totalPages: totalPages),
                locatorJSON: Self.makeComicLocator(pageIndex: currentComicPageIndex),
                source: .comic
            )

        default:
            return nil
        }
    }

    static func restoreComicPageIndex(book: Book, totalPages: Int) -> Int {
        if let locator = book.epubLocator, let parsedIndex = parseComicLocator(locator) {
            return min(max(0, parsedIndex), max(totalPages - 1, 0))
        }
        let fallback = Int(round(book.canonicalEbookProgress * Double(max(totalPages - 1, 0))))
        return min(max(0, fallback), max(totalPages - 1, 0))
    }

    static func restorePDFPageIndex(book: Book, totalPages: Int) -> Int {
        let maxIndex = max(totalPages - 1, 0)
        let progressFallback = Int(round(book.canonicalEbookProgress * Double(maxIndex)))
        let boundedFallback = min(max(0, progressFallback), maxIndex)

        if let locator = book.epubLocator, let parsedIndex = parsePDFLocator(locator) {
            let boundedParsed = min(max(0, parsedIndex), maxIndex)
            if abs(boundedParsed - boundedFallback) > 3,
                boundedFallback > boundedParsed
            {
                return boundedFallback
            }
            return boundedParsed
        }

        return boundedFallback
    }

    static func comicProgress(pageIndex: Int, totalPages: Int) -> Double {
        guard totalPages > 1 else { return totalPages == 0 ? 0 : 1 }
        return Double(pageIndex) / Double(totalPages - 1)
    }

    static func pdfProgress(pageIndex: Int, totalPages: Int) -> Double {
        guard totalPages > 1 else { return totalPages == 0 ? 0 : 1 }
        return Double(pageIndex) / Double(totalPages - 1)
    }

    static func makeComicLocator(pageIndex: Int) -> String {
        "cbz-page:\(pageIndex)"
    }

    static func makePDFLocator(pageIndex: Int) -> String {
        "{\"page\":\(pageIndex)}"
    }

    static func parseComicLocator(_ locator: String?) -> Int? {
        guard let locator, locator.hasPrefix("cbz-page:") else { return nil }
        return Int(locator.dropFirst("cbz-page:".count))
    }

    static func parsePDFLocator(_ locator: String?) -> Int? {
        guard let locator, !locator.isEmpty else { return nil }
        if locator.hasPrefix("pdf-page:") {
            return Int(locator.dropFirst("pdf-page:".count))
        }
        if let data = locator.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let page = object["page"] as? Int
        {
            return page
        }
        return nil
    }

    private func lastKnownLocatorHasTextAnchor() -> Bool {
        guard let json = lastKnownLocatorJSON,
            let data = json.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = obj["text"] as? [String: Any],
            let highlight = text["highlight"] as? String,
            !highlight.isEmpty
        else { return false }
        return true
    }

    private func locatorsShareLocation(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b,
            let aData = a.data(using: .utf8),
            let bData = b.data(using: .utf8),
            let aObj = try? JSONSerialization.jsonObject(with: aData) as? [String: Any],
            let bObj = try? JSONSerialization.jsonObject(with: bData) as? [String: Any]
        else { return false }
        let aHref = aObj["href"] as? String
        let bHref = bObj["href"] as? String
        guard aHref == bHref else { return false }
        let aLoc = aObj["locations"] as? [String: Any]
        let bLoc = bObj["locations"] as? [String: Any]
        let aP = (aLoc?["totalProgression"] as? Double) ?? (aLoc?["progression"] as? Double) ?? 0
        let bP = (bLoc?["totalProgression"] as? Double) ?? (bLoc?["progression"] as? Double) ?? 0
        return abs(aP - bP) < 0.0001
    }
}
