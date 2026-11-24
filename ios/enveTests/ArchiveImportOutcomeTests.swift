import AVFoundation
import Foundation
import ReadiumZIPFoundation
import Testing

@testable import enve

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ArchiveImportOutcomeTests {
    @Test func corruptAndUnsupportedArchivesAreNotCommitted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let corrupt = fixture.inbox.appendingPathComponent("corrupt.zip")
        try Data(repeating: 0x42, count: 4_096).write(to: corrupt)
        let unsupported = try await fixture.makeArchive("notes.zip", entries: ["readme.txt": Data("not a book".utf8)])

        let outcomes = try await fixture.session.remoteImport.importArchives([corrupt, unsupported])

        #expect(outcomes.map(\.archive) == [corrupt, unsupported])
        #expect(outcomes.allSatisfy { !$0.isCommitted })
        #expect(fixture.session.remoteImport.lastError != nil)
        await fixture.session.retire()
    }

    @Test func partialBatchCommitsOnlyTheArchiveThatImported() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let valid = try await fixture.makeArchive("valid.zip", entries: ["Book/part-1.wav": try Fixture.silentWAV()])
        let corrupt = fixture.inbox.appendingPathComponent("corrupt.zip")
        try Data(repeating: 0x13, count: 2_048).write(to: corrupt)

        let outcomes = try await fixture.session.remoteImport.importArchives([valid, corrupt])

        #expect(outcomes.first { $0.archive == valid }?.isCommitted == true)
        #expect(outcomes.first { $0.archive == corrupt }?.isCommitted == false)
        let books = try #require(try outcomes.first { $0.archive == valid }?.result.get())
        #expect(books.count == 1)
        #expect(FileManager.default.fileExists(atPath: try #require(books.first).filePath))
        await fixture.session.retire()
    }

    @Test func cancelledArchiveImportThrowsInsteadOfReportingOutcomes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let archive = try await fixture.makeArchive("valid.zip", entries: ["Book/part-1.wav": try Fixture.silentWAV()])
        let service = fixture.session.remoteImport
        let task = Task { try await service.importArchives([archive]) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await fixture.session.retire()
    }

    @Test func committedArchiveIsReportedBeforeTheNextArchiveIsCancelled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try await fixture.makeArchive("first.zip", entries: ["Book/part.wav": try Fixture.silentWAV()])
        let second = try await fixture.makeArchive("second.zip", entries: ["Book/part.wav": try Fixture.silentWAV()])
        var acknowledged: [URL] = []
        let task = Task {
            try await fixture.session.remoteImport.importArchives([first, second]) { outcome in
                if outcome.isCommitted {
                    acknowledged.append(outcome.archive)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(acknowledged == [first])
        await fixture.session.retire()
    }

    private struct Fixture {
        let root: URL
        let suite: String
        let inbox: URL
        let session: ProfileSession

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "archive-import-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            let profile = FamilyProfile(id: UUID().uuidString, name: "Importer", role: .adult)
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
            inbox = root.appendingPathComponent("Documents/Inbox", isDirectory: true)
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        }

        func makeArchive(_ name: String, entries: [String: Data]) async throws -> URL {
            let url = inbox.appendingPathComponent(name)
            let archive = try await Archive(url: url, accessMode: .create)
            for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
                try await archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count),
                                           compressionMethod: .none) { position, count in
                    data.subdata(in: Int(position)..<min(Int(position) + count, data.count))
                }
            }
            return url
        }

        static func silentWAV() throws -> Data {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = buffer.frameCapacity
            try #require(buffer.floatChannelData?[0]).update(repeating: 0, count: Int(buffer.frameLength))
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: buffer)
            }
            return try Data(contentsOf: url)
        }

        func remove() {
            UserDefaults().removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
