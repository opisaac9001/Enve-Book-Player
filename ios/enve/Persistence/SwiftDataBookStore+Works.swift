import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func books(workKey key: String) async -> [Book] {
        guard !key.isEmpty else { return [] }
        return await read("books(workKey:)", fallback: []) { try await $0.fetchBooksByWorkKey(key) }
    }

    func books(editionKey key: String) async -> [Book] {
        guard !key.isEmpty else { return [] }
        return await read("books(editionKey:)", fallback: []) { try await $0.fetchBooksByEditionKey(key) }
    }

    func booksWithIdentifiers(limit: Int) async -> [Book] {
        await read("booksWithIdentifiers", fallback: []) { try await $0.fetchBooksWithIdentifiers(limit: limit) }
    }

    func workSlices() async -> [WorkSlice] {
        await read("workSlices", fallback: []) { try await $0.fetchWorkSlices() }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchBooksByWorkKey(_ key: String) throws -> [Book] {
        guard !key.isEmpty else { return [] }
        try backfillWorkKeysIfNeeded()
        let localKey = key
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.workKey == localKey && !record.isDeleted
            },
            sortBy: [SortDescriptor(\.title)]
        )
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchBooksByEditionKey(_ key: String) throws -> [Book] {
        guard !key.isEmpty else { return [] }
        try backfillWorkKeysIfNeeded()
        let localKey = key
        let descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                record.editionKey == localKey && !record.isDeleted
            }
        )
        return try modelContext.fetch(descriptor).compactMap { $0.toBook() }
    }

    func fetchBooksWithIdentifiers(limit: Int) throws -> [Book] {
        try backfillWorkKeysIfNeeded()
        var d1 = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { $0.isbn != nil && !$0.isDeleted }
        )
        d1.fetchLimit = limit
        var d2 = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { $0.asin != nil && !$0.isDeleted }
        )
        d2.fetchLimit = limit
        var seen = Set<String>()
        var result: [Book] = []
        for record in try modelContext.fetch(d1) + (try modelContext.fetch(d2)) {
            let hasISBN = !(record.isbn ?? "").isEmpty
            let hasASIN = !(record.asin ?? "").isEmpty
            guard hasISBN || hasASIN, seen.insert(record.uniqueId).inserted,
                let book = record.toBook()
            else { continue }
            result.append(book)
        }
        return result
    }

    func fetchWorkSlices() throws -> [WorkSlice] {
        try backfillWorkKeysIfNeeded()
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate<BookRecord> { record in
                !record.isDeleted && !record.isHidden && record.workKey != ""
            }
        )
        descriptor.propertiesToFetch = [\.uniqueId, \.stableId, \.workKey, \.source, \.thumb, \.bookDescription]
        return try modelContext.fetch(descriptor).map { record in
            var score = 0
            if record.source == "local" { score += 4 }
            if record.thumb?.isEmpty == false { score += 2 }
            if record.bookDescription?.isEmpty == false { score += 1 }
            return WorkSlice(uniqueId: record.uniqueId, stableId: record.stableId, workKey: record.workKey, score: score)
        }
    }

    func backfillWorkKeysIfNeeded() throws {
        let flag = "imagine.workKeysBackfilled.v1"
        if UserDefaults.standard.bool(forKey: flag) { return }
        let pageSize = 2000
        var offset = 0
        while true {
            var d = FetchDescriptor<BookRecord>(sortBy: [SortDescriptor(\.uniqueId)])
            d.fetchLimit = pageSize
            d.fetchOffset = offset
            let page = try modelContext.fetch(d)
            if page.isEmpty { break }
            for r in page where r.workKey.isEmpty {
                guard let book = r.toBook() else { continue }
                r.workKey = WorkIdentity.workKey(for: book)
                r.editionKey = WorkIdentity.editionKey(for: book)
            }
            try modelContext.save()
            offset += page.count
            if page.count < pageSize { break }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }
}
