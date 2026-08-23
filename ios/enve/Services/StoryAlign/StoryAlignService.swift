import BackgroundTasks
import Foundation
import Logging
import Speech
import StoryAlignCore
import SwiftUI
import UIKit
import os

private struct StoryAlignOSLogger: StoryAlignCore.Logger {
    private let log = os.Logger(subsystem: "com.enve.enve", category: "StoryAlign")

    func log(
        _ level: StoryAlignCore.LogLevel,
        _ message: @autoclosure () -> String,
        file: String,
        function: String,
        line: Int,
        indentLevel: Int
    ) {
        let text = message()
        switch level {
        case .debug: log.debug("\(text, privacy: .public)")
        case .info, .timestamp: log.notice("\(text, privacy: .public)")
        case .warn: log.warning("\(text, privacy: .public)")
        case .error: log.error("\(text, privacy: .public)")
        }
        FileHandle.standardError.write("[StoryAlign][\(level.rawValue.uppercased())] \(text)\n".data(using: .utf8) ?? Data())
    }
}

private enum StoryAlignSpeechAuthorization {
    static func requestStatus() async -> SFSpeechRecognizerAuthorizationStatus {
        await Task.detached(priority: nil) {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status)
                }
            }
        }.value
    }
}

enum StoryAlignLaunchWarning {
    static let title = "Heads up, this will take a while"
    static let message =
        "StoryAlign listens to the full audiobook and lines it up with the ebook text. This can take a while on iPhone, so keeping your phone plugged in is recommended. You can leave the app while it runs, but try not to force-close it or leave it idle for too long, or it may stop. For faster results, you can use the Storyteller server or run StoryAlign on a Mac. Links are at the bottom of this page."
}

@available(iOS 26.0, *)
@MainActor @Observable
final class StoryAlignService {
    static let shared = StoryAlignService()

    private let libraryCache: LibraryBookCache
    private let bookRepository: BookStoreRepository

    private init(
        libraryCache: LibraryBookCache = AppState.shared.libraryCache,
        bookRepository: BookStoreRepository = AppState.shared.bookStore
    ) {
        self.libraryCache = libraryCache
        self.bookRepository = bookRepository
    }

    var activeConversion: ConversionState?

    struct ConversionState: Equatable {
        let ebookStableId: String
        let audiobookStableId: String
        var stage: String
        var progress: Double
        var detailText: String?
        var isComplete: Bool = false
        var error: String?
        var technicalError: String?
        var isDownloadPhase: Bool = false
        let startedAt: Date
        var elapsedTime: TimeInterval?
    }

    struct CompletedConversion: Identifiable, Sendable {
        let id: String
        let ebook: Book
        let audiobook: Book
        let url: URL
    }

    struct PausedConversion: Codable {
        let ebookStableId: String
        let audiobookStableId: String
    }

    private(set) var pausedConversion: PausedConversion? {
        didSet { savePausedConversion() }
    }

    private static let pausedConversionKey = "storyalign.pausedConversion"

    private func savePausedConversion() {
        if let paused = pausedConversion,
            let data = try? JSONEncoder().encode(paused)
        {
            UserDefaults.standard.set(data, forKey: Self.pausedConversionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.pausedConversionKey)
        }
    }

    func loadPausedConversion() {
        guard let data = UserDefaults.standard.data(forKey: Self.pausedConversionKey),
            let paused = try? JSONDecoder().decode(PausedConversion.self, from: data)
        else { return }
        pausedConversion = paused
    }

    private static let bgTaskIdentifier = "com.enve.enve.storyalign"

    private var currentTask: Task<Void, Never>?
    private var currentSession: AlignmentSession?
    #if !targetEnvironment(macCatalyst)
    private var continuedTask: BGContinuedProcessingTask?
    #endif
    private var bgTaskExpired = false
    private var didDisableIdleTimer = false

