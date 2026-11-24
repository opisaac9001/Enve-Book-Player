import Foundation

struct SystemEbook: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let author: String?

    init(_ book: Book) {
        id = book.stableId
        title = book.title
        author = book.author
    }
}

enum EbookSystemError: LocalizedError, Equatable {
    case unavailable
    case nothingToContinue

    var errorDescription: String? {
        switch self {
        case .unavailable: "Open Enve with the adult owner profile and reading enabled to access this ebook."
        case .nothingToContinue: "There isn't an ebook to continue reading in Enve."
        }
    }
}

@MainActor
@Observable
final class EbookSystemService {
    struct Request: Identifiable {
        let id = UUID()
        let bookID: String
    }

    private(set) var pendingRequest: Request?
    private let books: any BookQuerying
    private let lastOpened: LastOpenedBookStore
    private let isAllowed: () -> Bool

    init(books: any BookQuerying, lastOpened: LastOpenedBookStore, isAllowed: @escaping () -> Bool) {
        self.books = books
        self.lastOpened = lastOpened
        self.isAllowed = isAllowed
    }

    static var permittedSession: ProfileSession? {
        let profiles = ProfileSwitchCoordinator.shared
        let session = profiles.activeSession
        guard !profiles.isLocked, !profiles.isSwitching, session.isOwner, !session.isRetired,
            session.preferences.readingEnabled else { return nil }
        return session
    }

    func search(_ text: String) async -> [SystemEbook] {
        guard isAllowed() else { return [] }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return await suggestions() }
        let matches = await books.searchBooks(query: query, mediaType: "ebook", limit: 50)
        return isAllowed() ? descriptors(matches) : []
    }

    func entities(for identifiers: [String]) async -> [SystemEbook] {
        var result: [SystemEbook] = []
        for id in identifiers {
            guard isAllowed(), !Task.isCancelled else { return [] }
            if let book = await books.visibleEbook(stableId: id) { result.append(SystemEbook(book)) }
        }
        return isAllowed() ? result : []
    }

    func suggestions() async -> [SystemEbook] {
        guard isAllowed() else { return [] }
        let current = await lastBook().map { [$0] } ?? []
        guard isAllowed() else { return [] }
        let reading = await books.continueReadingBooks(limit: 20)
        let recent = await books.recentEbooks(limit: 20)
        return isAllowed() ? Array(descriptors(current + reading + recent).prefix(20)) : []
    }

    func spotlightBooks() async -> [SystemEbook] {
        guard isAllowed() else { return [] }
        let current = await lastBook().map { [$0] } ?? []
        let reading = await books.continueReadingBooks(limit: 20)
        guard isAllowed() else { return [] }
        let downloaded = await books.downloadedEbooks(limit: 50)
        return isAllowed() ? descriptors(current + reading + downloaded) : []
    }

    func requestOpen(_ identifier: String) async throws {
        guard isAllowed(), let book = await books.visibleEbook(stableId: identifier), isAllowed() else {
            throw EbookSystemError.unavailable
        }
        pendingRequest = Request(bookID: book.stableId)
    }

    func requestContinue() async throws {
        guard isAllowed() else { throw EbookSystemError.unavailable }
        var book = await lastBook()
        if book?.isFinished == true || book?.hideFromContinue == true || book?.serverReadStatus == "READ" { book = nil }
        if book == nil { book = await books.continueReadingBooks(limit: 1).first }
        guard isAllowed() else { throw EbookSystemError.unavailable }
        guard let book else { throw EbookSystemError.nothingToContinue }
        try await requestOpen(book.stableId)
    }

    func resolve(_ request: Request) async -> Book? {
        guard isAllowed(), pendingRequest?.id == request.id else { return nil }
        let book = await books.visibleEbook(stableId: request.bookID)
        guard isAllowed(), pendingRequest?.id == request.id else { return nil }
        return book
    }

    func finish(_ request: Request) {
        if pendingRequest?.id == request.id { pendingRequest = nil }
    }

    func revoke() { pendingRequest = nil }

    private func lastBook() async -> Book? {
        guard let id = lastOpened.stableId else { return nil }
        return await books.visibleEbook(stableId: id)
    }

    private func descriptors(_ candidates: [Book]) -> [SystemEbook] {
        var seen = Set<String>()
        return candidates.filter { $0.mediaType == .ebook && seen.insert($0.stableId).inserted }.map(SystemEbook.init)
    }
}
