import Foundation
import Testing

@testable import enve

struct ReaderNotebookMergeTests {
    @Test func bookloreRecordUpdatesLocalAnnotationWhenServerCopyIsNewer() {
        let local = ReaderAnnotation(
            id: "local-1",
            bookId: "book-1",
            locator: #"{"href":"chapter1.xhtml","locations":{"progression":0.25}}"#,
            position: 0.25,
            text: "Old text",
            colorHex: "#FFF59D",
            updatedAt: Date(timeIntervalSince1970: 1_000),
            remoteID: 7
        )

        let merged = ReaderNotebookMerge.applyingBookloreRecords(
            annotations: [remoteAnnotation(id: 7, cfi: "epubcfi(/6/4!/4/2)", text: "New text", updatedAt: "2026-01-01T00:00:00Z")],
            bookmarks: [],
            to: .init(bookmarks: [], annotations: [local]),
            bookID: "book-1",
            bookStableID: "stable-1"
        )

        #expect(merged.annotations.count == 1)
        #expect(merged.annotations[0].id == "local-1")
        #expect(merged.annotations[0].text == "New text")
        #expect(cfi(in: merged.annotations[0].locator) == "epubcfi(/6/4!/4/2)")
        #expect(merged.annotations[0].locator?.contains("chapter1.xhtml") == true)
    }

    @Test func bookloreRecordDoesNotOverwriteNewerLocalAnnotation() {
        let local = ReaderAnnotation(
            id: "local-1",
            bookId: "book-1",
            locator: #"{"href":"chapter1.xhtml","locations":{"progression":0.25}}"#,
            text: "Local text",
            updatedAt: Date(timeIntervalSince1970: 4_000_000_000),
            remoteID: 7
        )

        let merged = ReaderNotebookMerge.applyingBookloreRecords(
            annotations: [remoteAnnotation(id: 7, cfi: "epubcfi(/6/4!/4/2)", text: "Server text", updatedAt: "2026-01-01T00:00:00Z")],
            bookmarks: [],
            to: .init(bookmarks: [], annotations: [local]),
            bookID: "book-1",
            bookStableID: "stable-1"
        )

        #expect(merged.annotations.count == 1)
        #expect(merged.annotations[0].text == "Local text")
    }

    @Test func bookloreRecordUpgradesPlaceholderWithServerCFI() {
        let placeholder = ReaderAnnotation(
            id: "local-1",
            bookId: "book-1",
            locator: nil,
            text: "Placeholder",
            updatedAt: Date(timeIntervalSince1970: 4_000_000_000),
            remoteID: 7,
            isRemotePlaceholder: true
        )

        let merged = ReaderNotebookMerge.applyingBookloreRecords(
            annotations: [remoteAnnotation(id: 7, cfi: "epubcfi(/6/4!/4/2)", text: "Server text", updatedAt: "2026-01-01T00:00:00Z")],
            bookmarks: [],
            to: .init(bookmarks: [], annotations: [placeholder]),
            bookID: "book-1",
            bookStableID: "stable-1"
        )

        #expect(merged.annotations.count == 1)
        #expect(merged.annotations[0].text == "Placeholder")
        #expect(merged.annotations[0].isRemotePlaceholder == false)
        #expect(cfi(in: merged.annotations[0].locator) == "epubcfi(/6/4!/4/2)")
    }

    @Test func bookloreBookmarksDedupeByRemoteIDAndAdoptStableBookID() {
        let known = Bookmark(bookId: "stable-1", position: 0.5, title: "Known", mediaType: .ebook, remoteID: 11)

        let merged = ReaderNotebookMerge.applyingBookloreRecords(
            annotations: [],
            bookmarks: [remoteBookmark(id: 11), remoteBookmark(id: 12, title: "Fresh")],
            to: .init(bookmarks: [known], annotations: []),
            bookID: "book-1",
            bookStableID: "stable-1"
        )

        #expect(merged.bookmarks.count == 2)
        #expect(merged.bookmarks.map(\.remoteID) == [11, 12])
        #expect(merged.bookmarks[1].title == "Fresh")
        #expect(merged.bookmarks[1].bookId == "stable-1")
        #expect(merged.bookmarks[1].isRemotePlaceholder)
    }

    @Test func audiobookPositionedRemoteBookmarkConvertsMillisecondsToSeconds() {
        let merged = ReaderNotebookMerge.applyingBookloreRecords(
            annotations: [],
            bookmarks: [remoteBookmark(id: 12, positionMs: 90_000)],
            to: .init(bookmarks: [], annotations: []),
            bookID: "book-1",
            bookStableID: "stable-1"
        )

        #expect(merged.bookmarks[0].position == 90)
        #expect(merged.bookmarks[0].mediaType == .audiobook)
        #expect(merged.bookmarks[0].isRemotePlaceholder == false)
    }

