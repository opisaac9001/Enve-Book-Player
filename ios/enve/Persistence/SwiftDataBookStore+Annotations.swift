import Foundation
import Logging
import SwiftData

extension SwiftDataBookStore {
    func annotations(forBookStableId sid: String) async -> [ReaderAnnotation] {
        let worker = makeWorker()
        do {
            let snapshots = try await worker.fetchAnnotations(forBookStableId: sid)
            return snapshots.map { s in
                ReaderAnnotation(
                    id: s.id,
                    bookId: s.bookStableId,
                    locator: s.locator,
                    position: s.position,
                    text: s.text,
                    note: s.note,
                    colorHex: s.colorHex,
                    style: ReaderAnnotationStyle(rawValue: s.style) ?? .highlight,
                    chapterTitle: s.chapterTitle,
                    createdAt: s.createdAt,
                    updatedAt: s.updatedAt,
                    remoteID: s.remoteID,
                    isRemotePlaceholder: s.isRemotePlaceholder
                )
            }
        } catch {
            AppLogger.general.error("BookStore.annotations failed: \(error)")
            return []
        }
    }

    func upsertAnnotation(_ annotation: ReaderAnnotation, bookStableId: String) async {
        guard !annotation.id.isEmpty, !bookStableId.isEmpty else {
            AppLogger.general.error("BookStore.upsertAnnotation: rejecting empty annotation id or bookStableId")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.upsertAnnotationRecord(
                id: annotation.id,
                bookStableId: bookStableId,
                locator: annotation.locator,
                position: annotation.position,
                text: annotation.text,
                note: annotation.note,
                colorHex: annotation.colorHex,
                style: annotation.style.rawValue,
                chapterTitle: annotation.chapterTitle,
                createdAt: annotation.createdAt,
                updatedAt: annotation.updatedAt,
                remoteID: annotation.remoteID,
                isRemotePlaceholder: annotation.isRemotePlaceholder
            )
        } catch {
            AppLogger.general.error("BookStore.upsertAnnotation failed: \(error)")
        }
    }

    func deleteAnnotation(id: String) async {
        guard !id.isEmpty else {
            AppLogger.general.error("BookStore.deleteAnnotation: rejecting empty id")
            return
        }
        let worker = makeWorker()
        do {
            try await worker.deleteAnnotationRecord(id: id)
        } catch {
            AppLogger.general.error("BookStore.deleteAnnotation failed: \(error)")
        }
    }

