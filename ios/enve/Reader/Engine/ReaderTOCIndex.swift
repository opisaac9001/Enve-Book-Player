import Foundation
@preconcurrency import ReadiumShared

@MainActor
final class ReaderTOCIndex {
    struct PageMarker: Equatable {
        let label: String
        let progression: Double
    }

    struct StartPage: Equatable {
        let label: String
        let isEstimated: Bool
    }

    struct EntryLengths: Equatable {
        var pages: [String: Int] = [:]
        /// One-based book pages, matching `visiblePageRange`.
        var pageRanges: [String: ClosedRange<Int>] = [:]
        /// Publisher page labels where the book has a page list, otherwise one-based positions.
        var starts: [String: StartPage] = [:]
        var isEstimated = true
    }

    var onEntriesChange: (() -> Void)?

    var entries: [ClassicTOCEntry] = [] {
        willSet { onEntriesChange?() }
        didSet {
            if entryLengths != EntryLengths() { entryLengths = EntryLengths() }
        }
    }

    private(set) var entryLengths = EntryLengths() {
        willSet { onEntriesChange?() }
    }

    private(set) var progressions: [(entry: ClassicTOCEntry, progression: Double)] = []
    private(set) var positionLocators: [Locator] = []
    private(set) var pageMarkers: [PageMarker] = []
    /// Where each anchored entry starts inside its resource, for resources that hold several entries or a fragment.
    private(set) var anchorFractions: [String: Double] = [:]

    var pageCount: Int {
        pageMarkers.isEmpty ? positionLocators.count : pageMarkers.count
    }

    func loadPositions(_ readingOrderPositions: [[Locator]]) {
        positionLocators = readingOrderPositions.flatMap { $0 }
    }

    func loadPageMarkers(_ markers: [PageMarker]) {
        pageMarkers = markers
    }

    func loadAnchorFractions(_ fractions: [String: Double]) {
        anchorFractions = fractions
    }

    static func resolveAnchorFractions(for entries: [ClassicTOCEntry], in publication: Publication) async -> [String: Double] {
        let byResource = Dictionary(grouping: entries) { normalizedResourcePath($0.href) }
        var fractions: [String: Double] = [:]
        for (resourcePath, siblings) in byResource where siblings.count > 1 || anchor(of: siblings[0].href) != nil {
            guard !Task.isCancelled,
                let resource = publication.get(Link(href: resourcePath)),
                let data = try? await resource.read().get(),
                let html = String(data: data, encoding: .utf8),
                !html.isEmpty
            else { continue }
            let length = Double(html.utf8.count)
            for entry in siblings {
                guard let fragment = anchor(of: entry.href) else {
                    fractions[entry.id] = 0
                    continue
                }
                let offset = ["id=\"\(fragment)\"", "id='\(fragment)'", "name=\"\(fragment)\""].lazy
                    .compactMap { html.range(of: $0) }
                    .first
                    .map { Double(html.utf8.distance(from: html.startIndex, to: $0.lowerBound)) }
                if let offset {
                    fractions[entry.id] = offset / length
                }
            }
        }
        return fractions
    }

    private static func anchor(of href: String) -> String? {
        let parts = href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let fragment = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        return fragment.isEmpty ? nil : (fragment.removingPercentEncoding ?? fragment)
    }

    func clearPositions() {
        positionLocators = []
        pageMarkers = []
        if entryLengths != EntryLengths() { entryLengths = EntryLengths() }
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
        // Starts spread evenly across a shared resource are guesses and must not bound a length.
        var knownStarts: [String: Double] = [:]
        var approximateStarts: Set<String> = []

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

            let span = fileEndPosition - fileStartPosition
            if entryIndices.count == 1 {
                let entry = entries[entryIndices[0]]
                result.append((entry, fileStartPosition))
                if Self.anchor(of: entry.href) == nil {
                    knownStarts[entry.id] = fileStartPosition
                } else if let fraction = anchorFractions[entry.id] {
                    knownStarts[entry.id] = fileStartPosition + fraction * span
                    approximateStarts.insert(entry.id)
                }
            } else {
                for (slotIdx, entryIdx) in entryIndices.enumerated() {
                    let anchorFraction = anchorFractions[entries[entryIdx].id]
                    let fraction = anchorFraction ?? Double(slotIdx) / Double(entryIndices.count)
                    let prog = fileStartPosition + fraction * span
                    result.append((entries[entryIdx], prog))
                    if let anchorFraction {
                        knownStarts[entries[entryIdx].id] = prog
                        // Zero means the entry has no fragment; anything else is a byte-offset estimate.
                        if anchorFraction > 0 { approximateStarts.insert(entries[entryIdx].id) }
                    }
                }
            }
        }

