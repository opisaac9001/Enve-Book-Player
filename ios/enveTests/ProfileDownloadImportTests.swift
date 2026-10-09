import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileDownloadImportTests {
    @Test func clonedAudiobookHasIndependentInodeProgressAndLifetime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = fixture.book
        let file = try fixture.writeAudio()
        let service = ProfileDownloadImportService(source: fixture.source, destination: fixture.destination)
        let imported = try await service.importDownload(original, completedTask: fixture.completedTask)
        let importedFile = URL(fileURLWithPath: try #require(imported.filePath))
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let importedAttributes = try FileManager.default.attributesOfItem(atPath: importedFile.path)
        #expect(sourceAttributes[.systemFileNumber] as? NSNumber != importedAttributes[.systemFileNumber] as? NSNumber)
        #expect(try Data(contentsOf: importedFile) == fixture.bytes)
        #expect(imported.source == .local)
        #expect(imported.id != original.id)
        #expect(imported.providerId != original.providerId)
        #expect(imported.backendId != original.backendId)
        #expect(imported.currentTime == 0)
        #expect(!imported.isFinished)
        #expect(imported.epubLocator == nil)
        #expect(imported.linkedAudiobookStableId == nil)
        #expect(imported.partKey == nil)
        #expect(imported.audioTracks?.first?.contentUrl == nil)
        #expect(imported.audioTracks?.first?.headers == nil)
        #expect(imported.title == original.title)
        #expect(imported.author == original.author)
        #expect(imported.narrator == original.narrator)
        #expect(imported.duration == original.duration)
        #expect(imported.chapters?.first?.start == original.chapters?.first?.start)
        #expect(imported.chapters?.first?.end == original.chapters?.first?.end)
        let metadata = try fixture.destination.loadMetadataOverride(OfflineBookMetadata.self, for: imported.downloadKey)
        #expect(metadata.source == .local)
        #expect(metadata.audioTracks?.first?.headers == nil)
        let receiptURL = importedFile.deletingLastPathComponent().appendingPathComponent("profile-import.json")
        let receipt = try String(contentsOf: receiptURL, encoding: .utf8)
        #expect(!receipt.contains("private.invalid"))
        #expect(!receipt.contains("signed-secret"))
        #expect(!receipt.contains("remote-account"))

        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data([0x99]))
        try handle.close()
        #expect(try Data(contentsOf: importedFile) == fixture.bytes)
        try fixture.destination.deleteDownloadedAudiobook(imported.downloadKey)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: file).first == 0x99)

        let next = try await service.importDownload(original, completedTask: fixture.completedTask)
        let nextFile = URL(fileURLWithPath: try #require(next.filePath))
        let nextBytes = try Data(contentsOf: nextFile)
        try fixture.source.deleteDownloadedAudiobook(original.downloadKey)
        #expect(try Data(contentsOf: nextFile) == nextBytes)
    }

    @Test func repeatedImportAndReopenedServiceKeepOneLocalIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.writeAudio()
        _ = try fixture.source.saveCoverOverride(for: fixture.book.downloadKey, imageData: Data([1, 2, 3]))
        let first = try await ProfileDownloadImportService(source: fixture.source, destination: fixture.destination)
            .importDownload(fixture.book, completedTask: fixture.completedTask)
        try fixture.source.deleteDownloadedAudiobook(fixture.book.downloadKey)
        let reopened = try LocalStorageManager(storage: fixture.destinationLocations, isDownloadActive: { _ in false })
        let second = try await ProfileDownloadImportService(source: fixture.source, destination: reopened)
            .importDownload(fixture.book, completedTask: fixture.completedTask)
        #expect(first == second)
        #expect(reopened.downloadedAudiobookIds().count == 1)
        let coverURL = try #require(first.thumb.flatMap(URL.init(string:)))
        #expect(coverURL.isFileURL)
        #expect(try Data(contentsOf: coverURL) == Data([1, 2, 3]))
        #expect(coverURL != fixture.source.coverOverridePath(for: fixture.book.downloadKey))
    }

    @Test func incompleteWrongMissingAndSymlinkMediaDoNotPublish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = ProfileDownloadImportService(source: fixture.source, destination: fixture.destination)
        for status in [BookDownloadTask.DownloadStatus.queued, .downloading, .paused, .failed, .cancelled] {
            var task = fixture.completedTask
            task.status = status
            await #expect(throws: (any Error).self) {
                try await service.importDownload(fixture.book, completedTask: task)
            }
        }
        var wrong = BookDownloadTask.create(bookId: "wrong-book", title: "Wrong", source: fixture.book.source)
        wrong.status = .completed
        await #expect(throws: (any Error).self) {
            try await service.importDownload(fixture.book, completedTask: wrong)
        }
        await #expect(throws: (any Error).self) {
            try await service.importDownload(fixture.book, completedTask: fixture.completedTask)
        }
        let file = try fixture.writeAudio()
        let activeSource = try LocalStorageManager(storage: fixture.sourceLocations, isDownloadActive: { _ in true })
        await #expect(throws: (any Error).self) {
            try await ProfileDownloadImportService(source: activeSource, destination: fixture.destination)
                .importDownload(fixture.book, completedTask: fixture.completedTask)
        }
        let external = fixture.root.appendingPathComponent("external.m4b")
        try fixture.bytes.write(to: external)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        await #expect(throws: (any Error).self) {
            try await service.importDownload(fixture.book, completedTask: fixture.completedTask)
        }
        #expect(fixture.destination.downloadedAudiobookIds().isEmpty)
        #expect(try Data(contentsOf: external) == fixture.bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.audiobooksDirectory.path).isEmpty)
    }

    @Test func ebookComicAndPDFClonesStayLocalAndIndependent() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceEbooks = try LocalEbookImporter(storage: fixture.sourceLocations)
        let destinationEbooks = try LocalEbookImporter(storage: fixture.destinationLocations)
        let service = ProfileDownloadImportService(
            source: fixture.source, destination: fixture.destination,
            sourceEbooks: sourceEbooks, destinationEbooks: destinationEbooks
        )
        for ext in ["epub", "cbz", "pdf"] {
            let file = sourceEbooks.serverEbooksRoot.appendingPathComponent("fixture.\(ext)")
            try fixture.bytes.write(to: file)
            let book = Book(
                id: UUID().uuidString, title: ext, mediaType: .ebook, ebookFormat: ext,
                epubLocator: "private-position", ebookProgress: 0.7, ebookFileURL: file,
                currentTime: 70, isFinished: true, libraryId: "remote-library",
                providerId: UUID(), backendId: "remote-account", source: .audiobookshelf, filePath: file.path
            )
            var task = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
            task.status = .completed
            let imported = try await service.importDownload(book, completedTask: task)
            let importedURL = try #require(imported.ebookFileURL)
            #expect(importedURL.path.hasPrefix(destinationEbooks.localEbooksRoot.path))
            #expect(imported.ebookFormat == ext)
            #expect(imported.source == .local)
            #expect(imported.audioTracks == nil)
            #expect(imported.currentTime == 0)
            #expect(imported.epubLocator == nil)
            #expect(imported.ebookProgress == nil)
            #expect(!imported.isFinished)
            #expect(try Data(contentsOf: importedURL) == fixture.bytes)
            let originalInode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? NSNumber
            let importedInode = try FileManager.default.attributesOfItem(atPath: importedURL.path)[.systemFileNumber] as? NSNumber
            #expect(originalInode != importedInode)
            let repeated = try await service.importDownload(book, completedTask: task)
            #expect(repeated == imported)
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data([0x99]))
            try handle.close()
            #expect(try Data(contentsOf: importedURL) == fixture.bytes)
            try FileManager.default.removeItem(at: file)
            #expect(try Data(contentsOf: importedURL) == fixture.bytes)
            let reopenedImport = try await service.importDownload(book, completedTask: task)
            #expect(reopenedImport == imported)
            try FileManager.default.removeItem(at: importedURL.deletingLastPathComponent())
        }
    }

    @Test func escapedAndSymlinkEbooksDoNotPublish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceEbooks = try LocalEbookImporter(storage: fixture.sourceLocations)
        let destinationEbooks = try LocalEbookImporter(storage: fixture.destinationLocations)
        let service = ProfileDownloadImportService(
            source: fixture.source, destination: fixture.destination,
            sourceEbooks: sourceEbooks, destinationEbooks: destinationEbooks
        )
        let external = fixture.root.appendingPathComponent("external.pdf")
        try fixture.bytes.write(to: external)
        let linked = sourceEbooks.serverEbooksRoot.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: external)
        for file in [external, linked] {
            let book = Book(
                id: UUID().uuidString, title: "Invalid", mediaType: .ebook,
                ebookFormat: "pdf", ebookFileURL: file, backendId: "remote-account",
                source: .audiobookshelf, filePath: file.path
            )
            var task = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
            task.status = .completed
            await #expect(throws: (any Error).self) {
                try await service.importDownload(book, completedTask: task)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: destinationEbooks.localEbooksRoot.path).isEmpty)
        #expect(try Data(contentsOf: external) == fixture.bytes)
    }

    @Test func linkedPairKeepsFreshLinksAndIndependentPositions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceEbooks = try LocalEbookImporter(storage: fixture.sourceLocations)
        let destinationEbooks = try LocalEbookImporter(storage: fixture.destinationLocations)
        let file = sourceEbooks.serverEbooksRoot.appendingPathComponent("pair.epub")
        try fixture.bytes.write(to: file)
        var ebook = Book(id: "paired-ebook", title: "Paired ebook", mediaType: .ebook,
            ebookFormat: "epub", epubLocator: "private-position", ebookProgress: 0.7, ebookFileURL: file,
            isFinished: true, libraryId: "library", providerId: UUID(), backendId: "account", source: .audiobookshelf)
        var audio = fixture.book
        audio.readAloudSourceStableId = ebook.stableId
        ebook.linkedAudiobookStableId = audio.stableId
        ebook.linkedAudiobookChapterOffset = 2
        _ = try fixture.writeAudio(for: audio)
        var audioTask = BookDownloadTask.create(bookId: audio.downloadKey, title: audio.title, source: audio.source)
        audioTask.status = .completed
        var ebookTask = BookDownloadTask.create(bookId: ebook.downloadKey, title: ebook.title, source: ebook.source)
        ebookTask.status = .completed
        let service = ProfileDownloadImportService(source: fixture.source, destination: fixture.destination,
            sourceEbooks: sourceEbooks, destinationEbooks: destinationEbooks)
        let imported = try await service.importLinkedDownloads([
            (book: ebook, completedTask: ebookTask), (book: audio, completedTask: audioTask)
        ])
        #expect(imported[0].linkedAudiobookStableId == imported[1].stableId)
        #expect(imported[0].linkedAudiobookChapterOffset == 2)
        #expect(imported[1].readAloudSourceStableId == imported[0].stableId)
        let audioFile = URL(fileURLWithPath: try #require(imported[1].filePath))
        #expect(audioFile.deletingLastPathComponent() == fixture.destination.bookAudioDirectory(for: imported[1].downloadKey))
        #expect(try Data(contentsOf: audioFile) == fixture.bytes)
        #expect(imported[0].epubLocator == nil)
        #expect(imported[0].ebookProgress == nil)
        #expect(!imported[0].isFinished)
        #expect(imported[1].currentTime == 0)
        #expect(!imported[1].isFinished)
        #expect(ebook.ebookProgress == 0.7)
        #expect(audio.currentTime == 400)
        #expect(fixture.destination.totalEbookSize() >= Int64(fixture.bytes.count))
        #expect(fixture.destination.totalDownloadedMediaSize() == fixture.destination.totalAudiobooksSize() + fixture.destination.totalEbookSize())
        let reopened = try await service.importLinkedDownloads([
            (book: audio, completedTask: audioTask), (book: ebook, completedTask: ebookTask)
        ])
        #expect(reopened.map(\.stableId) == [imported[1].stableId, imported[0].stableId])
    }

    @Test func failedPairPublicationRemovesBothClones() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let audioFile = try fixture.writeAudio()
        let sourceEbooks = try LocalEbookImporter(storage: fixture.sourceLocations)
        let destinationEbooks = try LocalEbookImporter(storage: fixture.destinationLocations)
        let file = sourceEbooks.serverEbooksRoot.appendingPathComponent("rollback.epub")
        try fixture.bytes.write(to: file)
        let ebook = Book(id: "rollback-ebook", title: "Rollback", mediaType: .ebook,
            ebookFormat: "epub", ebookFileURL: file, libraryId: "library", providerId: UUID(),
            backendId: "account", source: .audiobookshelf)
        var task = BookDownloadTask.create(bookId: ebook.downloadKey, title: ebook.title, source: ebook.source)
        task.status = .completed
        let service = ProfileDownloadImportService(source: fixture.source, destination: fixture.destination,
            sourceEbooks: sourceEbooks, destinationEbooks: destinationEbooks)
        do {
            _ = try await service.importLinkedDownloads([
                (book: ebook, completedTask: task), (book: fixture.book, completedTask: fixture.completedTask)
            ]) { _ in throw ProfileDownloadImportError.sourceChanged }
            Issue.record("Pair publication should fail")
        } catch ProfileDownloadImportError.sourceChanged {}
        #expect(try FileManager.default.contentsOfDirectory(atPath: destinationEbooks.localEbooksRoot.path).isEmpty)
        #expect(fixture.destination.totalDownloadedMediaSize() == 0)
        #expect(try Data(contentsOf: file) == fixture.bytes)
        #expect(try Data(contentsOf: audioFile) == fixture.bytes)
    }

    private struct Fixture {
        let root: URL
        let bytes = Data(repeating: 0x55, count: 130_000)
        let sourceLocations: ProfileStorageLocations
        let destinationLocations: ProfileStorageLocations
        let source: LocalStorageManager
        let destination: LocalStorageManager
        let book: Book
        let completedTask: BookDownloadTask

        init() throws {
            let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            root = fixtureRoot
            func locations(_ profileID: String) -> ProfileStorageLocations {
                ProfileStorageLocations(
                    profileID: profileID, documentsDirectory: fixtureRoot.appendingPathComponent("Documents"),
                    applicationSupportDirectory: fixtureRoot.appendingPathComponent("ApplicationSupport"),
                    cachesDirectory: fixtureRoot.appendingPathComponent("Caches"),
                    legacyPlaybackStoreURL: fixtureRoot.appendingPathComponent("default.store")
                )
            }
            sourceLocations = locations(FamilyProfile.ownerID)
            destinationLocations = locations(UUID().uuidString)
            source = try LocalStorageManager(storage: sourceLocations, isDownloadActive: { _ in false })
            destination = try LocalStorageManager(storage: destinationLocations, isDownloadActive: { _ in false })
            let track = AudioTrack(
                id: "remote-track", index: 0,
                contentUrl: "https://private.invalid/audio?token=signed-secret",
                duration: 600, startOffset: 0, headers: ["Authorization": "signed-secret"]
            )
            book = Book(
                id: "42", title: "Shared audiobook", author: "Author", narrator: "Narrator",
                partKey: "https://private.invalid/signed-secret", duration: 600,
                chapters: [Chapter(id: "remote-chapter", start: 0, end: 600, title: "Opening")],
                source: .audiobookshelf, backendId: "remote-account", audioTracks: [track],
                currentTime: 400, isFinished: true, providerId: UUID(), libraryId: "remote-library"
            )
            var task = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
            task.status = .completed
            task.progress = 1
            completedTask = task
        }

        func writeAudio(for suppliedBook: Book? = nil) throws -> URL {
            let book = suppliedBook ?? self.book
            let directory = source.bookAudioDirectory(for: book.downloadKey)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("chapter_0.m4b")
            try bytes.write(to: file)
            return file
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
