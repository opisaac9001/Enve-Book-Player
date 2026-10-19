import Foundation
import Testing

@testable import enve

@MainActor
struct GrimmoryBookNoteMergeTests {
    private let connectionID = UUID()
    private let idMap = GrimmoryBookNoteIDStore(defaults: UserDefaults(suiteName: "GrimmoryBookNoteMergeTests-\(UUID().uuidString)")!)

    @Test func aServerNoteBecomesAMappedLocalAnnotationWithoutClaimingTheAnnotationID() throws {
        let merged = merge([try note(id: 7, content: "Remember this", cfi: "epubcfi(/6/4!/4/2)")], into: [])

        let annotation = try #require(merged.annotations.first)
        #expect(merged.annotations.count == 1)
        #expect(annotation.remoteID == nil)
        #expect(annotation.note == "Remember this")
        #expect(annotation.text == "Selected passage")
        #expect(EpubLocationBridge.epubCFI(from: annotation.locator) == "epubcfi(/6/4!/4/2)")
        #expect(idMap.noteID(connectionID: connectionID, bookID: "stable-1", localID: annotation.id) == 7)
    }

    @Test func aNewerServerNoteUpdatesTheMappedAnnotationInPlace() throws {
        let local = ReaderAnnotation(
            id: "local-1",
            bookId: "book-1",
            text: "Selected passage",
            note: "Old",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        idMap.setNoteID(7, connectionID: connectionID, bookID: "stable-1", localID: "local-1")

        let merged = merge([try note(id: 7, content: "New")], into: [local])

        #expect(merged.annotations.map(\.id) == ["local-1"])
        #expect(merged.annotations[0].note == "New")
    }

    @Test func aNewerLocalEditIsKept() throws {
        let local = ReaderAnnotation(id: "local-1", bookId: "book-1", text: "Passage", note: "Local", updatedAt: .distantFuture)
        idMap.setNoteID(7, connectionID: connectionID, bookID: "stable-1", localID: "local-1")

        let merged = merge([try note(id: 7, content: "Server")], into: [local])

        #expect(merged.annotations[0].note == "Local")
    }

    @Test func aNoteDeletedOnTheServerIsRemovedLocally() {
        let mapped = ReaderAnnotation(id: "local-gone", bookId: "book-1", text: "Passage", note: "Gone")
        let highlight = ReaderAnnotation(id: "local-highlight", bookId: "book-1", text: "Passage", remoteID: 3)
        idMap.setNoteID(9, connectionID: connectionID, bookID: "stable-1", localID: "local-gone")

        let merged = merge([], into: [mapped, highlight])

        #expect(merged.annotations.map(\.id) == ["local-highlight"])
        #expect(idMap.noteID(connectionID: connectionID, bookID: "stable-1", localID: "local-gone") == nil)
    }

    @Test func aStaleMappingIsReplacedWhenTheLocalAnnotationIsMissing() throws {
        idMap.setNoteID(7, connectionID: connectionID, bookID: "stable-1", localID: "missing")

        let merged = merge([try note(id: 7, content: "Back")], into: [])

        let annotation = try #require(merged.annotations.first)
        #expect(idMap.localID(connectionID: connectionID, bookID: "stable-1", noteID: 7) == annotation.id)
        #expect(idMap.noteID(connectionID: connectionID, bookID: "stable-1", localID: "missing") == nil)
    }

    private func merge(_ records: [BookloreProvider.RemoteBookNoteRecord], into annotations: [ReaderAnnotation]) -> ReaderNotebookMerge.Snapshot {
        ReaderNotebookMerge.applyingGrimmoryBookNotes(
            records,
            to: .init(bookmarks: [], annotations: annotations),
            bookID: "book-1",
            bookStableID: "stable-1",
            connectionID: connectionID,
            idMap: idMap
        )
    }

    private func note(id: Int, content: String, cfi: String? = nil) throws -> BookloreProvider.RemoteBookNoteRecord {
        var object: [String: Any] = [
            "id": id,
            "bookId": 42,
            "selectedText": "Selected passage",
            "noteContent": content,
            "color": "#FFFF00",
            "createdAt": "2026-10-01T10:00:00",
            "updatedAt": "2026-10-02T10:00:00",
        ]
        if let cfi { object["cfi"] = cfi }
        return try JSONDecoder().decode(
            BookloreProvider.RemoteBookNoteRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
