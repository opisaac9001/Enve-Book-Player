import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func upsertLink(ebookStableId: String, audiobookStableId: String, chapterOffset: Int) async {
        guard !ebookStableId.isEmpty, !audiobookStableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertLink: rejecting empty ebookStableId or audiobookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertLinkRecord(
                ebookStableId: ebookStableId,
                audiobookStableId: audiobookStableId,
                chapterOffset: chapterOffset
            )
        } catch {
            AppLogger.general.error("BookStore.upsertLink failed: \(error)")
        }
    }

    func removeLink(ebookStableId: String) async {
        guard !ebookStableId.isEmpty else { return }
        let worker = makeWorker()
        do {
            try await worker.removeLinkRecord(ebookStableId: ebookStableId)
        } catch {
            AppLogger.general.error("BookStore.removeLink failed: \(error)")
        }
    }

    func linkedAudiobookStableId(forEbookStableId eid: String) async -> String? {
        await read("linkedAudiobook", fallback: nil) {
            try await $0.fetchLinkedAudiobookStableId(forEbookStableId: eid)
        }
    }

    func linkedEbookStableId(forAudiobookStableId aid: String) async -> String? {
        await read("linkedEbook", fallback: nil) {
            try await $0.fetchLinkedEbookStableId(forAudiobookStableId: aid)
        }
    }

    func allLinks() async -> [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)] {
        await read("allLinks", fallback: []) { try await $0.fetchAllLinks() }
    }

    func importLegacyLinks(_ links: [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)]) async {
        let worker = makeWorker()
        do {
            try await worker.importLinks(links)
            AppLogger.general.info("BookStore: imported \(links.count) legacy links")
        } catch {
            AppLogger.general.error("BookStore.importLegacyLinks failed: \(error)")
        }
    }

    func ebookLinkedAudiobookIds(source: String) async -> [(ebookStableId: String, audiobookStableId: String)] {
        await read("ebookLinkedAudiobookIds", fallback: []) {
            try await $0.fetchEbookLinkedAudiobookIds(source: source)
        }
    }

    func existingAudiobookStableIds(from candidates: Set<String>) async -> Set<String> {
        await read("existingAudiobookStableIds", fallback: []) {
            try await $0.fetchExistingAudiobookStableIds(from: candidates)
        }
    }

    func absorbedStableIds() async -> Set<String> {
        await read("absorbedStableIds", fallback: []) { try await $0.fetchAbsorbedStableIds() }
    }

    func referencedAudiobookStableIds(among candidates: Set<String>) async -> Set<String> {
        do {
            return try await makeWorker().fetchReferencedAudiobookStableIds(among: candidates)
        } catch {
            AppLogger.general.error("BookStore.referencedAudiobookStableIds failed: \(error)")
            // Unknown links count as in use, so nothing linked is removed.
            return candidates
        }
    }
}

extension SwiftDataBookStore.Worker {
    func upsertLinkRecord(ebookStableId: String, audiobookStableId: String, chapterOffset: Int) throws {
        let eid = ebookStableId
        var descriptor = FetchDescriptor<LinkedBookPairRecord>(
            predicate: #Predicate { $0.ebookStableId == eid }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.audiobookStableId = audiobookStableId
            existing.chapterOffset = chapterOffset
            existing.lastUpdate = Date()
        } else {
            modelContext.insert(
                LinkedBookPairRecord(
                    ebookStableId: ebookStableId,
                    audiobookStableId: audiobookStableId,
                    chapterOffset: chapterOffset
                )
            )
        }
        try modelContext.save()
    }