    @Test func notebookEntriesRouteByTypeAndDedupeByRemoteID() {
        let knownBookmark = Bookmark(bookId: "stable-1", position: 0, title: "Known", mediaType: .ebook, remoteID: 1)
        let knownAnnotation = ReaderAnnotation(bookId: "book-1", text: "Known", remoteID: 2)

        let merged = ReaderNotebookMerge.applyingBookloreNotebookEntries(
            [
                notebookEntry(id: 1, type: .bookmark),
                notebookEntry(id: 2, type: .highlight),
                notebookEntry(id: 3, type: .bookmark, text: "New mark"),
                notebookEntry(id: 4, type: .note, text: "New note"),
            ],
            to: .init(bookmarks: [knownBookmark], annotations: [knownAnnotation]),
            bookID: "book-1",
            bookStableID: "stable-1"
        )

        #expect(merged.bookmarks.map(\.remoteID) == [1, 3])
        #expect(merged.annotations.map(\.remoteID) == [2, 4])
        #expect(merged.bookmarks[1].title == "New mark")
        #expect(merged.annotations[1].text == "New note")
        #expect(merged.annotations[1].isRemotePlaceholder)
    }

    @Test func locatorJSONFallsBackToExistingLocatorWithoutCFI() {
        let existing = #"{"href":"chapter1.xhtml"}"#
        #expect(ReaderNotebookMerge.locatorJSON(fromCFI: nil, existingLocator: existing) == existing)
        #expect(ReaderNotebookMerge.locatorJSON(fromCFI: "", existingLocator: existing) == existing)
    }

    @Test func locatorJSONFromBareCFIMarksFoliateAsSourceEngine() throws {
        let json = try #require(ReaderNotebookMerge.locatorJSON(fromCFI: "epubcfi(/6/4!/4/2)", existingLocator: nil))
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let locations = try #require(decoded["locations"] as? [String: Any])
        #expect(locations["cfi"] as? String == "epubcfi(/6/4!/4/2)")
        #expect(locations[EpubLocationBridge.sourceEngineLocationKey] as? String == ReaderEngineKind.foliate.rawValue)
    }

