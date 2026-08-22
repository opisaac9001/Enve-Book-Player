import Foundation
@preconcurrency import ReadiumShared

@MainActor
final class ReaderTOCIndex {
    struct PageMarker: Equatable {
        let label: String
        let progression: Double
    }

    var onEntriesChange: (() -> Void)?

    var entries: [ClassicTOCEntry] = [] {
        willSet { onEntriesChange?() }
    }

    private(set) var progressions: [(entry: ClassicTOCEntry, progression: Double)] = []
    private(set) var positionLocators: [Locator] = []
    private(set) var pageMarkers: [PageMarker] = []

    var pageCount: Int {
        pageMarkers.isEmpty ? positionLocators.count : pageMarkers.count
    }

    func loadPositions(_ readingOrderPositions: [[Locator]]) {
        positionLocators = readingOrderPositions.flatMap { $0 }
    }

    func loadPageMarkers(_ markers: [PageMarker]) {
        pageMarkers = markers
    }

    func clearPositions() {
        positionLocators = []
        pageMarkers = []
    }

    @discardableResult
    func buildProgressions(
        readingOrder: [ReadiumShared.Link],
        readingOrderPositions: [[Locator]]
    ) -> [(entry: ClassicTOCEntry, progression: Double)]? {
        guard !entries.isEmpty else { return nil }

        var roMap: [String: (index: Int, positions: [Locator])] = [:]
        for (idx, item) in readingOrder.enumerated() {
            let key = item.url().string
            if idx < readingOrderPositions.count {
                roMap[key] = (idx, readingOrderPositions[idx])
            }
        }

        var entriesByFile: [String: [Int]] = [:]
        for (i, entry) in entries.enumerated() {
            let file = entry.href.components(separatedBy: "#").first ?? entry.href
            entriesByFile[file, default: []].append(i)
        }

        var result: [(entry: ClassicTOCEntry, progression: Double)] = []

        for (file, entryIndices) in entriesByFile {
            let matchKey = roMap.keys.first(where: { key in
                key == file || key.hasSuffix(file) || file.hasSuffix(key)
            })

            guard let matchKey, let roData = roMap[matchKey] else {
                for i in entryIndices {
                    result.append((entries[i], -1))
                }
                continue
            }

            let positions = roData.positions
            guard !positions.isEmpty else {
                for i in entryIndices {
                    result.append((entries[i], -1))
                }
                continue
            }

            let fileStartPosition = positions.first?.locations.totalProgression ?? 0
            let fileEndPosition = positions.last?.locations.totalProgression ?? fileStartPosition

            if entryIndices.count == 1 {
                result.append((entries[entryIndices[0]], fileStartPosition))
            } else {
                let span = fileEndPosition - fileStartPosition
                for (slotIdx, entryIdx) in entryIndices.enumerated() {
                    let fraction = Double(slotIdx) / Double(entryIndices.count)
                    let prog = fileStartPosition + fraction * span
                    result.append((entries[entryIdx], prog))
                }
            }
        }

        progressions =
            result
            .filter { $0.progression >= 0 }
            .sorted { $0.progression < $1.progression }
        return progressions
    }

    static func resolvePageMarkers(in publication: Publication) async -> [PageMarker] {
        var markers: [PageMarker] = []
        for (index, link) in publication.pageList.enumerated() {
            guard !Task.isCancelled,
                let locator = await publication.locate(link),
                let progression = locator.locations.totalProgression
            else {
                continue
            }
            let rawTitle = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title: String?
            if let rawTitle, rawTitle.lowercased().hasPrefix("page ") {
                let suffix = rawTitle.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                title = suffix.isEmpty ? nil : suffix
            } else {
                title = rawTitle.flatMap { $0.isEmpty ? nil : $0 }
            }
            markers.append(
                PageMarker(
                    label: title ?? String(index + 1),
                    progression: progression
                )
            )
        }
        return markers.sorted { $0.progression < $1.progression }
    }

    var tickProgressions: [Double] {
        progressions.map(\.progression)
    }

    func chapterIndex(for progress: Double?) -> Int? {
        guard let progress, !progressions.isEmpty else { return nil }
        var best = 0
        for (i, entry) in progressions.enumerated() {
            if entry.progression <= progress + 0.001 { best = i }
        }
        return best
    }

    func chapterEndProgression(atChapter index: Int) -> Double? {
        guard progressions.indices.contains(index) else { return nil }
        let nextIndex = index + 1
        if progressions.indices.contains(nextIndex) {
            return progressions[nextIndex].progression
        }
        return 1
    }

    func nextChapterProgression(after progression: Double) -> Double? {
        guard !progressions.isEmpty else { return nil }
        for entry in progressions where entry.progression > progression + 0.0005 {
            return entry.progression
        }
        return nil
    }