    func removeLinkRecord(ebookStableId eid: String) throws {
        let descriptor = FetchDescriptor<LinkedBookPairRecord>(
            predicate: #Predicate { $0.ebookStableId == eid }
        )
        for record in try modelContext.fetch(descriptor) {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    func fetchLinkedAudiobookStableId(forEbookStableId eid: String) throws -> String? {
        var descriptor = FetchDescriptor<LinkedBookPairRecord>(
            predicate: #Predicate { $0.ebookStableId == eid }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.audiobookStableId
    }

    func fetchLinkedEbookStableId(forAudiobookStableId aid: String) throws -> String? {
        var descriptor = FetchDescriptor<LinkedBookPairRecord>(
            predicate: #Predicate { $0.audiobookStableId == aid }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.ebookStableId
    }

    func fetchAllLinks() throws -> [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)] {
        let descriptor = FetchDescriptor<LinkedBookPairRecord>()
        return try modelContext.fetch(descriptor).map {
            (ebookStableId: $0.ebookStableId, audiobookStableId: $0.audiobookStableId, chapterOffset: $0.chapterOffset)
        }
    }

    func importLinks(_ links: [(ebookStableId: String, audiobookStableId: String, chapterOffset: Int)]) throws {
        for link in links {
            let eid = link.ebookStableId
            var descriptor = FetchDescriptor<LinkedBookPairRecord>(
                predicate: #Predicate { $0.ebookStableId == eid }
            )
            descriptor.fetchLimit = 1
            if try modelContext.fetch(descriptor).first == nil {
                modelContext.insert(
                    LinkedBookPairRecord(
                        ebookStableId: link.ebookStableId,
                        audiobookStableId: link.audiobookStableId,
                        chapterOffset: link.chapterOffset
                    )
                )
            }
        }
        try modelContext.save()
    }

    func fetchAbsorbedStableIds() throws -> Set<String> {
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate { $0.readAloudSourceStableId != nil && !$0.isDeleted }
        )
        descriptor.propertiesToFetch = [\BookRecord.readAloudSourceStableId, \BookRecord.linkedAudiobookStableId]
        var ids = Set<String>()
        for record in try modelContext.fetch(descriptor) {
            if let s = record.readAloudSourceStableId, !s.isEmpty { ids.insert(s) }
            if let a = record.linkedAudiobookStableId, !a.isEmpty { ids.insert(a) }
        }
        return ids
    }

    func fetchEbookLinkedAudiobookIds(source sourceValue: String) throws -> [(ebookStableId: String, audiobookStableId: String)] {
        let ebookType = AppMediaType.ebook.rawValue
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.source == sourceValue && $0.mediaType == ebookType && !$0.isDeleted
                    && $0.linkedAudiobookStableId != nil
            }
        )
        descriptor.propertiesToFetch = [\BookRecord.stableId, \BookRecord.linkedAudiobookStableId]
        return try modelContext.fetch(descriptor).compactMap { record -> (ebookStableId: String, audiobookStableId: String)? in
            guard let linked = record.linkedAudiobookStableId, !linked.isEmpty else { return nil }
            return (ebookStableId: record.stableId, audiobookStableId: linked)
        }
    }

    func fetchExistingAudiobookStableIds(from candidates: Set<String>) throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        let audioType = "audiobook"
        var descriptor = FetchDescriptor<BookRecord>(
            predicate: #Predicate {
                $0.mediaType == audioType && !$0.isDeleted && candidates.contains($0.stableId)
            }
        )
        descriptor.propertiesToFetch = [\BookRecord.stableId]
        return Set(try modelContext.fetch(descriptor).map { $0.stableId })
    }

    func fetchReferencedAudiobookStableIds(among candidates: Set<String>) throws -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        var books = FetchDescriptor<BookRecord>(
            predicate: #Predicate { !$0.isDeleted && ($0.linkedAudiobookStableId != nil || $0.readAloudSourceStableId != nil) }
        )
        books.propertiesToFetch = [\BookRecord.linkedAudiobookStableId, \BookRecord.readAloudSourceStableId]
        var referenced = Set<String>()
        for record in try modelContext.fetch(books) {
            if let linked = record.linkedAudiobookStableId { referenced.insert(linked) }
            if let source = record.readAloudSourceStableId { referenced.insert(source) }
        }
        var links = FetchDescriptor<LinkedBookPairRecord>()
        links.propertiesToFetch = [\LinkedBookPairRecord.audiobookStableId]
        referenced.formUnion(try modelContext.fetch(links).map(\.audiobookStableId))
        return referenced.intersection(candidates)
    }
}
