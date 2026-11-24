import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func allBooks() async -> [Book] {
        await read("allBooks", fallback: []) { try await $0.fetchAllBooks() }
    }

    func rediscoverCandidates(after cursor: String?, limit: Int) async -> [RediscoverPolicy.Candidate] {
        await read("rediscoverCandidates", fallback: []) {
            try await $0.fetchRediscoverCandidates(after: cursor, limit: limit)
        }
    }

    func activeBooks(excludingSource: String, minProgressThreshold: Double) async -> [Book] {
        await read("activeBooks", fallback: []) {
            try await $0.fetchActiveBooks(excludingSource: excludingSource, minProgress: minProgressThreshold)
        }
    }

    func firstBooks(libraryId: String, providerId: UUID, limit: Int) async -> [Book] {
        await read("books(library)", fallback: []) {
            try await $0.fetchFirstBooksForLibrary(libraryId: libraryId, providerId: providerId.uuidString, limit: limit)
        }
    }

    func firstBooks(mediaType: String, limit: Int) async -> [Book] {
        await read("firstBooks(mediaType:)", fallback: []) {
            try await $0.fetchFirstBooksByMediaType(mediaType: mediaType, limit: limit)
        }
    }

    func firstBooks(source: String, mediaType: String, limit: Int) async -> [Book] {
        await read("firstBooks(source:mediaType:)", fallback: []) {
            try await $0.fetchFirstBooksBySource(source: source, mediaType: mediaType, limit: limit)
        }
    }

    func books(source: String, providerId: UUID) async -> [Book] {
        await read("books(source:providerId:)", fallback: []) {
            try await $0.fetchBooks(source: source, providerIdString: providerId.uuidString)
        }
    }

    func books(source: String, providerId: UUID, mediaType: String) async -> [Book] {
        await read("books(source:providerId:mediaType:)", fallback: []) {
            try await $0.fetchBooks(source: source, providerIdString: providerId.uuidString, mediaType: mediaType)
        }
    }

    func books(backendId: String, source: String?) async -> [Book] {
        await read("books(backendId:source:)", fallback: []) {
            try await $0.fetchBooks(backendId: backendId, source: source)
        }
    }

    func firstBooksWithReadAloudSource(limit: Int) async -> [Book] {
        await read("firstBooksWithReadAloudSource", fallback: []) {
            try await $0.fetchFirstBooksWithReadAloudSource(limit: limit)
        }
    }

    func firstBooksWithoutReadAloudSource(limit: Int) async -> [Book] {
        await read("firstBooksWithoutReadAloudSource", fallback: []) {
            try await $0.fetchFirstBooksWithoutReadAloudSource(limit: limit)
        }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchAllBooks() throws -> [Book] {
        let pageSize = 1000
        var books: [Book] = []
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate { !$0.isDeleted },
                sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
            )
            descriptor.fetchLimit = pageSize
            descriptor.fetchOffset = offset
            let page = try modelContext.fetch(descriptor)
            if page.isEmpty { break }
            books.append(contentsOf: page.compactMap { $0.toBook() })
            if page.count < pageSize { break }
            offset += pageSize
        }
        if books.count > 5000 {
            AppLogger.general.warning(
                "BookStore.fetchAllBooks materialized \(books.count) books; caller should migrate to fetchPaged or a projection for memory safety"
            )
        }
        return books
    }

    func fetchRediscoverCandidates(after cursor: String?, limit: Int) throws -> [RediscoverPolicy.Candidate] {
        let lowerBound = cursor ?? ""
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { !$0.isDeleted && $0.uniqueId > lowerBound },
            sortBy: [SortDescriptor(\.uniqueId)]
        )
        descriptor.fetchLimit = limit
        return try autoreleasepool {
            try modelContext.fetch(descriptor).compactMap { record in
                record.toBook().map { RediscoverPolicy.Candidate($0, workKey: record.workKey) }
            }
        }
    }

    func fetchActiveBooks(excludingSource: String, minProgress: Double) throws -> [Book] {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in !record.isDeleted },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        let result = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        AppLogger.general.info("BookStore.activeBooks: \(result.count) books loaded from cache")
        return result
    }

    func fetchFirstBooksForLibrary(libraryId: String, providerId: String, limit: Int) throws -> [Book] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.libraryId == libraryId && $0.providerId == providerId && !$0.isDeleted
            },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let books = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        if books.count == limit {
            AppLogger.general.warning(
                "BookStore.firstBooksForLibrary returned exactly limit=\(limit) - more rows likely exist; caller should paginate"
            )
        }
        return books
    }

    func fetchFirstBooksByMediaType(mediaType: String, limit: Int) throws -> [Book] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == mediaType && !$0.isDeleted && !$0.isHidden
            },
            sortBy: [SortDescriptor(\.title)]
        )
        descriptor.fetchLimit = limit
        let books = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        if books.count == limit {
            AppLogger.general.warning(
                "BookStore.firstBooks(mediaType:\(mediaType)) returned exactly limit=\(limit) - more rows likely exist; caller should paginate"
            )
        }
        return books
    }

    func fetchFirstBooksBySource(source: String, mediaType: String, limit: Int) throws -> [Book] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.source == source && $0.mediaType == mediaType && !$0.isDeleted
            },
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let books = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        if books.count == limit {
            AppLogger.general.warning(
                "BookStore.firstBooks(source:\(source),mediaType:\(mediaType)) returned exactly limit=\(limit) - more rows likely exist; caller should paginate"
            )
        }
        return books
    }

    func fetchBooks(source src: String, providerIdString pid: String) throws -> [Book] {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.source == src && $0.providerId == pid && !$0.isDeleted && !$0.isHidden
            },
            sortBy: [SortDescriptor(\.title)]
        )
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchBooks(source src: String, providerIdString pid: String, mediaType mt: String) throws -> [Book] {
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.source == src && $0.providerId == pid && $0.mediaType == mt
                    && !$0.isDeleted && !$0.isHidden
            },
            sortBy: [SortDescriptor(\.title)]
        )
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchBooks(backendId bid: String, source src: String?) throws -> [Book] {
        let descriptor: FetchDescriptor<BookRecord>
        if let src {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.backendId == bid && $0.source == src && !$0.isDeleted && !$0.isHidden
                },
                sortBy: [SortDescriptor(\.title)]
            )
        } else {
            descriptor = FetchDescriptor<BookRecord>(
                predicate: #Predicate {
                    $0.backendId == bid && !$0.isDeleted && !$0.isHidden
                },
                sortBy: [SortDescriptor(\.title)]
            )
        }
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchFirstBooksWithReadAloudSource(limit: Int) throws -> [Book] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.readAloudSourceStableId != nil && !$0.isDeleted && !$0.isHidden
            },
            sortBy: [SortDescriptor(\.title)]
        )
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchFirstBooksWithoutReadAloudSource(limit: Int) throws -> [Book] {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.readAloudSourceStableId == nil && !$0.isDeleted && !$0.isHidden
            },
            sortBy: [SortDescriptor(\.title)]
        )
        descriptor.fetchLimit = limit
        let books = try modelContext.fetch(descriptor).compactMap { $0.toBook() }
        if books.count == limit {
            AppLogger.general.warning(
                "BookStore.firstBooksWithoutReadAloudSource returned exactly limit=\(limit) - more rows likely exist"
            )
        }
        return books
    }
}