    @MainActor
    @Test func siloRecordsMergeIntoMappedLocalAnnotationInsteadOfDuplicating() throws {
        let idMap = InMemorySiloIDMap()
        let connectionID = UUID()
        idMap.setAnnotationRemoteID("remote-1", connectionID: connectionID, bookID: "stable-1", localID: "local-1")
        let local = ReaderAnnotation(
            id: "local-1",
            bookId: "stable-1",
            locator: #"{"href":"chapter1.xhtml","locations":{"cfi":"epubcfi(/6/4!/4/2)"}}"#,
            text: "Local",
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let merged = ReaderNotebookMerge.applyingSiloRecords(
            [try siloRecord(id: "remote-1", kind: "highlight", selectedText: "Server")],
            to: .init(bookmarks: [], annotations: [local]),
            bookStableID: "stable-1",
            connectionID: connectionID,
            idMap: idMap
        )

        #expect(merged.annotations.count == 1)
        #expect(merged.annotations[0].id == "local-1")
        #expect(merged.annotations[0].text == "Server")
    }

    @MainActor
    @Test func siloMergeDropsLocalArtifactsMissingFromTheServerResponse() throws {
        let idMap = InMemorySiloIDMap()
        let connectionID = UUID()
        idMap.setAnnotationRemoteID("remote-gone", connectionID: connectionID, bookID: "stable-1", localID: "local-gone")
        let synced = ReaderAnnotation(id: "local-gone", bookId: "stable-1", text: "Deleted remotely")
        let localOnly = ReaderAnnotation(id: "local-new", bookId: "stable-1", text: "Never synced")

        let merged = ReaderNotebookMerge.applyingSiloRecords(
            [],
            to: .init(bookmarks: [], annotations: [synced, localOnly]),
            bookStableID: "stable-1",
            connectionID: connectionID,
            idMap: idMap
        )

        #expect(merged.annotations.map(\.id) == ["local-new"])
    }

    @MainActor
    @Test func siloBookmarkRecordAdoptsMetadataLocalIDAndRegistersMapping() throws {
        let idMap = InMemorySiloIDMap()
        let connectionID = UUID()

        let merged = ReaderNotebookMerge.applyingSiloRecords(
            [
                try siloRecord(
                    id: "remote-9",
                    kind: "bookmark",
                    selectedText: "Chapter start",
                    metadata: ["enve_local_id": "local-9", "enve_position": "0.42"]
                )
            ],
            to: .init(bookmarks: [], annotations: []),
            bookStableID: "stable-1",
            connectionID: connectionID,
            idMap: idMap
        )

        #expect(merged.bookmarks.count == 1)
        #expect(merged.bookmarks[0].id == "local-9")
        #expect(merged.bookmarks[0].title == "Chapter start")
        #expect(merged.bookmarks[0].position == 0.42)
        #expect(idMap.bookmarkRemoteID(connectionID: connectionID, bookID: "stable-1", localID: "local-9") == "remote-9")
    }

    private func cfi(in locator: String?) -> String? {
        guard let data = locator?.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let locations = json["locations"] as? [String: Any]
        else { return nil }
        return locations["cfi"] as? String
    }

    private func remoteAnnotation(
        id: Int,
        cfi: String?,
        text: String,
        updatedAt: String?
    ) -> BookloreProvider.RemoteAnnotationRecord {
        BookloreProvider.RemoteAnnotationRecord(
            id: id,
            bookId: 1,
            cfi: cfi,
            text: text,
            color: "#FFF59D",
            style: "highlight",
            note: nil,
            chapterTitle: nil,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: updatedAt
        )
    }

    private func remoteBookmark(
        id: Int,
        title: String = "Synced",
        positionMs: Double? = nil
    ) -> BookloreProvider.RemoteBookmarkRecord {
        BookloreProvider.RemoteBookmarkRecord(
            id: id,
            bookId: 1,
            cfi: nil,
            positionMs: positionMs,
            trackIndex: nil,
            title: title,
            notes: nil,
            color: nil,
            priority: nil,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-02T00:00:00Z"
        )
    }

    private func notebookEntry(
        id: Int,
        type: BookloreProvider.AppNotebookEntry.EntryType,
        text: String = "Entry"
    ) -> BookloreProvider.AppNotebookEntry {
        BookloreProvider.AppNotebookEntry(
            id: id,
            type: type,
            bookId: 1,
            text: text,
            note: nil,
            color: nil,
            style: nil,
            createdAt: "2025-01-01T00:00:00Z",
            updatedAt: "2025-01-02T00:00:00Z"
        )
    }

    private func siloRecord(
        id: String,
        kind: String,
        selectedText: String,
        metadata: [String: String] = [:]
    ) throws -> SiloReaderAnnotationRecord {
        let payload: [String: Any] = [
            "id": id,
            "content_id": "content-1",
            "kind": kind,
            "cfi_range": "epubcfi(/6/4!/4/2)",
            "selected_text": selectedText,
            "note": "",
            "style": "highlight",
            "color": "#facc15",
            "metadata": metadata,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(SiloReaderAnnotationRecord.self, from: data)
    }
}

@MainActor
final class InMemorySiloIDMap: SiloReaderArtifactIDMapping {
    private var annotationIDs: [String: String] = [:]
    private var bookmarkIDs: [String: String] = [:]

    func annotationRemoteID(connectionID: UUID, bookID: String, localID: String) -> String? {
        annotationIDs[key(connectionID, bookID, localID)]
    }

    func setAnnotationRemoteID(_ remoteID: String, connectionID: UUID, bookID: String, localID: String) {
        annotationIDs[key(connectionID, bookID, localID)] = remoteID
    }

    func removeAnnotationRemoteID(connectionID: UUID, bookID: String, localID: String) {
        annotationIDs.removeValue(forKey: key(connectionID, bookID, localID))
    }

    func localAnnotationID(connectionID: UUID, bookID: String, remoteID: String) -> String? {
        localID(in: annotationIDs, connectionID: connectionID, bookID: bookID, remoteID: remoteID)
    }

    func bookmarkRemoteID(connectionID: UUID, bookID: String, localID: String) -> String? {
        bookmarkIDs[key(connectionID, bookID, localID)]
    }

    func setBookmarkRemoteID(_ remoteID: String, connectionID: UUID, bookID: String, localID: String) {
        bookmarkIDs[key(connectionID, bookID, localID)] = remoteID
    }

    func removeBookmarkRemoteID(connectionID: UUID, bookID: String, localID: String) {
        bookmarkIDs.removeValue(forKey: key(connectionID, bookID, localID))
    }

    func localBookmarkID(connectionID: UUID, bookID: String, remoteID: String) -> String? {
        localID(in: bookmarkIDs, connectionID: connectionID, bookID: bookID, remoteID: remoteID)
    }

    private func key(_ connectionID: UUID, _ bookID: String, _ localID: String) -> String {
        "\(connectionID.uuidString)|\(bookID)|\(localID)"
    }

    private func localID(in map: [String: String], connectionID: UUID, bookID: String, remoteID: String) -> String? {
        let prefix = "\(connectionID.uuidString)|\(bookID)|"
        return map.first { $0.key.hasPrefix(prefix) && $0.value == remoteID }
            .map { String($0.key.dropFirst(prefix.count)) }
    }
}