    #if !targetEnvironment(macCatalyst)
    func handleContinuedProcessingTask(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        task.progress.totalUnitCount = 100
        task.expirationHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleBackgroundTaskExpiration()
            }
        }
    }
    #endif

    func canConvert(ebook: Book, audiobook: Book) -> Bool {
        guard ebook.mediaType == .ebook, audiobook.mediaType == .audiobook else { return false }
        return true
    }

    func needsDownload(ebook: Book, audiobook: Book) -> (ebook: Bool, audiobook: Bool) {
        return (ebook: resolveEpubURL(ebook) == nil, audiobook: resolveAudioURLs(audiobook) == nil)
    }

    func isConverted(ebook: Book, audiobook: Book) -> Bool {
        return cachedNarratedEpubURL(ebook: ebook, audiobook: audiobook) != nil
    }

    func cachedNarratedEpubURL(ebook: Book, audiobook: Book) -> URL? {
        return Self.cachedNarratedEpubURL(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId)
    }

    func cancelConversion() {
        currentTask?.cancel()
        currentTask = nil
        currentSession?.cleanup()
        currentSession = nil
        activeConversion = nil
        pausedConversion = nil
        endExecutionProtection(success: false)
    }

    func resumeConversion(ebook: Book, audiobook: Book) {
        pausedConversion = nil
        downloadAndConvert(ebook: ebook, audiobook: audiobook)
    }

    func dismissConversion() {
        activeConversion = nil
        currentTask = nil
        currentSession = nil
        endExecutionProtection(success: true)
    }

    private func beginExecutionProtection() {
        bgTaskExpired = false

        #if !targetEnvironment(macCatalyst)
        if !UIApplication.shared.isIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = true
            didDisableIdleTimer = true
        }

        guard continuedTask == nil else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.bgTaskIdentifier,
            title: "StoryAlign",
            subtitle: "Starting\u{2026}"
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            AppLogger.general.error("[StoryAlign] BGContinuedProcessingTask submit failed: \(error.localizedDescription)")
        }
        #endif
    }

    private func endExecutionProtection(success: Bool) {
        #if !targetEnvironment(macCatalyst)
        if let task = continuedTask {
            task.setTaskCompleted(success: success)
            continuedTask = nil
        }

        if didDisableIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = false
            didDisableIdleTimer = false
        }
        #endif

        bgTaskExpired = false
    }

    private func handleBackgroundTaskExpiration() {
        bgTaskExpired = true
        currentTask?.cancel()
        currentTask = nil

        currentSession = nil
        if let active = activeConversion {
            pausedConversion = PausedConversion(
                ebookStableId: active.ebookStableId,
                audiobookStableId: active.audiobookStableId
            )
        }
        activeConversion?.stage = "Paused"
        activeConversion?.error = AlignError.backgroundExpired.localizedDescription
        activeConversion?.isDownloadPhase = false
        activeConversion?.detailText = nil
        endExecutionProtection(success: false)
    }

    func downloadAndConvert(ebook: Book, audiobook: Book) {
        guard activeConversion == nil else { return }
        guard ebook.mediaType == .ebook, audiobook.mediaType == .audiobook else { return }

        beginExecutionProtection()

        let ebookId = ebook.stableId
        let audiobookId = audiobook.stableId

        activeConversion = ConversionState(
            ebookStableId: ebookId,
            audiobookStableId: audiobookId,
            stage: "Preparing",
            progress: 0,
            detailText: nil,
            isDownloadPhase: false,
            startedAt: Date()
        )

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let speechAnalyzerConfig = self.currentSpeechAnalyzerConfig()
                if resolveEpubURL(ebook) == nil {
                    await MainActor.run {
                        self.activeConversion?.stage = "Downloading Ebook"
                        self.activeConversion?.isDownloadPhase = true
                        self.activeConversion?.progress = 0
                        self.activeConversion?.detailText = nil
                    }
                    await UnifiedDownloadService.shared.download(book: ebook)
                    try await awaitEbookDownload(ebook)
                }

                if Task.isCancelled { throw CancellationError() }

                if resolveAudioURLs(audiobook) == nil {
                    await MainActor.run {
                        self.activeConversion?.stage = "Downloading Audiobook"
                        self.activeConversion?.isDownloadPhase = true
                        self.activeConversion?.progress = 0
                        self.activeConversion?.detailText = nil
                    }
                    await UnifiedDownloadService.shared.download(book: audiobook)
                    try await awaitAudiobookDownload(audiobook)
                }

                if Task.isCancelled { throw CancellationError() }

                await MainActor.run {
                    self.activeConversion?.isDownloadPhase = false
                    self.activeConversion?.detailText = nil
                }

                try await ensureSpeechAuthorization()
                guard let epubURL = try await prepareEpubURL(ebook),
                    let audioURLs = resolveAudioURLs(audiobook)
                else {
                    throw AlignError.missingFiles
                }
                try await runAlignment(
                    ebookId: ebookId,
                    audiobookId: audiobookId,
                    epubURL: epubURL,
                    audioURLs: audioURLs,
                    ebook: ebook,
                    audiobook: audiobook,
                    speechAnalyzerConfig: speechAnalyzerConfig
                )
            } catch is CancellationError {
                await MainActor.run {
                    if self.bgTaskExpired {
                        self.activeConversion?.error = AlignError.backgroundExpired.localizedDescription
                        self.activeConversion?.stage = "Failed"
                        self.activeConversion?.isDownloadPhase = false
                        self.activeConversion?.detailText = nil
                        self.bgTaskExpired = false
                    } else {
                        self.activeConversion = nil
                    }
                    self.currentSession?.cleanup()
                    self.currentSession = nil
                    self.endExecutionProtection(success: false)
                }
            } catch {
                await MainActor.run {
                    self.activeConversion?.error = self.userFacingErrorMessage(for: error)
                    self.activeConversion?.technicalError = self.rawErrorString(for: error)
                    self.activeConversion?.stage = "Failed"
                    self.activeConversion?.isDownloadPhase = false
                    self.activeConversion?.detailText = nil
                    self.currentSession?.cleanup()
                    self.currentSession = nil
                    self.endExecutionProtection(success: false)
                }
            }
        }
    }

    private func awaitEbookDownload(_ book: Book) async throws {
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            if resolveEpubURL(book) != nil { return }
            let failed = await MainActor.run {
                UnifiedDownloadService.shared.tasks
                    .first(where: { $0.bookId == book.downloadKey })
                    .map { $0.status == .failed } ?? false
            }
            if failed { throw AlignError.downloadFailed }
            await updateDownloadProgress(for: book)
            try await Task.sleep(for: .milliseconds(400))
        }
        throw AlignError.downloadTimeout
    }

    private func awaitAudiobookDownload(_ book: Book) async throws {
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            let ready = await MainActor.run {
                LocalStorageManager.shared.isAudiobookDownloaded(book.downloadKey)
            }
            if ready { return }
            let failed = await MainActor.run {
                UnifiedDownloadService.shared.tasks
                    .first(where: { $0.bookId == book.downloadKey })
                    .map { $0.status == .failed } ?? false
            }
            if failed { throw AlignError.downloadFailed }
            await updateDownloadProgress(for: book)
            try await Task.sleep(for: .milliseconds(400))
        }
        throw AlignError.downloadTimeout
    }

    private func updateDownloadProgress(for book: Book) async {
        let task = await MainActor.run {
            UnifiedDownloadService.shared.tasks
                .first(where: { $0.bookId == book.downloadKey })
        }
        await MainActor.run {
            self.activeConversion?.progress = task?.progress ?? 0
            self.activeConversion?.detailText = task?.progressText
        }
    }

    private func ensureSpeechAuthorization() async throws {
        #if targetEnvironment(simulator)
        throw AlignError.simulatorUnsupported
        #else
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        if currentStatus == .authorized {
            return
        }

        let status = await StoryAlignSpeechAuthorization.requestStatus()

        guard status == .authorized else {
            throw AlignError.speechAuthorizationDenied
        }
        #endif
    }

    private func rawErrorString(for error: Error) -> String {
        if error is AlignError { return "" }
        let localized = (error as? LocalizedError)?.errorDescription ?? ""
        let raw = String(describing: error)
        return localized.isEmpty ? raw : "\(localized)\n\n\(raw)"
    }

    private func userFacingErrorMessage(for error: Error) -> String {
        if let alignError = error as? AlignError {
            return alignError.localizedDescription
        }

        let message = {
            if let localized = (error as? LocalizedError)?.errorDescription,
                !localized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return localized
            }
            return String(describing: error)
        }()
        let lowercasedMessage = message.lowercased()

        if lowercasedMessage.contains("missingendofcentraldirectoryrecord") {
            return "The ebook file appears to be corrupt or invalid. Try re-downloading the ebook and starting StoryAlign again."
        }
        if lowercasedMessage.contains("invalid name") || lowercasedMessage.contains("invalid filename") {
            return
                "StoryAlign could not create one of its working files. Try importing the ebook again, or rename the source file with plain letters and numbers before starting alignment."
        }

        #if targetEnvironment(simulator)
        if lowercasedMessage.contains("not subscribed to transcription") || lowercasedMessage.contains("cannot check the download status") {
            return AlignError.simulatorUnsupported.localizedDescription
        }
        #else
        if lowercasedMessage.contains("not subscribed to transcription") || lowercasedMessage.contains("cannot check the download status") {
            return
                "StoryAlign could not start Apple's on-device transcription service. This usually means the device does not support on-device recognition, or the speech model for this language hasn't been downloaded yet. Go to Settings → General → Language & Region and ensure your language is set, then try again. If the problem persists, your device hardware may not support this feature."
        }
        #endif

        return message
    }

    private func currentSpeechAnalyzerConfig() -> SpeechAnalyzerConfig {
        SpeechAnalyzerConfig(bias: .fast)
    }

    private func runAlignment(
        ebookId: String,
        audiobookId: String,
        epubURL: URL,
        audioURLs: [URL],
        ebook: Book,
        audiobook: Book,
        speechAnalyzerConfig: SpeechAnalyzerConfig
    ) async throws {
        let outputDir = cacheDirectory(ebook: ebook, audiobook: audiobook)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let preparedEpubURL = try prepareStoryAlignInputEpub(epubURL, in: outputDir)

        let request = try AlignmentRequest(
            epubURL: preparedEpubURL,
            audioBookURLs: audioURLs,
            sessionDir: outputDir.path
        )
        let config = AlignmentConfig(
            audioLoaderType: .avfoundation,
            concurrency: 0,
            reportType: .none,
            granularity: .sentence
        )
        let transcriptionStore = DiskTranscriptionStore(
            directory: outputDir.appendingPathComponent("transcription-cache", isDirectory: true)
        )
        let session = AlignmentSession(
            request: request,
            config: config,
            logger: StoryAlignOSLogger(),
            speechAnalyzerConfig: speechAnalyzerConfig,
            transcriptionStore: transcriptionStore
        )
        await MainActor.run { self.currentSession = session }

        let listener = ProgressBridge { [weak self] snapshot in
            Task { @MainActor in
                let stage = snapshot.stage.rawValue.capitalized
                self?.activeConversion?.stage = stage
                self?.activeConversion?.progress = snapshot.timeEstimateProgress()
                self?.activeConversion?.detailText = nil
                #if !targetEnvironment(macCatalyst)
                if let bgTask = self?.continuedTask {
                    bgTask.progress.completedUnitCount = Int64(snapshot.timeEstimateProgress() * 100)
                    bgTask.updateTitle("StoryAlign", subtitle: stage)
                }
                #endif
            }
        }
        session.addProgressListener(listener)

        let result = try await StoryAligner().alignStory(session: session)
        let alignedEpubURL = result.alignedEpubURL
        await MainActor.run {
            let elapsed = self.activeConversion.map { Date().timeIntervalSince($0.startedAt) }
            self.registerReadAloudBook(ebook: ebook, audiobook: audiobook, epubURL: alignedEpubURL)
            self.activeConversion?.stage = "Complete"
            self.activeConversion?.progress = 1.0
            self.activeConversion?.elapsedTime = elapsed
            self.activeConversion?.isComplete = true
            self.currentSession = nil
            self.endExecutionProtection(success: true)
        }
    }

    private func prepareStoryAlignInputEpub(_ source: URL, in outputDir: URL) throws -> URL {
        let inputDir = outputDir.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
        let destination = inputDir.appendingPathComponent("source.epub")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func deleteConversion(ebook: Book, audiobook: Book) {
        for dir in Self.cacheDirectories(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId) {
            try? FileManager.default.removeItem(at: dir)
        }
        unregisterReadAloudBook(forSourceStableId: ebook.stableId)
    }

    func deleteConversions(involving book: Book) {
        let stableId = book.stableId
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: Self.cacheRoot,
                includingPropertiesForKeys: nil
            )
        else { return }
        let legacyComponent = Self.legacyCacheComponent(stableId)
        for entry in entries {
            let shouldDelete =
                Self.cachePair(from: entry)?.contains(stableId) == true
                || Self.legacyCacheKey(entry.lastPathComponent, containsComponent: legacyComponent)
            if shouldDelete {
                try? FileManager.default.removeItem(at: entry)
            }
        }
        unregisterReadAloudBook(forSourceStableId: stableId)
    }

    func deleteAllConversions() {
        try? FileManager.default.removeItem(at: Self.cacheRoot)
        Task.detached(priority: .utility) {
            let readAloud = await self.bookRepository.firstBooksWithReadAloudSource(limit: 5000)
            let ids = Set(readAloud.map(\.uniqueId))
            await MainActor.run {
                for id in ids {
                    self.libraryCache.hot.remove(uniqueId: id)
                }
            }
            if !ids.isEmpty {
                await self.bookRepository.deleteBooks(uniqueIds: ids)
            }
            await LibraryCatalogCoordinator.shared.flushLocalBooksToCache()
        }
    }

    static let readAloudLibraryId = "__storyalign_readaloud__"

    @MainActor
    private func registerReadAloudBook(ebook: Book, audiobook: Book, epubURL: URL) {
        let readAloudBook = Book(
            id: "storyalign_\(ebook.id)",
            title: "\(ebook.title)",
            author: ebook.author,
            narrator: audiobook.narrator ?? audiobook.author,
            thumb: ebook.thumb,
            partKey: ebook.partKey,
            duration: audiobook.duration,
            source: ebook.source,
            backendId: ebook.backendId,
            filePath: epubURL.path,
            mediaType: .ebook,
            ebookFileURL: epubURL,
            linkedAudiobookStableId: audiobook.stableId,
            epub3Features: EPUB3Features(hasMediaOverlay: true, smilFileCount: 1),
            readAloudSourceStableId: ebook.stableId,
            description: ebook.description,
            series: ebook.series,
            seriesNumber: ebook.seriesNumber,
            publishedYear: ebook.publishedYear,
            genres: ebook.genres,
            publisher: ebook.publisher,
            addedAt: Date(),
            libraryName: "Read Aloud",
            backendName: ebook.backendName,
            language: ebook.language,
            providerId: ebook.providerId,
            libraryId: Self.readAloudLibraryId
        )

        self.libraryCache.hot.insert(readAloudBook)
        Task.detached(priority: .utility) {
            let existing = await self.bookRepository.firstBooksWithReadAloudSource(limit: 5000)
            let staleIds = Set(
                existing.filter { $0.readAloudSourceStableId == ebook.stableId && $0.uniqueId != readAloudBook.uniqueId }.map(\.uniqueId)
            )
            if !staleIds.isEmpty {
                await self.bookRepository.deleteBooks(uniqueIds: staleIds)
            }
            await self.bookRepository.upsertBooks([readAloudBook])
        }
    }

    @MainActor
    private func unregisterReadAloudBook(forSourceStableId stableId: String) {
        Task.detached(priority: .utility) {
            let readAloud = await self.bookRepository.firstBooksWithReadAloudSource(limit: 5000)
            let removedIds = Set(readAloud.filter { $0.readAloudSourceStableId == stableId }.map(\.uniqueId))
            await MainActor.run {
                for id in removedIds { self.libraryCache.hot.remove(uniqueId: id) }
            }
            if !removedIds.isEmpty {
                await self.bookRepository.deleteBooks(uniqueIds: removedIds)
            }
            await LibraryCatalogCoordinator.shared.flushLocalBooksToCache()
        }
    }

    func completedConversions() async -> [CompletedConversion] {
        let pairs = Self.completedCachePairs()
        let readAloudBooks = await self.bookRepository.firstBooksWithReadAloudSource(limit: 5000)
        guard !pairs.isEmpty || !readAloudBooks.isEmpty else { return [] }

        var resultsById: [String: CompletedConversion] = [:]
        for pair in pairs {
            async let ebook = self.bookRepository.book(stableId: pair.ebookStableId)
            async let audiobook = self.bookRepository.book(stableId: pair.audiobookStableId)
            guard let ebook = await ebook,
                ebook.mediaType == .ebook,
                let audiobook = await audiobook,
                audiobook.mediaType == .audiobook,
                let url = Self.cachedNarratedEpubURL(ebookStableId: pair.ebookStableId, audiobookStableId: pair.audiobookStableId)
            else {
                continue
            }
            resultsById[pair.id] = CompletedConversion(
                id: pair.id,
                ebook: ebook,
                audiobook: audiobook,
                url: url
            )
        }

        for readAloud in readAloudBooks {
            guard let sourceStableId = readAloud.readAloudSourceStableId,
                let audiobookStableId = readAloud.linkedAudiobookStableId,
                let url = readAloud.ebookFileURL ?? readAloud.filePath.map(URL.init(fileURLWithPath:)),
                FileManager.default.fileExists(atPath: url.path)
            else {
                continue
            }
            let pair = CachePair(ebookStableId: sourceStableId, audiobookStableId: audiobookStableId)
            guard resultsById[pair.id] == nil else { continue }

            async let ebook = self.bookRepository.book(stableId: sourceStableId)
            async let audiobook = self.bookRepository.book(stableId: audiobookStableId)
            guard let ebook = await ebook,
                ebook.mediaType == .ebook,
                let audiobook = await audiobook,
                audiobook.mediaType == .audiobook
            else {
                continue
            }
            resultsById[pair.id] = CompletedConversion(
                id: pair.id,
                ebook: ebook,
                audiobook: audiobook,
                url: url
            )
        }

        return resultsById.values.sorted {
            $0.ebook.title.localizedStandardCompare($1.ebook.title) == .orderedAscending
        }
    }

    @MainActor
    func syncReadAloudLibrary() {
        Task { @MainActor in
            let completed = await completedConversions()
            let readAloudBooks = await self.bookRepository.firstBooksWithReadAloudSource(limit: 5000)
            let existingSourceIds = Set(readAloudBooks.compactMap(\.readAloudSourceStableId))
            let sourceBooksByStableId = await self.bookRepository.booksByStableIds(existingSourceIds)

            for conversion in completed {
                guard !existingSourceIds.contains(conversion.ebook.stableId) else { continue }
                registerReadAloudBook(ebook: conversion.ebook, audiobook: conversion.audiobook, epubURL: conversion.url)
            }

            let toRemove = readAloudBooks.filter { book in
                guard let sourceStableId = book.readAloudSourceStableId else { return false }
                guard let epubURL = book.ebookFileURL else { return true }
                if !FileManager.default.fileExists(atPath: epubURL.path) { return true }
                return sourceBooksByStableId[sourceStableId] == nil
            }
            if !toRemove.isEmpty {
                let removeIds = Set(toRemove.map(\.uniqueId))
                for id in removeIds { self.libraryCache.hot.remove(uniqueId: id) }
                Task.detached(priority: .utility) {
                    await self.bookRepository.deleteBooks(uniqueIds: removeIds)
                    await LibraryCatalogCoordinator.shared.flushLocalBooksToCache()
                }
            }
        }
    }

    func syncReadAloudLibraryOnLaunch() async {
        await MainActor.run {
            self.syncReadAloudLibrary()
        }
    }

    private nonisolated static let cacheRoot: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Enve/StoryAlignCache", isDirectory: true)
    }()

    private nonisolated struct CachePair: Hashable {
        let ebookStableId: String
        let audiobookStableId: String

        var id: String { "\(ebookStableId)|\(audiobookStableId)" }

        func contains(_ stableId: String) -> Bool {
            ebookStableId == stableId || audiobookStableId == stableId
        }
    }

    private nonisolated static func cachedNarratedEpubURL(ebookStableId: String, audiobookStableId: String) -> URL? {
        for dir in cacheDirectories(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId) {
            let epubFiles = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension.lowercased() == "epub"
            }
            if let epub = epubFiles?.first {
                return epub
            }
        }
        return nil
    }

    private nonisolated static func cacheDirectory(ebookStableId: String, audiobookStableId: String) -> URL {
        cacheRoot.appendingPathComponent(cacheKey(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId), isDirectory: true)
    }

    private nonisolated static func cacheDirectories(ebookStableId: String, audiobookStableId: String) -> [URL] {
        let current = cacheDirectory(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)
        let legacy = cacheRoot.appendingPathComponent(
            legacyCacheKey(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId),
            isDirectory: true
        )
        return current == legacy ? [current] : [current, legacy]
    }

    private nonisolated static func completedCachePairs() -> [CachePair] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: cacheRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var pairs: [CachePair] = []
        pairs.reserveCapacity(entries.count)

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                let pair = cachePair(from: entry)
            else {
                continue
            }
            pairs.append(pair)
        }

        return Array(Set(pairs))
    }

    private nonisolated static func cachePair(from directory: URL) -> CachePair? {
        let key = directory.lastPathComponent
        let parts = key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
            let ebookStableId = decodeCacheComponent(String(parts[0])),
            let audiobookStableId = decodeCacheComponent(String(parts[1]))
        else {
            return nil
        }
        return CachePair(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)
    }

    private nonisolated static func legacyCachePair(from directory: URL, booksByLegacyComponent: [String: [Book]]) -> CachePair? {
        let key = directory.lastPathComponent
        for index in key.indices where key[index] == "_" {
            let ebookComponent = String(key[..<index])
            let audiobookComponent = String(key[key.index(after: index)...])
            guard let ebook = booksByLegacyComponent[ebookComponent]?.first(where: { $0.mediaType == .ebook }),
                let audiobook = booksByLegacyComponent[audiobookComponent]?.first(where: { $0.mediaType == .audiobook })
            else {
                continue
            }
            return CachePair(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId)
        }
        return nil
    }

    private nonisolated static func legacyCacheKey(_ key: String, containsComponent component: String) -> Bool {
        for index in key.indices where key[index] == "_" {
            let ebookComponent = String(key[..<index])
            let audiobookComponent = String(key[key.index(after: index)...])
            if ebookComponent == component || audiobookComponent == component {
                return true
            }
        }
        return false
    }

    private nonisolated static func cacheKey(ebookStableId: String, audiobookStableId: String) -> String {
        "\(encodeCacheComponent(ebookStableId)).\(encodeCacheComponent(audiobookStableId))"
    }

    private nonisolated static func encodeCacheComponent(_ stableId: String) -> String {
        Data(stableId.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private nonisolated static func decodeCacheComponent(_ component: String) -> String? {
        var base64 =
            component
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func legacyCacheKey(ebookStableId: String, audiobookStableId: String) -> String {
        "\(legacyCacheComponent(ebookStableId))_\(legacyCacheComponent(audiobookStableId))"
    }

    private nonisolated static func legacyCacheComponent(_ stableId: String) -> String {
        stableId
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }

    private func cacheDirectory(ebook: Book, audiobook: Book) -> URL {
        Self.cacheDirectory(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId)
    }

    private func resolveEpubURL(_ book: Book) -> URL? {
        LocalEbookImporter.shared.resolveExistingLocalEbookURL(
            bookIdentifier: book.id,
            ebookFileURL: book.ebookFileURL,
            filePath: book.filePath
        )
    }

    private func prepareEpubURL(_ book: Book) async throws -> URL? {
        guard let url = resolveEpubURL(book) else {
            return nil
        }

        let pathExtension = url.pathExtension.lowercased()
        guard EbookFormat.mobiExtensions.contains(pathExtension) else {
            return url
        }

        activeConversion?.stage = "Converting Ebook"
        activeConversion?.detailText = url.lastPathComponent
        activeConversion?.isDownloadPhase = false
        return try await LocalEbookImporter.shared.convertMobiToEpub(url)
    }

    private func resolveAudioURLs(_ book: Book) -> [URL]? {
        if let urls = LocalStorageManager.shared.localAudiobookFilesIfExists(for: book), !urls.isEmpty {
            return urls
        }

        let fileManager = FileManager.default
        let trackURLs = (book.audioTracks ?? [])
            .compactMap(\.filePath)
            .map(URL.init(fileURLWithPath:))
            .filter { fileManager.isReadableFile(atPath: $0.path) }

        if !trackURLs.isEmpty {
            return trackURLs
        }

        if let filePath = book.filePath,
            fileManager.isReadableFile(atPath: filePath)
        {
            return [URL(fileURLWithPath: filePath)]
        }

        return nil
    }

    func cleanupOrphanedCaches(allBooks: [Book]) {
        guard FileManager.default.fileExists(atPath: Self.cacheRoot.path) else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: Self.cacheRoot, includingPropertiesForKeys: nil) else {
            return
        }
        let stableIds = Set(allBooks.map(\.stableId))
        let booksByLegacyComponent = Dictionary(grouping: allBooks, by: { Self.legacyCacheComponent($0.stableId) })
        for dir in contents {
            guard let pair = Self.cachePair(from: dir) ?? Self.legacyCachePair(from: dir, booksByLegacyComponent: booksByLegacyComponent)
            else {
                continue
            }
            if !stableIds.contains(pair.ebookStableId) || !stableIds.contains(pair.audiobookStableId) {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }
}

private struct DiskTranscriptionStore: TranscriptionStore {
    let directory: URL

    func store(data: Data, key: String, context: TranscriptionStoreContext) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(key)
        try data.write(to: file, options: .atomic)
    }

    func fetch(key: String, context: TranscriptionStoreContext) async throws -> Data? {
        let file = directory.appendingPathComponent(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }
}

private struct ProgressBridge: ProgressListener, Sendable {
    let handler: @Sendable (ProgressSnapshot) -> Void

    func show(_ snapshot: ProgressSnapshot) {
        handler(snapshot)
    }
}

enum AlignError: LocalizedError {
    case missingFiles
    case downloadFailed
    case downloadTimeout
    case speechAuthorizationDenied
    case simulatorUnsupported
    case backgroundExpired

    var errorDescription: String? {
        switch self {
        case .missingFiles: return "Could not locate ebook or audiobook files."
        case .downloadFailed: return "Download failed. Check your connection and try again."
        case .downloadTimeout: return "Download timed out. Please try again."
        case .speechAuthorizationDenied: return "Speech Recognition permission is required to create a read-aloud EPUB."
        case .simulatorUnsupported:
            return
                "StoryAlign alignment is not available in the iOS Simulator. Use a physical device to run the transcription and alignment step."
        case .backgroundExpired:
            return "The system ended StoryAlign\u{2019}s background session. Try again while plugged in and with fewer apps running."
        }
    }
}
