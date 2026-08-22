import Combine
import Foundation
import Logging

@MainActor
final class OPDSBulkImportService: ObservableObject {

    struct ImportItem: Identifiable {
        let book: Book
        var status: Status

        var id: String { book.id }

        enum Status: Equatable {
            case pending
            case downloading(progress: Double)
            case completed
            case failed(message: String)
        }
    }

    @Published private(set) var items: [ImportItem] = []
    @Published private(set) var isRunning = false
    @Published private(set) var lastSummary: String?

    private let maxConcurrent: Int

    init(maxConcurrent: Int = 3) {
        self.maxConcurrent = maxConcurrent
    }

    func loadCatalog(connection: ServerConnection) async {
        guard let provider = PluginRegistry.shared.makeLibraryProvider(for: connection) as? OPDSProvider else {
            items = []
            return
        }
        do {
            let books = try await provider.fetchBooks(libraryId: "opds-root")
            items = books.map { ImportItem(book: $0, status: .pending) }
        } catch {
            AppLogger.network.warning("OPDS bulk-import: catalog fetch failed - \(error.localizedDescription)")
            items = []
        }
    }

    func importSelected(
        selectedIDs: Set<String>,
        from connection: ServerConnection,
        collectionName: String,
    ) async {
        guard let provider = PluginRegistry.shared.makeLibraryProvider(for: connection) as? OPDSProvider else {
            lastSummary = "Couldn't open OPDS connection."
            return
        }
        let targets = items.filter { selectedIDs.contains($0.book.id) }
        guard !targets.isEmpty else { return }

        isRunning = true
        defer { isRunning = false }

        let progressCallback: @Sendable (String, Double) -> Void = { [weak self] bookId, progress in
            Task { @MainActor [weak self] in
                self?.setStatus(id: bookId, .downloading(progress: progress))
            }
        }

        let completedIDs = await withTaskGroup(of: TaskResult.self, returning: [String].self) { group in
            var iterator = targets.makeIterator()
            var inFlight = 0
            var done: [String] = []

            while inFlight < maxConcurrent, let item = iterator.next() {
                let bookId = item.book.id
                let book = item.book
                inFlight += 1
                setStatus(id: bookId, .downloading(progress: 0))
                group.addTask {
                    do {
                        _ = try await provider.downloadEbook(for: book) { progress in
                            progressCallback(bookId, progress)
                        }
                        return TaskResult(bookId: bookId, success: true, failureMessage: nil)
                    } catch {
                        return TaskResult(bookId: bookId, success: false, failureMessage: error.localizedDescription)
                    }
                }
            }

            for await result in group {
                inFlight -= 1
                if result.success {
                    setStatus(id: result.bookId, .completed)
                    done.append(result.bookId)
                } else {
                    setStatus(id: result.bookId, .failed(message: result.failureMessage ?? "Failed"))
                }

                if let next = iterator.next() {
                    let bookId = next.book.id
                    let book = next.book
                    inFlight += 1
                    setStatus(id: bookId, .downloading(progress: 0))
                    group.addTask {
                        do {
                            _ = try await provider.downloadEbook(for: book) { progress in
                                progressCallback(bookId, progress)
                            }
                            return TaskResult(bookId: bookId, success: true, failureMessage: nil)
                        } catch {
                            return TaskResult(bookId: bookId, success: false, failureMessage: error.localizedDescription)
                        }
                    }
                }
            }
            return done
        }

        if !completedIDs.isEmpty {
            createCollection(name: collectionName, bookIDs: completedIDs)
        }
        lastSummary = "Imported \(completedIDs.count) of \(targets.count) books."
    }

    private func setStatus(id: String, _ status: ImportItem.Status) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
    }

    private struct TaskResult: Sendable {
        let bookId: String
        let success: Bool
        let failureMessage: String?
    }

    private func createCollection(name: String, bookIDs: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = trimmed.isEmpty ? "OPDS Import" : trimmed
        let collection = Collection(
            id: UUID().uuidString,
            name: display,
            description: "Imported from OPDS",
            books: bookIDs,
            bookCount: bookIDs.count,
            iconName: "books.vertical.fill",
            color: "orange",
            providerId: nil,
            parentID: nil,
            customCoverPath: nil,
            isSystem: false,
            isUserGenerated: true,
        )
        UserCollectionStore.shared.save(collection)
    }
}
