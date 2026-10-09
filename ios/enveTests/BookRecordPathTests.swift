import Foundation
import Testing

@testable import enve

struct BookRecordPathTests {
    @Test func existingProfileFileKeepsItsCapturedRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Profiles/\(UUID().uuidString)/Documents/Ebooks/book.epub")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("profile book".utf8).write(to: file)
        #expect(BookRecord.rebaseSandboxPath(file.path) == file)
    }

    @Test func movedSandboxKeepsProfileComponentsUnderApplicationSupport() {
        let profileID = UUID().uuidString
        let suffix = "Profiles/\(profileID)/Documents/Ebooks/book.epub"
        let previous = "/private/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Library/Application Support/\(suffix)"
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(BookRecord.rebaseSandboxPath(previous) == root.appendingPathComponent(suffix))
    }

    @Test func movedOwnerSandboxKeepsLegacyDocumentsRoot() {
        let suffix = "Ebooks/\(UUID().uuidString).epub"
        let previous = "/private/var/mobile/Containers/Data/Application/\(UUID().uuidString)/Documents/\(suffix)"
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #expect(BookRecord.rebaseSandboxPath(previous) == root.appendingPathComponent(suffix))
    }
}
