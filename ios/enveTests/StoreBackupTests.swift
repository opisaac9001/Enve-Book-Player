import Foundation
import Testing

@testable import enve

@MainActor
struct StoreBackupTests {
    @Test func repeatedBackupsPreserveStoreAndJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("test.sqlite")
        let journal = root.appendingPathComponent("test.sqlite-wal")
        try Data("store".utf8).write(to: store)
        try Data("journal".utf8).write(to: journal)

        let first = try #require(StoreBackup.backup(storeURL: store, label: "Test"))
        let second = try #require(StoreBackup.backup(storeURL: store, label: "Test"))
        #expect(first != second)
        #expect(try Data(contentsOf: first.appendingPathComponent("test.sqlite")) == Data("store".utf8))
        #expect(try Data(contentsOf: second.appendingPathComponent("test.sqlite-wal")) == Data("journal".utf8))
        #expect(FileManager.default.fileExists(atPath: store.path))
        #expect(FileManager.default.fileExists(atPath: journal.path))
        #expect(StoreBackup.existingBackups(in: root, label: "Test").count == 2)
    }

    @Test func failedBackupPreservesPreviousBackups() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("test.sqlite")
        try Data("store".utf8).write(to: store)
        let label = String(repeating: "x", count: 220)
        let previous = root.appendingPathComponent("\(label).corrupt-previous")
        try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
        #expect(StoreBackup.backup(storeURL: store, label: label, retainCount: 1) == nil)
        #expect(FileManager.default.fileExists(atPath: previous.path))
        #expect(try Data(contentsOf: store) == Data("store".utf8))
    }
}
