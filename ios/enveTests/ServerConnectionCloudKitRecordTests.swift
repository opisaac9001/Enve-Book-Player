import CloudKit
import Foundation
import Testing

@testable import enve

@MainActor
struct ServerConnectionCloudKitRecordTests {
    @Test func allLibrariesDoesNotCreateAnEmptyCloudKitField() {
        let record = ServerConnectionCloudKitSync.shared.makeRecord(for: connection())

        #expect(record["selectedLibraryIds"] == nil)
        #expect(record.changedKeys().contains("selectedLibraryIds"))
    }

    @Test func emptyLibrarySelectionUsesTheAllLibrariesRepresentation() {
        let record = ServerConnectionCloudKitSync.shared.makeRecord(for: connection(libraryIds: []))

        #expect(record["selectedLibraryIds"] == nil)
        #expect(record.changedKeys().contains("selectedLibraryIds"))
    }

    @Test func clearingASelectionDeletesTheFieldOnTheSameServerRecord() throws {
        var connection = connection(libraryIds: ["books", "audiobooks"])
        let selected = ServerConnectionCloudKitSync.shared.makeRecord(for: connection)
        let libraryIds = try #require(selected["selectedLibraryIds"] as? [String])
        #expect(Set(libraryIds) == ["books", "audiobooks"])

        connection.selectedLibraryIds = nil
        let cleared = ServerConnectionCloudKitSync.shared.makeRecord(for: connection)
        #expect(cleared.recordID == selected.recordID)
        #expect(cleared["selectedLibraryIds"] == nil)
        #expect(cleared.changedKeys().contains("selectedLibraryIds"))
    }

    private func connection(libraryIds: Set<String>? = nil) -> ServerConnection {
        var connection = ServerConnection(
            name: "CloudKit fixture", url: "https://example.invalid", type: .audiobookshelf
        )
        connection.selectedLibraryIds = libraryIds
        return connection
    }
}
