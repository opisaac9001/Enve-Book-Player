import CloudKit
import Foundation
import Testing

@testable import enve

@MainActor
struct CloudKitProgressRecordTests {
    @Test func legacyAudiobookRecordDecodesWithDerivedProgress() throws {
        let record = makeRecord(name: "legacy")
        record["duration"] = 1_000
        record["playbackPosition"] = 250.0

        let decoded = try #require(PlaybackStateRecord(from: record))

        #expect(decoded.domain == .audiobook)
        #expect(decoded.normalizedProgress == 0.25)
        #expect(decoded.locator == nil)
    }

    @Test func ebookRecordPreservesProgressAndLocator() throws {
        let locator = #"{"href":"chapter-4.xhtml","locations":{"progression":0.42}}"#
        let record = makeRecord(name: "ebook", type: "BookReadingState")
        record["playbackPosition"] = 0.0
        record["normalizedProgress"] = 0.42
        record["locator"] = locator

        let decoded = try #require(PlaybackStateRecord(from: record))

        #expect(decoded.domain == .ebook)
        #expect(decoded.normalizedProgress == 0.42)
        #expect(decoded.locator == locator)
        #expect(decoded.progressPercentage == 0.42)
    }

    @Test func ebookPushUsesFreshSavedReadingLocationOverStaleCapturedBook() {
        let staleLocator = #"{"href":"chapter-1.xhtml","locations":{"progression":0.10}}"#
        let freshLocator = #"{"href":"chapter-8.xhtml","locations":{"progression":0.58}}"#
        let timestamp = Date(timeIntervalSince1970: 2_000)
        var captured = Book(
            id: "normal-reader",
            title: "Normal Reader",
            source: .local,
            mediaType: .ebook,
            lastUpdate: timestamp,
            providerId: UUID(),
            libraryId: "icloud-normal-reader-tests"
        )
        captured.ebookProgress = 0.10
        captured.epubLocator = staleLocator
        var cached = captured
        cached.ebookProgress = 0.58
        cached.epubLocator = freshLocator

        let resolved = freshestEbookProgressBook(captured: captured, cached: cached)

        #expect(resolved.ebookProgress == 0.58)
        #expect(resolved.epubLocator == freshLocator)
    }

    @Test func ebookPushKeepsNewerCapturedReadingLocationWhenCacheLags() {
        let capturedLocator = #"{"href":"chapter-9.xhtml","locations":{"progression":0.64}}"#
        let cachedLocator = #"{"href":"chapter-3.xhtml","locations":{"progression":0.21}}"#
        var captured = Book(
            id: "normal-reader-newer",
            title: "Normal Reader",
            source: .local,
            mediaType: .ebook,
            lastUpdate: Date(timeIntervalSince1970: 3_000),
            providerId: UUID(),
            libraryId: "icloud-normal-reader-tests"
        )
        captured.ebookProgress = 0.64
        captured.epubLocator = capturedLocator
        var cached = captured
        cached.lastUpdate = Date(timeIntervalSince1970: 2_000)
        cached.ebookProgress = 0.21
        cached.epubLocator = cachedLocator

        let resolved = freshestEbookProgressBook(captured: captured, cached: cached)

        #expect(resolved.ebookProgress == 0.64)
        #expect(resolved.epubLocator == capturedLocator)
    }

    @Test func localContentHashIsPreservedWithBookLocation() throws {
        let locator = #"{"href":"chapter-4.xhtml","locations":{"progression":0.42}}"#
        let record = makeRecord(name: "hashed", type: "BookReadingState")
        record["contentHash"] = "sha256-book"
        record["playbackPosition"] = 0.0
        record["normalizedProgress"] = 0.42
        record["locator"] = locator

        let decoded = try #require(PlaybackStateRecord(from: record))

        #expect(decoded.contentHash == "sha256-book")
        #expect(decoded.locator == locator)
        #expect(decoded.normalizedProgress == 0.42)
    }

