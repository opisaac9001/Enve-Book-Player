import Foundation

nonisolated struct HardcoverIdentifiers {
    let isbn: String?
    let asin: String?

    init(isbn: String?, asin: String?) {
        let cleaned = isbn?.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        self.isbn = cleaned.flatMap { Self.validISBN($0) ? $0 : nil }
        let audible = asin?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.asin = audible.flatMap { value in
            value.count == 10 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) } ? value : nil
        }
    }

    var isEmpty: Bool { isbn == nil && asin == nil }

    static func validISBN(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        if bytes.count == 13, bytes.allSatisfy({ (48...57).contains($0) }), value.hasPrefix("978") || value.hasPrefix("979") {
            return bytes.enumerated().reduce(0) { $0 + Int($1.element - 48) * ($1.offset.isMultiple(of: 2) ? 1 : 3) } % 10 == 0
        }
        if bytes.count == 10, bytes.prefix(9).allSatisfy({ (48...57).contains($0) }),
            let last = bytes.last, (48...57).contains(last) || last == 88 {
            let total = bytes.prefix(9).enumerated().reduce(0) { $0 + Int($1.element - 48) * (10 - $1.offset) }
            return (total + (last == 88 ? 10 : Int(last - 48))) % 11 == 0
        }
        return false
    }
}

struct HardcoverIdentifierEdition: Decodable {
    let id: Int
    let bookId: Int
    let isbn10: String?
    let isbn13: String?
    let asin: String?
    let pages: Int?
    let book: HardcoverBook

    static func select(_ editions: [Self], identifiers: HardcoverIdentifiers) throws -> Self? {
        let matches = editions.filter { edition in
            edition.id > 0 && edition.bookId > 0 &&
                ((identifiers.isbn != nil && [edition.isbn10, edition.isbn13].contains(identifiers.isbn)) ||
                    (identifiers.asin != nil && edition.asin?.uppercased() == identifiers.asin))
        }
        guard !matches.isEmpty else { return nil }
        guard Set(matches.map(\.bookId)).count == 1 else { throw HardcoverSyncError.conflictingIdentifiers }
        let exact = matches.filter { edition in
            (identifiers.isbn == nil || [edition.isbn10, edition.isbn13].contains(identifiers.isbn)) &&
                (identifiers.asin == nil || edition.asin?.uppercased() == identifiers.asin)
        }
        guard Set(exact.map(\.id)).count == 1, let selected = exact.first else {
            throw HardcoverSyncError.conflictingIdentifiers
        }
        return selected
    }
}
