import Foundation

struct WorkMergeSuggestion: Identifiable {
    let id: String
    let reason: String
    let books: [Book]
    let targetWorkKey: String

    var representative: Book { books[0] }
    var title: String { representative.title }
    var author: String? { representative.author }
    var stableIds: [String] { books.map(\.stableId) }
}

enum WorkSuggestions {

    @MainActor
    static func identifierSuggestions(from books: [Book]) -> [WorkMergeSuggestion] {
        let overrides = WorkOverrideStore.shared
        var byISBN: [String: [Book]] = [:]
        var byASIN: [String: [Book]] = [:]
        for book in books {
            if let isbn = normalizeISBN(book.isbn) { byISBN[isbn, default: []].append(book) }
            if let asin = normalizeASIN(book.asin) { byASIN[asin, default: []].append(book) }
        }

        var suggestions: [WorkMergeSuggestion] = []
        var emitted = Set<String>()

        func consider(kind: String, reason: String, identifier: String, members: [Book]) {
            var seen = Set<String>()
            let unique = members.filter { seen.insert($0.uniqueId).inserted }
            guard unique.count > 1 else { return }

            let effective = Set(
                unique.map {
                    overrides.effectiveWorkKey(stableId: $0.stableId, computed: WorkIdentity.workKey(for: $0))
                }.filter { !$0.isEmpty }
            )
            guard effective.count > 1 else { return }

            let positions = Set(unique.compactMap(seriesPosition))
            guard positions.count <= 1 else { return }

            let suggestionId = "\(kind):\(identifier)"
            guard !overrides.isDismissed(suggestionId: suggestionId), emitted.insert(suggestionId).inserted else { return }

            let target = WorkIdentity.workKey(for: unique[0])
            guard !target.isEmpty else { return }
            suggestions.append(WorkMergeSuggestion(id: suggestionId, reason: reason, books: unique, targetWorkKey: target))
        }

        for (id, members) in byISBN where members.count > 1 {
            consider(kind: "isbn", reason: "Same ISBN", identifier: id, members: members)
        }
        for (id, members) in byASIN where members.count > 1 {
            consider(kind: "asin", reason: "Same ASIN", identifier: id, members: members)
        }
        return suggestions.sorted { $0.title < $1.title }
    }

    static func normalizeISBN(_ raw: String?) -> String? {
        let digits = (raw ?? "").filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
        return digits.count >= 10 ? digits : nil
    }

    static func normalizeASIN(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.count >= 8 ? trimmed : nil
    }

    private static func seriesPosition(_ book: Book) -> String? {
        if let raw = book.seriesSequence?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let numeric = raw.filter { $0.isNumber || $0 == "." }
            if let value = Double(numeric), value > 0 { return String(format: "%g", value) }
            return raw.lowercased()
        }
        if let number = book.seriesNumber, number > 0 { return String(number) }
        return nil
    }
}