    @Test func dropInAndFilesImportsResolveTheirScannedContentHash() {
        let filePath = "/tmp/Enve/Individual_Audiobooks/Author/Book/track.m4b"
        let book = Book(
            id: "imported-book",
            title: "Book",
            source: .local,
            filePath: filePath,
            providerId: UUID(),
            libraryId: LocalLibraryService.fileSharingLibraryId
        )
        let stored = LocalBookFile(
            id: "scan-record",
            fileName: "track.m4b",
            filePath: filePath,
            fileSize: 1_024,
            format: "m4b",
            fileHash: "sha256-imported"
        )

        #expect(CloudBookContentIdentity.hash(for: book, storedBooks: [stored]) == "sha256-imported")
    }

    @Test func normalizedProgressIsClampedForConsumers() throws {
        let record = makeRecord(name: "overrun", type: "BookReadingState")
        record["playbackPosition"] = 0.0
        record["normalizedProgress"] = 1.2

        let decoded = try #require(PlaybackStateRecord(from: record))

        #expect(decoded.progressPercentage == 1)
    }

    @Test func ebookRecordNameDoesNotChangeWithAudioDuration() {
        let short = CanonicalBookIdentity(title: "Shared Story", author: "A. Reader", duration: 3_600)
        let long = CanonicalBookIdentity(title: "Shared Story", author: "A. Reader", duration: 7_200)

        #expect(
            CloudKitProgressSync.recordName(for: short, domain: .ebook)
                == CloudKitProgressSync.recordName(for: long, domain: .ebook)
        )
        #expect(
            CloudKitProgressSync.recordName(for: short, domain: .audiobook)
                != CloudKitProgressSync.recordName(for: long, domain: .audiobook)
        )
    }

    @Test func newerCloudResetPullsToBeginning() {
        let direction = resolveCloudProgressConflict(
            localPosition: 0.6,
            localDate: Date(timeIntervalSince1970: 1_000),
            cloudPosition: 0,
            cloudDate: Date(timeIntervalSince1970: 2_000)
        )

        #expect(direction == .pull)
    }

    @Test func olderCloudResetDoesNotOverwriteNewerLocalProgress() {
        let direction = resolveCloudProgressConflict(
            localPosition: 0.6,
            localDate: Date(timeIntervalSince1970: 2_000),
            cloudPosition: 0,
            cloudDate: Date(timeIntervalSince1970: 1_000)
        )

        #expect(direction == .push)
    }

    @Test func newerNarratedSentencePushesEvenInsidePercentageTolerance() {
        let localLocator = #"{"href":"chapter.xhtml","locations":{"fragments":["sentence-26","t=174.8"]}}"#
        let cloudLocator = #"{"href":"chapter.xhtml","locations":{"fragments":["sentence-20","t=128.8"]}}"#
        let direction = resolveCloudProgressConflict(
            localPosition: 0.0613,
            localDate: Date(timeIntervalSince1970: 2_000),
            cloudPosition: 0.0603,
            cloudDate: Date(timeIntervalSince1970: 1_000),
            localLocator: localLocator,
            cloudLocator: cloudLocator
        )

        #expect(direction == .push)
    }

    @Test func pausedLoadedAudiobookAppliesAndSeeksCrossDeviceProgress() {
        #expect(
            cloudAudiobookMergeDisposition(isCurrentBook: true, isPlaying: false)
                == .applyAndSeek
        )
        #expect(
            cloudAudiobookMergeDisposition(isCurrentBook: true, isPlaying: true)
                == .deferWhilePlaying
        )
        #expect(
            cloudAudiobookMergeDisposition(isCurrentBook: false, isPlaying: true)
                == .apply
        )
    }

    @Test func activeReadAloudPlaybackDefersEbookCloudMerges() {
        #expect(
            shouldDeferCloudMerge(
                domain: .ebook,
                isCurrentBook: true,
                isOverlayPlaybackActive: true,
                isPlaying: true
            )
        )
        #expect(
            !shouldDeferCloudMerge(
                domain: .ebook,
                isCurrentBook: true,
                isOverlayPlaybackActive: true,
                isPlaying: false
            )
        )
        #expect(
            !shouldDeferCloudMerge(
                domain: .ebook,
                isCurrentBook: false,
                isOverlayPlaybackActive: true,
                isPlaying: true
            )
        )
        #expect(
            !shouldDeferCloudMerge(
                domain: .audiobook,
                isCurrentBook: true,
                isOverlayPlaybackActive: true,
                isPlaying: true
            )
        )
    }

    @Test func audiobookZeroPushRequiresAnExplicitLocalReset() {
        #expect(CloudKitProgressSync.shouldPushAudiobookPosition(120, storedLocalPosition: nil))
        #expect(!CloudKitProgressSync.shouldPushAudiobookPosition(0, storedLocalPosition: nil))
        #expect(CloudKitProgressSync.shouldPushAudiobookPosition(0, storedLocalPosition: 0))
        #expect(!CloudKitProgressSync.shouldPushAudiobookPosition(0, storedLocalPosition: 120))
    }

    @Test func cloudProgressEligibilityExcludesProviderManagedBooks() {
        let standaloneSources: [Book.BookSource] = [.local, .smb, .webdav, .realdebrid, .torbox]
        let providerSources: [Book.BookSource] = [
            .plex, .audiobookshelf, .jellyfin, .emby, .booklore, .komga, .kavita,
            .opds, .storyteller, .bookOrbit, .silo,
        ]

        for source in standaloneSources {
            #expect(CloudProgressEligibility.includes(makeBook(source: source)))
        }
        for source in providerSources {
            #expect(!CloudProgressEligibility.includes(makeBook(source: source)))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_ICLOUD_LIVE_RUN_ID"] != nil))
    func livePrivateDatabaseRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runID = try #require(environment["ENVE_ICLOUD_LIVE_RUN_ID"])
        let mode = try #require(environment["ENVE_ICLOUD_LIVE_MODE"])
        let audioIdentity = CanonicalBookIdentity(
            title: "Enve iCloud Audio Test \(runID)",
            author: "Enve Test",
            duration: 3_000
        )
        let ebookIdentity = CanonicalBookIdentity(
            title: "Enve iCloud Ebook Test \(runID)",
            author: "Enve Test",
            duration: nil
        )
        let service = CloudKitProgressSync.shared

        service.invalidateAccountStatusCache()
        #expect(await service.isAvailable())

        switch mode {
        case "seed":
            try await service.saveProgress(
                identity: audioIdentity,
                position: 735,
                progress: 0.245,
                locator: nil,
                domain: .audiobook,
                playbackRate: 1.25,
                lastInteractionDate: Date()
            )
            try await service.saveProgress(
                identity: ebookIdentity,
                position: 0,
                progress: 0.625,
                locator: #"{"href":"chapter-6.xhtml","locations":{"progression":0.625}}"#,
                domain: .ebook,
                lastInteractionDate: Date()
            )

            let audio = try #require(
                try await service.fetchProgress(for: audioIdentity, domain: .audiobook, bypassCache: true)
            )
            let ebook = try #require(
                try await service.fetchProgress(for: ebookIdentity, domain: .ebook, bypassCache: true)
            )
            #expect(audio.playbackPosition == 735)
            #expect(audio.normalizedProgress == 0.245)
            #expect(ebook.normalizedProgress == 0.625)

            let resetDate = Date().addingTimeInterval(1)
            let resetBook = Book(
                id: "icloud-live-reset-\(runID)",
                title: audioIdentity.originalTitle,
                author: audioIdentity.originalAuthor,
                duration: 3_000,
                source: .local,
                currentTime: 0,
                lastUpdate: resetDate,
                providerId: UUID(),
                libraryId: "icloud-live-tests"
            )
            UserProgressStore.shared.update(
                UserMediaProgress(
                    id: resetBook.id,
                    libraryItemId: resetBook.id,
                    providerId: resetBook.providerId,
                    episodeId: nil,
                    currentTime: 0,
                    progress: 0,
                    isFinished: false,
                    duration: 3_000,
                    lastUpdate: resetDate,
                    ebookProgress: nil
                )
            )
            try await service.push(
                ProgressUpdate(
                    book: resetBook,
                    domain: .audiobook,
                    positionSeconds: 0,
                    progress: 0,
                    locator: nil,
                    sourceEngine: nil,
                    sessionId: nil,
                    isFinished: false,
                    timeListened: 0,
                    playbackRate: 1
                )
            )
            let resetAudio = try #require(
                try await service.fetchProgress(for: audioIdentity, domain: .audiobook, bypassCache: true)
            )
            #expect(resetAudio.playbackPosition == 0)
            #expect(resetAudio.normalizedProgress == 0)
            UserProgressStore.shared.forget(keys: [resetBook.uniqueId])

            try await writePeerProgress(identity: audioIdentity, domain: .audiobook)
            try await writePeerProgress(identity: ebookIdentity, domain: .ebook)

            await service.registerForPushNotifications()
            #expect(service.pushSubscriptionRegistered)

        case "fetch":
            var failure: Error?
            do {
                let records = try await service.fetchAllRecords(bypassCache: true)
                let audioName = CloudKitProgressSync.recordName(for: audioIdentity, domain: .audiobook)
                let ebookName = CloudKitProgressSync.recordName(for: ebookIdentity, domain: .ebook)
                #expect(records.contains { $0.recordID == audioName })
                #expect(records.contains { $0.recordID == ebookName })

                let audio = try #require(
                    try await service.fetchProgress(for: audioIdentity, domain: .audiobook, bypassCache: true)
                )
                let ebook = try #require(
                    try await service.fetchProgress(for: ebookIdentity, domain: .ebook, bypassCache: true)
                )
                #expect(audio.playbackPosition == 1_500)
                #expect(audio.normalizedProgress == 0.5)
                #expect(audio.deviceID == "icloud-live-peer")
                #expect(ebook.normalizedProgress == 0.8125)
                #expect(ebook.locator == #"{"href":"chapter-9.xhtml","locations":{"progression":0.8125}}"#)
                #expect(ebook.deviceID == "icloud-live-peer")
            } catch {
                failure = error
            }

            await deleteLiveRecords(audioIdentity: audioIdentity, ebookIdentity: ebookIdentity)
            if let failure { throw failure }

        default:
            Issue.record("ENVE_ICLOUD_LIVE_MODE must be seed or fetch")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_ICLOUD_AUDIOBOOK_RUN_ID"] != nil))
    func liveAudiobookRestoreAfterReinstall() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runID = try #require(environment["ENVE_ICLOUD_AUDIOBOOK_RUN_ID"])
        let mode = try #require(environment["ENVE_ICLOUD_AUDIOBOOK_MODE"])
        FileSharingImportCoordinator.shared.stopWatching()
        SyncCoordinator.shared.setSyncEnabled(true)
        let book = try await importLiveAudiobook(runID: runID)
        let identity = CanonicalBookIdentity(from: book)
        let cloud = CloudKitProgressSync.shared

        cloud.invalidateAccountStatusCache()
        let cloudAvailable = await cloud.isAvailable()
        try #require(cloudAvailable)
        SyncCoordinator.shared.updateCloudAvailability(cloudAvailable)

        switch mode {
        case "seed":
            await deleteLiveAudiobookRecord(identity: identity)
            EnveEngine.shared.playback.play(book, presentPlayer: false)
            try await waitForPlayback { snapshot in
                snapshot.isLoaded && snapshot.currentBook?.stableId == book.stableId
            }

            let duration = try #require(book.duration)
            #expect(duration > 10)
            let target = Double.random(in: (duration * 0.25)...(duration * 0.75))
            ActivePlayback.controller.seek(to: target)
            try await waitForPlayback { abs($0.position - target) < 0.75 }
            ActivePlayback.controller.pause()
            BookProgressStore.shared.saveProgress(
                for: book,
                progress: target,
                duration: duration
            )

            let saved = await SyncCoordinator.shared.persistCurrentPlayback(reason: .playbackPaused)
            #expect(saved)
            let record = try #require(
                try await cloud.fetchProgress(for: identity, domain: .audiobook, bypassCache: true)
            )
            #expect(abs(record.playbackPosition - target) < 0.75)
            print("ENVE_ICLOUD_AUDIOBOOK_SEEDED position=\(record.playbackPosition) duration=\(duration)")
            ActivePlayback.controller.stop()

        case "fetch":
            cloud.invalidateCache()
            let record = try #require(
                try await cloud.fetchProgress(for: identity, domain: .audiobook, bypassCache: true)
            )
            var failure: Error?

            do {
                let restored = try #require(BookProgressStore.shared.loadProgress(for: book))
                #expect(abs(restored.progress - record.playbackPosition) < 0.01)

                EnveEngine.shared.playback.play(book, presentPlayer: false)
                try await waitForPlayback { snapshot in
                    snapshot.isLoaded && snapshot.currentBook?.stableId == book.stableId
                }
                let resumedPosition = ActivePlayback.controller.snapshot.position
                #expect(abs(resumedPosition - record.playbackPosition) < 2)
                print(
                    "ENVE_ICLOUD_AUDIOBOOK_RESTORED cloud=\(record.playbackPosition) local=\(restored.progress) playback=\(resumedPosition)"
                )
            } catch {
                failure = error
            }

            ActivePlayback.controller.stop()
            await deleteLiveAudiobookRecord(identity: identity)
            try? await LocalLibraryService.shared.deleteBookFiles(for: book)
            if let failure { throw failure }

        default:
            Issue.record("ENVE_ICLOUD_AUDIOBOOK_MODE must be seed or fetch")
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_ICLOUD_LAUNCH_RUN_ID"] != nil))
    func liveAudiobookRefreshesOnAppLaunch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let runID = try #require(environment["ENVE_ICLOUD_LAUNCH_RUN_ID"])
        let mode = try #require(environment["ENVE_ICLOUD_LAUNCH_MODE"])
        let cloud = CloudKitProgressSync.shared
        SyncCoordinator.shared.setSyncEnabled(true)

        switch mode {
        case "seed":
            FileSharingImportCoordinator.shared.stopWatching()
            let book = try await importLiveAudiobook(runID: runID)
            let identity = CanonicalBookIdentity(from: book)
            let duration = try #require(book.duration)
            let cloudPosition = duration * 0.6137

            await deleteLiveAudiobookRecord(identity: identity)
            try await cloud.saveProgress(
                identity: identity,
                position: cloudPosition,
                progress: cloudPosition / duration,
                locator: nil,
                domain: .audiobook,
                lastInteractionDate: Date().addingTimeInterval(5)
            )
            BookProgressStore.shared.saveProgress(
                for: book,
                progress: duration * 0.1,
                duration: duration,
                at: Date(timeIntervalSince1970: 1)
            )
            print("ENVE_ICLOUD_LAUNCH_SEEDED position=\(cloudPosition)")

        case "fetch":
            let book = try await waitForImportedBook(runID: runID)
            let identity = CanonicalBookIdentity(from: book)
            let record = try #require(
                try await cloud.fetchProgress(for: identity, domain: .audiobook, bypassCache: true)
            )
            let restored = try await waitForStoredProgress(
                book: book,
                expected: record.playbackPosition
            )
            #expect(abs(restored - record.playbackPosition) < 0.01)
            print("ENVE_ICLOUD_LAUNCH_RESTORED cloud=\(record.playbackPosition) local=\(restored)")

            await deleteLiveAudiobookRecord(identity: identity)
            try? await LocalLibraryService.shared.deleteBookFiles(for: book)

        default:
            Issue.record("ENVE_ICLOUD_LAUNCH_MODE must be seed or fetch")
        }
    }

    private func importLiveAudiobook(runID: String) async throws -> Book {
        let source = try #require(
            Bundle.main.url(forResource: "ambient-fireplace", withExtension: "mp3")
        )
        let destination = LocalLibraryService.fileSharingRootURL
            .appendingPathComponent("Enve-iCloud-Restore-\(runID).mp3")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)

        let result = try await LocalLibraryService.shared.scanCanonicalLibrary()
        let imported = try #require(
            result.booksFound.first { $0.fileName == destination.lastPathComponent }
        )
        let libraryId = LocalLibraryService.fileSharingLibraryId
        LocalLibraryStorageStore.shared.saveLibrary(
            LocalLibrary(
                id: libraryId,
                name: "Drag & Drop Books",
                folderPath: LocalLibraryService.fileSharingRootURL.path,
                isEnabled: true,
                type: .fileSharing
            )
        )
        LocalLibraryStorageStore.shared.saveScanResult(result)
        await LibraryCatalogCoordinator.shared.refreshLocalLibraries()

        let scannedBook = imported.toBook(libraryId: libraryId)
        return try #require(AppState.shared.bookInMemory(stableId: scannedBook.stableId))
    }

    private func waitForPlayback(
        timeout: Duration = .seconds(15),
        condition: (PlaybackSnapshot) -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let snapshot = ActivePlayback.controller.snapshot
            if condition(snapshot) { return }
            if let error = snapshot.errorDescription {
                throw NSError(
                    domain: "CloudKitProgressRecordTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: error]
                )
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "CloudKitProgressRecordTests",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for audiobook playback state"]
        )
    }

    private func waitForImportedBook(runID: String) async throws -> Book {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if let book = AppState.shared.allBooks.first(where: {
                $0.filePath.map { URL(fileURLWithPath: $0).lastPathComponent.contains(runID) } == true
            }) {
                return book
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "CloudKitProgressRecordTests",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the persisted audiobook on launch"]
        )
    }

    private func waitForStoredProgress(book: Book, expected: TimeInterval) async throws -> TimeInterval {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            if let progress = BookProgressStore.shared.loadProgress(for: book)?.progress,
                abs(progress - expected) < 0.01
            {
                return progress
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(
            domain: "CloudKitProgressRecordTests",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for automatic app-launch iCloud progress"]
        )
    }

    private func deleteLiveAudiobookRecord(identity: CanonicalBookIdentity) async {
        let database = CKContainer(identifier: "iCloud.com.enve.enve").privateCloudDatabase
        _ = try? await database.deleteRecord(
            withID: liveRecordID(for: identity, domain: .audiobook)
        )
    }

    private func writePeerProgress(identity: CanonicalBookIdentity, domain: ProgressSyncDomain) async throws {
        let database = CKContainer(identifier: "iCloud.com.enve.enve").privateCloudDatabase
        let recordID = liveRecordID(for: identity, domain: domain)
        let record = try await database.record(for: recordID)
        record["lastUpdated"] = Date().addingTimeInterval(5)
        record["deviceID"] = "icloud-live-peer"
        record["deviceName"] = "iCloud Live Peer"

        switch domain {
        case .audiobook:
            record["playbackPosition"] = 1_500.0
            record["normalizedProgress"] = 0.5
        case .ebook:
            record["normalizedProgress"] = 0.8125
            record["locator"] = #"{"href":"chapter-9.xhtml","locations":{"progression":0.8125}}"#
        }

        _ = try await database.save(record)
    }

    private func deleteLiveRecords(
        audioIdentity: CanonicalBookIdentity,
        ebookIdentity: CanonicalBookIdentity
    ) async {
        let database = CKContainer(identifier: "iCloud.com.enve.enve").privateCloudDatabase
        for (identity, domain) in [(audioIdentity, ProgressSyncDomain.audiobook), (ebookIdentity, .ebook)] {
            _ = try? await database.deleteRecord(withID: liveRecordID(for: identity, domain: domain))
        }
    }

    private func liveRecordID(
        for identity: CanonicalBookIdentity,
        domain: ProgressSyncDomain
    ) -> CKRecord.ID {
        let zoneID = CKRecordZone.ID(zoneName: "BookProgressZone", ownerName: CKCurrentUserDefaultName)
        let name = CloudKitProgressSync.recordName(for: identity, domain: domain)
        return CKRecord.ID(recordName: name, zoneID: zoneID)
    }

    private func makeRecord(name: String, type: CKRecord.RecordType = "BookPlaybackState") -> CKRecord {
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name))
        record["title"] = "The Test Book"
        record["author"] = "Example Author"
        record["normalizedTitle"] = "the test book"
        record["normalizedAuthor"] = "example author"
        record["duration"] = 0
        record["playbackPosition"] = 0.0
        record["lastUpdated"] = Date(timeIntervalSince1970: 1_000)
        record["playbackRate"] = 1.0
        record["completed"] = false
        record["deviceID"] = "device-a"
        record["deviceName"] = "Test iPhone"
        return record
    }

    private func makeBook(source: Book.BookSource) -> Book {
        Book(
            id: source.rawValue,
            title: "Cloud eligibility",
            source: source,
            mediaType: .audiobook,
            providerId: UUID(),
            libraryId: "cloud-eligibility"
        )
    }
}
