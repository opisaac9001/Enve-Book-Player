import Foundation

struct WorkView: Identifiable {
    let workKey: String
    let editions: [EditionView]

    var id: String { workKey }
    var primaryEdition: EditionView { editions[0] }
    var representative: Book { primaryEdition.representative }
    var title: String { representative.title }
    var author: String? { representative.author }
    var sourceCount: Int { editions.reduce(0) { $0 + $1.sources.count } }
    var editionCount: Int { editions.count }

    var isConsolidated: Bool { sourceCount > 1 || editionCount > 1 }
}

struct EditionView: Identifiable {
    let editionKey: String
    let sources: [Book]
    let representative: Book

    var id: String { editionKey }
    var format: AppMediaType { representative.mediaType }
    var label: String { WorkGrouping.editionLabel(representative) }

    var resumeSource: Book {
        sources.max { WorkGrouping.progressFraction($0) < WorkGrouping.progressFraction($1) } ?? representative
    }
}

struct WorkSlice: Sendable {
    let uniqueId: String
    let stableId: String
    let workKey: String
    let score: Int
}

struct WorkIndex {
    let hiddenUniqueIds: Set<String>
    let representativeWorkKey: [String: String]
    let representativeCount: [String: Int]

    static let empty = WorkIndex(hiddenUniqueIds: [], representativeWorkKey: [:], representativeCount: [:])
}

enum WorkGrouping {

    @MainActor
    static func index(_ slices: [WorkSlice]) -> WorkIndex {
        let overrides = WorkOverrideStore.shared
        var byWork: [String: [WorkSlice]] = [:]
        for slice in slices where !slice.workKey.isEmpty {
            let key = overrides.effectiveWorkKey(stableId: slice.stableId, computed: slice.workKey)
            byWork[key, default: []].append(slice)
        }
        var hidden = Set<String>()
        var repToKey = [String: String]()
        var repCount = [String: Int]()
        for (key, members) in byWork where members.count > 1 {
            let ordered = members.sorted { $0.score != $1.score ? $0.score > $1.score : $0.uniqueId < $1.uniqueId }
            repToKey[ordered[0].uniqueId] = key
            repCount[ordered[0].uniqueId] = members.count
            for member in ordered.dropFirst() { hidden.insert(member.uniqueId) }
        }
        return WorkIndex(hiddenUniqueIds: hidden, representativeWorkKey: repToKey, representativeCount: repCount)
    }

    @MainActor
    static func group(_ books: [Book]) -> [WorkView] {
        let overrides = WorkOverrideStore.shared
        var byWork: [String: [Book]] = [:]
        for book in books {
            let computed = WorkIdentity.workKey(for: book)
            guard !computed.isEmpty else { continue }
            let key = overrides.effectiveWorkKey(stableId: book.stableId, computed: computed)
            byWork[key, default: []].append(book)
        }
        return byWork.compactMap { makeWorkView(workKey: $0.key, members: $0.value) }
    }

    static func makeWorkView(workKey: String, members: [Book]) -> WorkView? {
        guard !members.isEmpty else { return nil }
        var byEdition: [String: [Book]] = [:]
        for book in members {
            let ek = WorkIdentity.editionKey(for: book)
            byEdition[ek.isEmpty ? "u:\(book.uniqueId)" : ek, default: []].append(book)
        }
        let editions =
            byEdition
            .map {
                EditionView(editionKey: $0.key, sources: $0.value.sorted(by: sourcePreferred), representative: representative($0.value))
            }
            .sorted(by: editionPreferred)
        guard !editions.isEmpty else { return nil }
        return WorkView(workKey: workKey, editions: editions)
    }

    static func sourcePreferred(_ a: Book, _ b: Book) -> Bool {
        let sa = sourceScore(a)
        let sb = sourceScore(b)
        if sa != sb { return sa > sb }
        return a.uniqueId < b.uniqueId
    }

    static func representative(_ books: [Book]) -> Book {
        books.sorted(by: sourcePreferred).first ?? books[0]
    }

    static func progressFraction(_ book: Book) -> Double {
        if book.isFinished { return 1 }
        if book.mediaType == .ebook { return book.canonicalEbookProgress }
        guard let duration = book.duration, duration > 0 else { return 0 }
        return min(max(book.currentTime / duration, 0), 1)
    }

    private static func sourceScore(_ b: Book) -> Int {
        var s = 0
        if b.source == .local { s += 4 }
        if b.coverURL != nil { s += 2 }
        if b.description?.isEmpty == false { s += 1 }
        return s
    }

    static func editionPreferred(_ a: EditionView, _ b: EditionView) -> Bool {
        let aActive = progressFraction(a.resumeSource) > 0.001
        let bActive = progressFraction(b.resumeSource) > 0.001
        if aActive != bActive { return aActive }
        if a.format != b.format { return a.format == .audiobook }
        if a.sources.count != b.sources.count { return a.sources.count > b.sources.count }
        return a.editionKey < b.editionKey
    }

    static func editionLabel(_ book: Book) -> String {
        var parts: [String] = [book.mediaType == .ebook ? "Ebook" : "Audiobook"]
        let production = VersionDetector.detectProductionType(from: book)
        if production != .standard {
            parts.append(production.displayName)
        } else if book.mediaType == .audiobook, let narrator = book.narrator, !narrator.isEmpty {
            parts.append(narrator.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? narrator)
        }
        if VersionDetector.detectAbridgedState(from: book) == .abridged {
            parts.append("Abridged")
        }
        if let language = book.language, !language.isEmpty, language.lowercased() != "en", language.lowercased() != "eng",
            language.lowercased() != "english"
        {
            parts.append(language.uppercased())
        }
        return parts.joined(separator: " · ")
    }
}
