import Foundation
import Observation

@MainActor
@Observable
final class AdminStorytellerModel {
    let connection: ServerConnection

    var currentUser: StorytellerUser?
    var shelves: [StorytellerShelf] = []
    var alignmentFacets: StorytellerAlignmentFacets?
    var processingBooks: [StorytellerProcessingBook] = []
    var canListBooks = false
    var canProcessBooks = false
    var shelvesSupported = true
    var isLoading = false
    var isRefreshingProcessing = false
    var hasLoaded = false
    var processingBookId: String?
    var error: String?
    var successMessage: String?

    init(connection: ServerConnection) {
        self.connection = connection
    }

    private var provider: StorytellerProvider? {
        AppState.shared.getProvider(connection.id) as? StorytellerProvider
    }

    func refreshAll() async {
        guard !isLoading else { return }
        guard let provider else {
            error = "This source has no live connection. Open it from its source page first."
            hasLoaded = true
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            currentUser = try await provider.fetchCurrentUser()
            let permissions = try await provider.fetchManagementPermissions()
            canListBooks = permissions.canListBooks
            canProcessBooks = permissions.canProcessBooks
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
            hasLoaded = true
            return
        }

        if !canListBooks { shelves = [] }
        if !canProcessBooks {
            processingBooks = []
            alignmentFacets = nil
        }

        if canListBooks {
            do {
                shelves = try await provider.fetchStorytellerShelves()
                shelvesSupported = true
            } catch StorytellerManagementError.unavailable {
                shelvesSupported = false
                shelves = []
            } catch StorytellerManagementError.forbidden {
                canListBooks = false
                shelves = []
            } catch {
                guard !isStorytellerCancellation(error) else { return }
                self.error = error.localizedDescription
            }
        }

        if canProcessBooks {
            do {
                processingBooks = try await provider.fetchStorytellerProcessingBooks()
            } catch StorytellerManagementError.forbidden {
                canProcessBooks = false
                processingBooks = []
            } catch {
                guard !isStorytellerCancellation(error) else { return }
                self.error = error.localizedDescription
            }

            if canProcessBooks {
                do {
                    alignmentFacets = try await provider.fetchStorytellerAlignmentFacets()
                } catch StorytellerManagementError.unavailable {
                    alignmentFacets = nil
                } catch StorytellerManagementError.forbidden {
                    canProcessBooks = false
                    processingBooks = []
                } catch {
                    guard !isStorytellerCancellation(error) else { return }
                    self.error = error.localizedDescription
                }
            }
        }
        hasLoaded = true
    }

