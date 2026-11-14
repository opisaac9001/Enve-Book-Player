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
        #expect(merged.annotations.map(\.remoteID) == [2])
        #expect(merged.bookmarks[1].title == "New mark")
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

    @Test func addingServerCFIPreservesTheOriginalReaderEngine() throws {
        let existing = """
            {"href":"chapter1.xhtml","type":"application/xhtml+xml","locations":{"progression":0.3,"enveSourceEngine":"readium"},"text":{"highlight":"Selected text"}}
            """
        let json = try #require(ReaderNotebookMerge.locatorJSON(
            fromCFI: "epubcfi(/6/4!/4/2)",
            existingLocator: existing
        ))
        let data = try #require(json.data(using: .utf8))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let locations = try #require(decoded["locations"] as? [String: Any])

        #expect(locations["cfi"] as? String == "epubcfi(/6/4!/4/2)")
        #expect(locations[EpubLocationBridge.sourceEngineLocationKey] as? String == ReaderEngineKind.readium.rawValue)
    }

    @MainActor
    @Test func siloRecordsMergeIntoMappedLocalAnnotationInsteadOfDuplicating() throws {
        let idMap = InMemorySiloIDMap()
        let scope = siloScope()
        idMap.setAnnotationRemoteID("remote-1", connectionID: scope.connectionID, bookID: scope.bookID, localID: "local-1")
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
            scope: scope,
            idMap: idMap
        )

        #expect(merged.annotations.count == 1)
        #expect(merged.annotations[0].id == "local-1")
        #expect(merged.annotations[0].text == "Server")
        #expect(idMap.artifactGuards(in: scope)["remote-1"]?.etag == "\"etag-remote-1\"")
        #expect(idMap.artifactGuards(in: scope)["remote-1"]?.state == .synced)
    }

    @MainActor
    @Test func siloMergeDropsCleanLocalArtifactsMissingFromTheServerResponse() throws {
        let idMap = InMemorySiloIDMap()
        let scope = siloScope()
        idMap.setAnnotationRemoteID("remote-gone", connectionID: scope.connectionID, bookID: scope.bookID, localID: "local-gone")
        idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: "\"v1\"", state: .synced, recordedAt: Date()), remoteID: "remote-gone", in: scope)
        let synced = ReaderAnnotation(id: "local-gone", bookId: "stable-1", text: "Deleted remotely", updatedAt: .distantPast)
        let localOnly = ReaderAnnotation(id: "local-new", bookId: "stable-1", text: "Never synced")

        let merged = ReaderNotebookMerge.applyingSiloRecords(
            [],
            to: .init(bookmarks: [], annotations: [synced, localOnly]),
            scope: scope,
            idMap: idMap
        )

        #expect(merged.annotations.map(\.id) == ["local-new"])
        #expect(idMap.annotationRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: "local-gone") == nil)
        #expect(idMap.artifactGuards(in: scope).isEmpty)
    }

    @MainActor
    @Test func siloMergeKeepsLocallyEditedArtifactsTheServerDeleted() throws {
        let idMap = InMemorySiloIDMap()
        let scope = siloScope()
        idMap.setAnnotationRemoteID("remote-edited", connectionID: scope.connectionID, bookID: scope.bookID, localID: "local-edited")
        idMap.setAnnotationRemoteID("remote-conflict", connectionID: scope.connectionID, bookID: scope.bookID, localID: "local-conflict")
        idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: "\"v1\"", state: .pendingUpdate, recordedAt: Date()), remoteID: "remote-edited", in: scope)
        idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: "\"v1\"", state: .conflict, recordedAt: Date()), remoteID: "remote-conflict", in: scope)

        let merged = ReaderNotebookMerge.applyingSiloRecords(
            [],
            to: .init(
                bookmarks: [],
                annotations: [
                    ReaderAnnotation(id: "local-edited", bookId: "stable-1", text: "Offline edit"),
                    ReaderAnnotation(id: "local-conflict", bookId: "stable-1", text: "Conflicted edit"),
                ]
            ),
            scope: scope,
            idMap: idMap
        )

        #expect(merged.annotations.map(\.id) == ["local-edited", "local-conflict"])
        #expect(idMap.annotationRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: "local-edited") == "remote-edited")
        #expect(idMap.artifactGuards(in: scope)["remote-edited"]?.state == .conflict)
    }

    @MainActor
    @Test func siloMergeNeverOverwritesPendingOrConflictedLocalEdits() throws {
        let idMap = InMemorySiloIDMap()
        let scope = siloScope()
        for (local, remote, state) in [("local-a", "remote-a", SiloReaderArtifactGuard.State.pendingUpdate), ("local-b", "remote-b", .conflict)] {
            idMap.setAnnotationRemoteID(remote, connectionID: scope.connectionID, bookID: scope.bookID, localID: local)
            idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: "\"base\"", state: state, recordedAt: Date()), remoteID: remote, in: scope)
        }

        let merged = ReaderNotebookMerge.applyingSiloRecords(
            [
                try siloRecord(id: "remote-a", kind: "highlight", selectedText: "Server A", updatedAt: "2099-01-01T00:00:00Z"),
                try siloRecord(id: "remote-b", kind: "highlight", selectedText: "Server B", updatedAt: "2099-01-01T00:00:00Z"),
            ],
            to: .init(
                bookmarks: [],
                annotations: [
                    ReaderAnnotation(id: "local-a", bookId: "stable-1", text: "Local A"),
                    ReaderAnnotation(id: "local-b", bookId: "stable-1", text: "Local B"),
                ]
            ),
            scope: scope,
            idMap: idMap
        )

        #expect(merged.annotations.map(\.text) == ["Local A", "Local B"])
        #expect(idMap.artifactGuards(in: scope)["remote-a"]?.etag == "\"base\"")
        #expect(idMap.artifactGuards(in: scope)["remote-b"]?.state == .conflict)
    }

    @MainActor
    @Test func siloMergeAppliesServerEditsOnlyWhenTheValidatorChanged() throws {
        let idMap = InMemorySiloIDMap()
        let scope = siloScope()
        idMap.setAnnotationRemoteID("remote-1", connectionID: scope.connectionID, bookID: scope.bookID, localID: "local-1")
        idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: "\"etag-remote-1\"", state: .synced, recordedAt: Date()), remoteID: "remote-1", in: scope)
        let local = ReaderAnnotation(id: "local-1", bookId: "stable-1", text: "Local", updatedAt: Date(timeIntervalSince1970: 1_000))

        let unchanged = ReaderNotebookMerge.applyingSiloRecords(
            [try siloRecord(id: "remote-1", kind: "highlight", selectedText: "Same version", updatedAt: "2099-01-01T00:00:00Z")],
            to: .init(bookmarks: [], annotations: [local]),
            scope: scope,
            idMap: idMap
        )
        #expect(unchanged.annotations[0].text == "Local")

        let edited = ReaderNotebookMerge.applyingSiloRecords(
            [try siloRecord(id: "remote-1", kind: "highlight", selectedText: "Edited elsewhere", etag: "\"v2\"")],
            to: .init(bookmarks: [], annotations: [local]),
            scope: scope,
            idMap: idMap
        )
        #expect(edited.annotations[0].text == "Edited elsewhere")
        #expect(idMap.artifactGuards(in: scope)["remote-1"]?.etag == "\"v2\"")
    }

    @MainActor
    @Test func siloMergeKeepsTombstonedRecordsDeletedAndClearsFinishedTombstones() throws {
        let idMap = InMemorySiloIDMap()
        let scope = siloScope()
        idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: "\"v1\"", state: .pendingDelete, recordedAt: Date()), remoteID: "remote-deleted", in: scope)
        idMap.setArtifactGuard(SiloReaderArtifactGuard(etag: "\"v1\"", state: .pendingDelete, recordedAt: Date()), remoteID: "remote-gone", in: scope)

        let merged = ReaderNotebookMerge.applyingSiloRecords(
            [try siloRecord(id: "remote-deleted", kind: "highlight", selectedText: "Deleted offline", metadata: ["enve_local_id": "local-deleted"])],
            to: .init(bookmarks: [], annotations: []),
            scope: scope,
            idMap: idMap
        )

        #expect(merged.annotations.isEmpty)
        #expect(idMap.artifactGuards(in: scope)["remote-deleted"]?.state == .pendingDelete)
        #expect(idMap.artifactGuards(in: scope)["remote-gone"] == nil)
    }

    @MainActor
    @Test func siloBookmarkRecordAdoptsMetadataLocalIDAndRegistersMapping() throws {
        let idMap = InMemorySiloIDMap()
        let scope = siloScope()

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
            scope: scope,
            idMap: idMap
        )

        #expect(merged.bookmarks.count == 1)
        #expect(merged.bookmarks[0].id == "local-9")
        #expect(merged.bookmarks[0].title == "Chapter start")
        #expect(merged.bookmarks[0].position == 0.42)
        #expect(idMap.bookmarkRemoteID(connectionID: scope.connectionID, bookID: scope.bookID, localID: "local-9") == "remote-9")
        #expect(idMap.artifactGuards(in: scope)["remote-9"]?.state == .synced)
    }

    private func siloScope() -> SiloReaderArtifactScope {
        SiloReaderArtifactScope(connectionID: UUID(), account: "7/profile-1", bookID: "stable-1")
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
        metadata: [String: String] = [:],
        updatedAt: String? = "2026-01-02T03:04:05Z",
        etag: String? = nil
    ) throws -> SiloReaderAnnotationRecord {
        var payload: [String: Any] = [
            "id": id,
            "content_id": "content-1",
            "kind": kind,
            "cfi_range": "epubcfi(/6/4!/4/2)",
            "selected_text": selectedText,
            "note": "",
            "style": "highlight",
            "color": "#facc15",
            "metadata": metadata,
            "etag": etag ?? "\"etag-\(id)\"",
        ]
        if let updatedAt {
            payload["updated_at"] = updatedAt
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SiloReaderAnnotationRecord.self, from: data)
    }
}

@MainActor
final class InMemorySiloIDMap: SiloReaderArtifactIDMapping {
    private var annotationIDs: [String: String] = [:]
    private var bookmarkIDs: [String: String] = [:]
    private var guards: [SiloReaderArtifactScope: [String: SiloReaderArtifactGuard]] = [:]

    func artifactGuards(in scope: SiloReaderArtifactScope) -> [String: SiloReaderArtifactGuard] {
        guards[scope] ?? [:]
    }

    func setArtifactGuard(_ artifactGuard: SiloReaderArtifactGuard?, remoteID: String, in scope: SiloReaderArtifactScope) {
        guards[scope, default: [:]][remoteID] = artifactGuard
    }

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