    func entry(for locator: Locator) -> ClassicTOCEntry? {
        let href = locator.href.string
        let normalizedHref = Self.normalizedChapterHref(href)
        if let exact = entries.first(where: { Self.normalizedChapterHref($0.href) == normalizedHref }) {
            return exact
        }

        let resourcePath = Self.normalizedResourcePath(href)
        if let exactResource = entries.first(where: { Self.normalizedResourcePath($0.href) == resourcePath }) {
            return exactResource
        }

        if let totalProgression = locator.locations.totalProgression, !progressions.isEmpty {
            return progressions.last { $0.progression <= totalProgression + 0.001 }?.entry
        }

        return entries.first {
            let entryPath = Self.normalizedResourcePath($0.href)
            return entryPath.hasSuffix(resourcePath) || resourcePath.hasSuffix(entryPath)
        }
    }

    func fallbackSectionTitle(from locator: Locator) -> String? {
        guard let totalProg = locator.locations.totalProgression, !progressions.isEmpty else {
            if let title = locator.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        var best: ClassicTOCEntry?
        for item in progressions {
            if item.progression <= totalProg + 0.001 {
                best = item.entry
            } else {
                break
            }
        }

        return best?.displayTitle
            ?? locator.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matchingEntry(for selection: EbookReaderInitialSelection) -> ClassicTOCEntry? {
        if let href = Self.hrefFromChapterID(selection.chapterID) {
            let normalizedTarget = Self.normalizedChapterHref(href)
            if let matched = entries.first(where: {
                let candidate = Self.normalizedChapterHref($0.href)
                return candidate == normalizedTarget || candidate.hasPrefix(normalizedTarget) || normalizedTarget.hasPrefix(candidate)
            }) {
                return matched
            }
        }

        if entries.indices.contains(selection.chapterIndex) {
            return entries[selection.chapterIndex]
        }

        let normalizedTitle = selection.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedTitle.isEmpty {
            return entries.first { $0.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTitle }
        }

        return nil
    }

    func fragmentTitleCandidates(for locator: Locator) -> [(fragment: String, title: String)] {
        let resourcePath = Self.normalizedResourcePath(locator.href.string)
        return entries.compactMap { entry -> (fragment: String, title: String)? in
            let parts = entry.href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let entryPath = String(parts.first ?? "")
            guard entryPath == resourcePath || entryPath.hasSuffix(resourcePath) || resourcePath.hasSuffix(entryPath) else {
                return nil
            }
            guard parts.count == 2 else { return nil }
            let fragment = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { return nil }
            return (fragment, entry.displayTitle)
        }
    }

    func positionLocator(atChapter index: Int) -> Locator? {
        positionLocators.indices.contains(index) ? positionLocators[index] : nil
    }

    func locatorAtOrBefore(progression: Double) -> Locator? {
        guard progression > 0.001, !positionLocators.isEmpty else { return nil }
        let bounded = min(max(progression, 0), 0.999_999)
        var best: Locator?

        for (index, locator) in positionLocators.enumerated() {
            let locatorProgress =
                locator.locations.totalProgression
                ?? locator.locations.progression
                ?? Double(index) / max(Double(positionLocators.count - 1), 1)
            if locatorProgress <= bounded + 0.000_001 {
                best = locator
            } else {
                break
            }
        }

        return best ?? positionLocators.first
    }

    var hasPageMarkers: Bool { !pageMarkers.isEmpty }

    func pageNumber(forProgression progression: Double) -> Int? {
        guard !pageMarkers.isEmpty else { return nil }
        let index = pageMarkers.lastIndex { $0.progression <= progression + 0.000_001 } ?? 0
        return index + 1
    }

    func pageLabel(atPage page: Int) -> String? {
        pageMarkers.indices.contains(page - 1) ? pageMarkers[page - 1].label : nil
    }

    var lastPageLabel: String? { pageMarkers.last?.label }

    static func flatten(_ links: [ReadiumShared.Link], depth: Int = 0) -> [ClassicTOCEntry] {
        links.flatMap { link in
            let cleaned = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = (cleaned?.isEmpty == false ? cleaned : URL(string: link.href)?.lastPathComponent) ?? "Untitled"
            let entry = ClassicTOCEntry(
                id: "\(depth)-\(link.href)",
                link: link,
                depth: depth,
                displayTitle: title
            )
            return [entry] + flatten(link.children, depth: depth + 1)
        }
    }

    static func normalizedResourcePath(_ href: String) -> String {
        href.components(separatedBy: "#").first ?? href
    }

    static func normalizedChapterHref(_ href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        return
            decoded
            .replacingOccurrences(of: "./", with: "")
            .replacingOccurrences(of: "%20", with: " ")
            .lowercased()
    }

    static func hrefFromChapterID(_ chapterID: String) -> String? {
        let prefix = "ebook-chapter-"
        guard chapterID.hasPrefix(prefix) else { return nil }
        let remainder = String(chapterID.dropFirst(prefix.count))
        guard let separatorIndex = remainder.firstIndex(of: "-") else { return nil }
        let hrefStart = remainder.index(after: separatorIndex)
        guard hrefStart < remainder.endIndex else { return nil }
        return String(remainder[hrefStart...])
    }
}