    func createShelf(name: String) async {
        guard let provider else { return }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        do {
            let shelf = try await provider.createStorytellerShelf(name: normalized)
            shelves.append(shelf)
            shelves.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            successMessage = "“\(normalized)” is ready."
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }

    func renameShelf(_ shelf: StorytellerShelf, name: String) async {
        guard let provider else { return }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        do {
            let updated = try await provider.renameStorytellerShelf(shelf, name: normalized)
            if let index = shelves.firstIndex(where: { $0.id == shelf.id }) {
                shelves[index] = updated
            }
            shelves.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            successMessage = "The shelf was renamed."
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }

    func deleteShelf(_ shelf: StorytellerShelf) async {
        guard let provider else { return }
        do {
            try await provider.deleteStorytellerShelf(shelf)
            shelves.removeAll { $0.id == shelf.id }
            successMessage = "“\(shelf.name)” was removed."
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }

    func applyShelf(_ shelf: StorytellerShelf) {
        if let index = shelves.firstIndex(where: { $0.id == shelf.id }) {
            shelves[index] = shelf
        }
        shelves.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func startAlignment(
        for book: StorytellerProcessingBook,
        restart: StorytellerAlignmentRestartMode
    ) async {
        guard processingBookId == nil, let provider else { return }
        processingBookId = book.id
        defer { processingBookId = nil }
        do {
            try await provider.startStorytellerAlignment(bookId: book.id, restart: restart)
            successMessage = restart == .continueExisting
                ? "Alignment started for “\(book.title)”."
                : "Alignment restart queued for “\(book.title)”."
            try? await Task.sleep(for: .seconds(1))
            await refreshProcessing()
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }

    func cancelAlignment(for book: StorytellerProcessingBook) async {
        guard processingBookId == nil, let provider else { return }
        processingBookId = book.id
        defer { processingBookId = nil }
        do {
            try await provider.cancelStorytellerAlignment(bookId: book.id)
            successMessage = "Alignment was cancelled for “\(book.title)”."
            try? await Task.sleep(for: .seconds(1))
            await refreshProcessing()
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }

    func refreshProcessing() async {
        guard !isLoading, !isRefreshingProcessing, let provider else { return }
        isRefreshingProcessing = true
        defer { isRefreshingProcessing = false }
        do {
            processingBooks = try await provider.fetchStorytellerProcessingBooks()
        } catch StorytellerManagementError.forbidden {
            canProcessBooks = false
            processingBooks = []
            alignmentFacets = nil
            return
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        do {
            alignmentFacets = try await provider.fetchStorytellerAlignmentFacets()
        } catch StorytellerManagementError.unavailable {
            alignmentFacets = nil
        } catch StorytellerManagementError.forbidden {
            canProcessBooks = false
            processingBooks = []
            alignmentFacets = nil
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class AdminStorytellerShelfMembershipModel {
    let shelf: StorytellerShelf

    var books: [StorytellerManagementBook] = []
    var orderedBookIds: [String]
    var baselineBookIds: [String]
    var isLoading = false
    var isSaving = false
    var hasLoaded = false
    var error: String?
    var successMessage: String?

    init(shelf: StorytellerShelf) {
        self.shelf = shelf
        let ids = shelf.books.map(\.bookUuid)
        orderedBookIds = ids
        baselineBookIds = ids
    }

    var hasChanges: Bool {
        orderedBookIds != baselineBookIds
    }

    func book(for id: String) -> StorytellerManagementBook? {
        books.first { $0.id == id }
    }

    func load(connection: ServerConnection) async {
        guard !isLoading, !hasLoaded else { return }
        guard let provider = AppState.shared.getProvider(connection.id) as? StorytellerProvider else {
            error = "This source has no live connection."
            hasLoaded = true
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            books = try await provider.fetchStorytellerManagementBooks()
            hasLoaded = true
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
            hasLoaded = true
        }
    }

    func add(_ book: StorytellerManagementBook) {
        guard !orderedBookIds.contains(book.id) else { return }
        orderedBookIds.append(book.id)
    }

    func remove(bookId: String) {
        orderedBookIds.removeAll { $0 == bookId }
    }

    func move(bookId: String, offset: Int) {
        guard let index = orderedBookIds.firstIndex(of: bookId) else { return }
        let destination = index + offset
        guard orderedBookIds.indices.contains(destination) else { return }
        orderedBookIds.swapAt(index, destination)
    }

    func save(connection: ServerConnection, parent: AdminStorytellerModel) async {
        guard hasChanges, !isSaving else { return }
        guard let provider = AppState.shared.getProvider(connection.id) as? StorytellerProvider else {
            error = "This source has no live connection."
            return
        }
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            let updated = try await provider.updateStorytellerShelfBooks(shelf, bookIds: orderedBookIds)
            orderedBookIds = updated.books.map(\.bookUuid)
            baselineBookIds = orderedBookIds
            parent.applyShelf(updated)
            successMessage = "Shelf books saved."
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
@Observable
final class AdminStorytellerReportModel {
    var report: StorytellerAlignmentReport?
    var isLoading = false
    var hasLoaded = false
    var error: String?

    func load(connection: ServerConnection, bookId: String) async {
        guard let provider = AppState.shared.getProvider(connection.id) as? StorytellerProvider else {
            error = "This source has no live connection."
            hasLoaded = true
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            report = try await provider.fetchStorytellerAlignmentReport(bookId: bookId)
        } catch {
            guard !isStorytellerCancellation(error) else { return }
            self.error = error.localizedDescription
        }
        hasLoaded = true
    }
}

private func isStorytellerCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}
