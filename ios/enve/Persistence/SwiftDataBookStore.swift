import Foundation
import Logging
import SwiftData

final class SwiftDataBookStore: BookStoreRepository, @unchecked Sendable {
    private let container: ModelContainer
    let ebookImporter: LocalEbookImporter

    init(container: ModelContainer, ebookImporter: LocalEbookImporter = .shared) {
        self.container = container
        self.ebookImporter = ebookImporter
    }

    @ModelActor
    actor Worker {
        func deduplicatedBooks(_ books: [Book]) -> [Book] {
            var indexByUniqueId: [String: Int] = [:]
            var result: [Book] = []
            result.reserveCapacity(books.count)

            for book in books {
                if let index = indexByUniqueId[book.uniqueId] {
                    result[index] = book
                } else {
                    indexByUniqueId[book.uniqueId] = result.count
                    result.append(book)
                }
            }

            if result.count != books.count {
                AppLogger.general.warning("BookStore deduplicated \(books.count - result.count) repeated uniqueId value(s) before saving")
            }
            return result
        }

        func fetchBooksWithIds(_ ids: [String]) throws -> [Book] {
            guard !ids.isEmpty else { return [] }
            let idSet = Set(ids)
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { record in
                    !record.isDeleted && (idSet.contains(record.bookId) || idSet.contains(record.stableId))
                }
            )
            return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        }