        progressions =
            result
            .filter { $0.progression >= 0 }
            .sorted { $0.progression < $1.progression }
        entryLengths = resolveEntryLengths(knownStarts: knownStarts, approximateStarts: approximateStarts)
        return progressions
    }

    // An entry ends where the next entry at its depth or shallower starts, so children do not shorten their parent.
    private func resolveEntryLengths(knownStarts: [String: Double], approximateStarts: Set<String>) -> EntryLengths {
        let usesPageMarkers = !pageMarkers.isEmpty
        let markers = pageMarkers
            .filter { $0.progression.isFinite && (0...1).contains($0.progression) }
            .sorted { $0.progression < $1.progression }
        let boundaries =
            usesPageMarkers
            ? markers.map(\.progression)
            : positionLocators.compactMap(\.locations.totalProgression)
                .filter { $0.isFinite && (0...1).contains($0) }
                .sorted()
        guard !boundaries.isEmpty else { return EntryLengths() }

        var nextIndices: [Int?] = Array(repeating: nil, count: entries.count)
        var open: [Int] = []
        for (index, entry) in entries.enumerated() {
            while let last = open.last, entries[last].depth >= entry.depth {
                nextIndices[last] = index
                open.removeLast()
            }
            open.append(index)
        }

        let tolerance = 0.000_001
        var pages: [String: Int] = [:]
        var pageRanges: [String: ClosedRange<Int>] = [:]
        var starts: [String: StartPage] = [:]
        var usesApproximateStart = false
        for (index, entry) in entries.enumerated() {
            guard let start = knownStarts[entry.id], start.isFinite, start >= 0 else { continue }
            let lower: Int
            if usesPageMarkers {
                // Count the published page already open at the start; nothing before the first marker is a page.
                lower = max(Self.firstIndex(in: boundaries, notBelow: start + tolerance) - 1, 0)
            } else {
                lower = Self.firstIndex(in: boundaries, notBelow: start - tolerance)
            }
            // Front matter before the first printed page has no page number of its own.
            if lower < boundaries.count, !usesPageMarkers || boundaries[0] <= start + tolerance {
                starts[entry.id] = StartPage(
                    label: usesPageMarkers ? markers[lower].label : String(lower + 1),
                    isEstimated: !usesPageMarkers || approximateStarts.contains(entry.id)
                )
            }
            let endID = nextIndices[index].map { entries[$0].id }
            let knownEnd: Double? = if let endID { knownStarts[endID] } else { 1 }
            guard let end = knownEnd, end.isFinite, end <= 1 + tolerance, end - start > tolerance else { continue }
            let upper = end >= 1 ? boundaries.count : Self.firstIndex(in: boundaries, notBelow: end - tolerance)
            guard upper > lower else { continue }
            pages[entry.id] = upper - lower
            pageRanges[entry.id] = (lower + 1)...upper
            if approximateStarts.contains(entry.id) || endID.map(approximateStarts.contains) == true {
                usesApproximateStart = true
            }
        }
        return EntryLengths(
            pages: pages,
            pageRanges: pageRanges,
            starts: starts,
            isEstimated: !usesPageMarkers || usesApproximateStart || starts.values.contains(where: \.isEstimated)
        )
    }

    private static func firstIndex(in sorted: [Double], notBelow value: Double) -> Int {
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
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
        if let anchored = anchoredEntry(for: locator) {
            return anchored
        }
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

    /// A resource holding several entries (a single-file book) is resolved by where the reader is inside it.
    private func anchoredEntry(for locator: Locator) -> ClassicTOCEntry? {
        let resourcePath = Self.normalizedChapterHref(Self.normalizedResourcePath(locator.href.string))
        let siblings = entries.filter { Self.normalizedChapterHref(Self.normalizedResourcePath($0.href)) == resourcePath }
        guard siblings.count > 1 else { return nil }
        let locatorFragments = Set(locator.locations.fragments)
        if let matched = siblings.first(where: { Self.anchor(of: $0.href).map(locatorFragments.contains) == true }) {
            return matched
        }
        guard let progression = locator.locations.progression else { return nil }
        let anchored = siblings.compactMap { entry in anchorFractions[entry.id].map { (entry, $0) } }
        guard !anchored.isEmpty else { return nil }
        return anchored.filter { $0.1 <= progression + 0.001 }.max { $0.1 < $1.1 }?.0 ?? anchored.min { $0.1 < $1.1 }?.0
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