    func replaceAnnotations(forBookStableId sid: String, annotations: [ReaderAnnotation]) async {
        guard !sid.isEmpty else {
            AppLogger.general.error("BookStore.replaceAnnotations: rejecting empty bookStableId")
            return
        }
        let validAnnotations = annotations.filter { !$0.id.isEmpty }
        if validAnnotations.count != annotations.count {
            AppLogger.general.error(
                "BookStore.replaceAnnotations: rejected \(annotations.count - validAnnotations.count) annotation(s) with empty id"
            )
        }
        let worker = makeWorker()
        do {
            let tuples = validAnnotations.map {
                (
                    id: $0.id, locator: $0.locator, position: $0.position, text: $0.text,
                    note: $0.note, colorHex: $0.colorHex, style: $0.style.rawValue,
                    chapterTitle: $0.chapterTitle, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                    remoteID: $0.remoteID, isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
            try await worker.replaceAnnotationRecords(forBookStableId: sid, annotations: tuples)
        } catch {
            AppLogger.general.error("BookStore.replaceAnnotations failed: \(error)")
        }
    }

    func importLegacyAnnotations(_ annotations: [ReaderAnnotation], bookStableId: String) async {
        let worker = makeWorker()
        do {
            let tuples = annotations.map {
                (
                    id: $0.id, locator: $0.locator, position: $0.position, text: $0.text,
                    note: $0.note, colorHex: $0.colorHex, style: $0.style.rawValue,
                    chapterTitle: $0.chapterTitle, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                    remoteID: $0.remoteID, isRemotePlaceholder: $0.isRemotePlaceholder
                )
            }
            try await worker.importAnnotationRecords(tuples, bookStableId: bookStableId)
            AppLogger.general.info("BookStore: imported \(annotations.count) legacy annotations for \(bookStableId)")
        } catch {
            AppLogger.general.error("BookStore.importLegacyAnnotations failed: \(error)")
        }
    }
}

extension SwiftDataBookStore.Worker {
    func fetchAnnotations(forBookStableId sid: String) throws -> [AnnotationSnapshot] {
        let descriptor = FetchDescriptor<AnnotationRecord>(
            predicate: #Predicate { $0.bookStableId == sid },
            sortBy: [SortDescriptor(\.position)]
        )
        return try modelContext.fetch(descriptor).map {
            AnnotationSnapshot(
                id: $0.id,
                bookStableId: $0.bookStableId,
                locator: $0.locator,
                position: $0.position,
                text: $0.text,
                note: $0.note,
                colorHex: $0.colorHex,
                style: $0.style,
                chapterTitle: $0.chapterTitle,
                createdAt: $0.createdAt,
                updatedAt: $0.updatedAt,
                remoteID: $0.remoteID,
                isRemotePlaceholder: $0.isRemotePlaceholder
            )
        }
    }

    func upsertAnnotationRecord(
        id: String,
        bookStableId: String,
        locator: String?,
        position: Double,
        text: String,
        note: String?,
        colorHex: String,
        style: String,
        chapterTitle: String?,
        createdAt: Date,
        updatedAt: Date,
        remoteID: Int?,
        isRemotePlaceholder: Bool
    ) throws {
        let aid = id
        var descriptor = FetchDescriptor<AnnotationRecord>(
            predicate: #Predicate { $0.id == aid }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.locator = locator
            existing.position = position
            existing.text = text
            existing.note = note
            existing.colorHex = colorHex
            existing.style = style
            existing.chapterTitle = chapterTitle
            existing.updatedAt = updatedAt
            existing.remoteID = remoteID
            existing.isRemotePlaceholder = isRemotePlaceholder
        } else {
            modelContext.insert(
                AnnotationRecord(
                    id: id,
                    bookStableId: bookStableId,
                    locator: locator,
                    position: position,
                    text: text,
                    note: note,
                    colorHex: colorHex,
                    style: style,
                    chapterTitle: chapterTitle,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    remoteID: remoteID,
                    isRemotePlaceholder: isRemotePlaceholder
                )
            )
        }
        try modelContext.save()
    }

    func deleteAnnotationRecord(id aid: String) throws {
        var descriptor = FetchDescriptor<AnnotationRecord>(
            predicate: #Predicate { $0.id == aid }
        )
        descriptor.fetchLimit = 1
        if let record = try modelContext.fetch(descriptor).first {
            modelContext.delete(record)
        }
        try modelContext.save()
    }

    func replaceAnnotationRecords(
        forBookStableId sid: String,
        annotations: [(
            id: String, locator: String?, position: Double,
            text: String, note: String?, colorHex: String,
            style: String, chapterTitle: String?,
            createdAt: Date, updatedAt: Date,
            remoteID: Int?, isRemotePlaceholder: Bool
        )]
    ) throws {
        let existing = FetchDescriptor<AnnotationRecord>(
            predicate: #Predicate { $0.bookStableId == sid }
        )
        for record in try modelContext.fetch(existing) {
            modelContext.delete(record)
        }
        for a in annotations {
            modelContext.insert(
                AnnotationRecord(
                    id: a.id,
                    bookStableId: sid,
                    locator: a.locator,
                    position: a.position,
                    text: a.text,
                    note: a.note,
                    colorHex: a.colorHex,
                    style: a.style,
                    chapterTitle: a.chapterTitle,
                    createdAt: a.createdAt,
                    updatedAt: a.updatedAt,
                    remoteID: a.remoteID,
                    isRemotePlaceholder: a.isRemotePlaceholder
                )
            )
        }
        try modelContext.save()
    }

    func importAnnotationRecords(
        _ annotations: [(
            id: String, locator: String?, position: Double,
            text: String, note: String?, colorHex: String,
            style: String, chapterTitle: String?,
            createdAt: Date, updatedAt: Date,
            remoteID: Int?, isRemotePlaceholder: Bool
        )],
        bookStableId: String
    ) throws {
        let existingDescriptor = FetchDescriptor<AnnotationRecord>(
            predicate: #Predicate { $0.bookStableId == bookStableId }
        )
        let existingIds = Set(try modelContext.fetch(existingDescriptor).map { $0.id })
        for a in annotations where !existingIds.contains(a.id) {
            modelContext.insert(
                AnnotationRecord(
                    id: a.id,
                    bookStableId: bookStableId,
                    locator: a.locator,
                    position: a.position,
                    text: a.text,
                    note: a.note,
                    colorHex: a.colorHex,
                    style: a.style,
                    chapterTitle: a.chapterTitle,
                    createdAt: a.createdAt,
                    updatedAt: a.updatedAt,
                    remoteID: a.remoteID,
                    isRemotePlaceholder: a.isRemotePlaceholder
                )
            )
        }
        try modelContext.save()
    }
}