        func fetchBookByUniqueId(_ uid: String) throws -> Book? {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.uniqueId == uid }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.toBook()
        }

        func fetchBookByStableId(_ sid: String) throws -> Book? {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.stableId == sid && !$0.isDeleted }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.toBook()
        }

        func fetchVisibleEbook(stableId: String) throws -> Book? {
            var descriptor = FetchDescriptor<BookRecord>(predicate: #Predicate {
                $0.stableId == stableId && $0.mediaType == "ebook" && !$0.isDeleted && !$0.isHidden
            })
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first?.toBook()
        }

        func fetchBooksByIds(ids: Set<String>) throws -> [String: Book] {
            guard !ids.isEmpty else { return [:] }
            let safeIds = ids.filter { !$0.isEmpty }
            guard !safeIds.isEmpty else { return [:] }

            let bookIdDescriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { safeIds.contains($0.bookId) }
            )
            var lookup = [String: Book](minimumCapacity: safeIds.count * 2)
            for record in try modelContext.fetch(bookIdDescriptor) {
                guard let book = record.toBook() else { continue }
                lookup[record.bookId] = book
            }
            for id in safeIds {
                if lookup.keys.contains(id) { continue }
                let lookupId = id
                var d = FetchDescriptor<BookRecord>(
                    predicate: #Predicate { $0.partKey == lookupId }
                )
                d.fetchLimit = 1
                if let record = try modelContext.fetch(d).first, let book = record.toBook() {
                    lookup[id] = book
                }
            }
            return lookup
        }

        func fetchBooksByUniqueIds(ids: Set<String>) throws -> [String: Book] {
            guard !ids.isEmpty else { return [:] }
            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { ids.contains($0.uniqueId) }
            )
            var lookup = [String: Book](minimumCapacity: ids.count)
            for record in try modelContext.fetch(descriptor) {
                guard let book = record.toBook() else { continue }
                lookup[record.uniqueId] = book
            }
            return lookup
        }

        func fetchBooksByStableIds(ids: Set<String>) throws -> [String: Book] {
            guard !ids.isEmpty else { return [:] }
            let safeIds = ids.filter { !$0.isEmpty }
            guard !safeIds.isEmpty else { return [:] }

            let descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.stableId) }
            )
            var lookup = [String: Book](minimumCapacity: safeIds.count)
            for record in try modelContext.fetch(descriptor) {
                guard let book = record.toBook() else { continue }
                lookup[record.stableId] = book
            }
            return lookup
        }

        func fetchBooksByAnyIds(ids: Set<String>) throws -> [String: Book] {
            guard !ids.isEmpty else { return [:] }
            let safeIds = ids.filter { !$0.isEmpty }
            guard !safeIds.isEmpty else { return [:] }

            let descriptors = [
                FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.bookId) }
                ),
                FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.stableId) }
                ),
                FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.uniqueId) }
                ),
                FetchDescriptor<BookRecord>(
                    predicate: #Predicate { !$0.isDeleted && safeIds.contains($0.ratingKey) }
                ),
            ]
            var lookup = [String: Book](minimumCapacity: safeIds.count)
            for descriptor in descriptors {
                for record in try modelContext.fetch(descriptor) {
                    guard let book = record.toBook() else { continue }
                    if safeIds.contains(record.bookId) { lookup[record.bookId] = book }
                    if safeIds.contains(record.stableId) { lookup[record.stableId] = book }
                    if safeIds.contains(record.uniqueId) { lookup[record.uniqueId] = book }
                    if safeIds.contains(record.ratingKey) { lookup[record.ratingKey] = book }
                }
            }
            return lookup
        }

        func fetchBook(byBookId id: String) throws -> Book? {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { $0.bookId == id }
            )
            descriptor.fetchLimit = 1
            return try modelContext.fetch(descriptor).first.flatMap { $0.toBook() }
        }
    }

    func read<Value>(_ operation: String, fallback: Value, _ fetch: (Worker) async throws -> Value) async -> Value {
        do {
            return try await fetch(makeWorker())
        } catch {
            AppLogger.general.error("BookStore.\(operation) failed: \(error)")
            return fallback
        }
    }

    func makeWorker() -> Worker {
        Worker(modelContainer: container)
    }

    // ModelActor binds its context to the queue where it is initialized.
    func makeBackgroundWorker() async -> Worker {
        let container = container
        return await Task.detached { Worker(modelContainer: container) }.value
    }

    var persistentStoreURL: URL? {
        container.configurations.first(where: { !$0.isStoredInMemoryOnly })?.url
    }

    func book(byBookId id: String) async -> Book? {
        await read("book(byBookId:)", fallback: nil) { try await $0.fetchBook(byBookId: id) }
    }

    func book(byAnyId id: String) async -> Book? {
        if let b = await book(uniqueId: id) { return b }
        if let b = await book(stableId: id) { return b }
        return await book(byBookId: id)
    }

    func books(withIds ids: [String]) async -> [Book] {
        await read("books(withIds:)", fallback: []) { try await $0.fetchBooksWithIds(ids) }
    }

    func book(uniqueId: String) async -> Book? {
        await read("book(uniqueId)", fallback: nil) { try await $0.fetchBookByUniqueId(uniqueId) }
    }

    func book(stableId: String) async -> Book? {
        await read("book(stableId)", fallback: nil) { try await $0.fetchBookByStableId(stableId) }
    }

    func visibleEbook(stableId: String) async -> Book? {
        do { return try await makeWorker().fetchVisibleEbook(stableId: stableId) }
        catch {
            AppLogger.general.error("BookStore.visibleEbook failed")
            return nil
        }
    }

    func booksByIds(_ ids: Set<String>) async -> [String: Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByIds(ids: ids)
        } catch {
            AppLogger.general.error("BookStore.booksByIds failed: \(error)")
            return [:]
        }
    }

    func booksByUniqueIds(_ ids: Set<String>) async -> [String: Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByUniqueIds(ids: ids)
        } catch {
            AppLogger.general.error("BookStore.booksByUniqueIds failed: \(error)")
            return [:]
        }
    }

    func booksByAnyIds(_ ids: Set<String>) async -> [String: Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByAnyIds(ids: ids)
        } catch {
            AppLogger.general.error("BookStore.booksByAnyIds failed: \(error)")
            return [:]
        }
    }

    func booksByStableIds(_ ids: Set<String>) async -> [String: Book] {
        let worker = makeWorker()
        do {
            return try await worker.fetchBooksByStableIds(ids: ids)
        } catch {
            AppLogger.general.error("BookStore.booksByStableIds failed: \(error)")
            return [:]
        }
    }
}
