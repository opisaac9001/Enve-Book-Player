import BackgroundTasks
import Foundation
import Logging
import ReadiumZIPFoundation
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

enum StoryAlignMethod: String, Codable, CaseIterable, Identifiable {
    case quartzNet = "quartznet"
    case appleSpeech = "appleSpeech"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quartzNet: "QuartzNet"
        case .appleSpeech: "Apple Speech"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .quartzNet: QuartzNetModelPackage.isSupported
        case .appleSpeech:
            if #available(iOS 26.0, *) { true } else { false }
        }
    }

    func supports(language: String?) -> Bool {
        guard self == .quartzNet, let language, !language.isEmpty else { return true }
        let normalized = language.lowercased().replacingOccurrences(of: "_", with: "-")
        return normalized == "und" || normalized == "english" || normalized == "eng" || normalized.split(separator: "-").first == "en"
    }
}

enum StoryAlignLaunchWarning {
    static let title = "Prepare read-aloud book"

    static func message(for method: StoryAlignMethod) -> String {
        switch method {
        case .quartzNet:
            return "StoryAlign aligns English narration with the ebook on this device. The first run downloads a 77 MB alignment model. Preparation can use significant battery power. Keep the app open on iOS 17–25; completed sections are saved if preparation pauses."
        case .appleSpeech:
            return "StoryAlign transcribes the audiobook with Apple's on-device speech service and matches it to the ebook. Preparation can use significant battery power and may pause if the system ends its background session."
        }
    }
}

@MainActor @Observable
final class StoryAlignService {
    static let shared = StoryAlignService()

    private let libraryCache: LibraryBookCache
    private let bookRepository: BookStoreRepository
    private unowned let profileSession: ProfileSession?
    private let defaults: UserDefaults
    private nonisolated let cacheRoot: URL
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var isRetired = false
    private var runID = UUID()
    private var thermalObserver: NSObjectProtocol?

    var method: StoryAlignMethod {
        didSet { defaults.set(method.rawValue, forKey: Self.methodKey) }
    }

    var automaticallyPausesForTemperature: Bool {
        didSet {
            defaults.set(automaticallyPausesForTemperature, forKey: Self.temperaturePauseKey)
            if automaticallyPausesForTemperature { pauseIfThermallyConstrained() }
        }
    }

    private static let methodKey = "storyalign.method"
    private static let temperaturePauseKey = "storyalign.automaticallyPausesForTemperature"

    init(
        libraryCache: LibraryBookCache = AppState.shared.libraryCache,
        bookRepository: BookStoreRepository = AppState.shared.bookStore,
        profileSession: ProfileSession? = nil
    ) {
        self.profileSession = profileSession
        defaults = profileSession?.defaults ?? .standard
        automaticallyPausesForTemperature = defaults.object(forKey: Self.temperaturePauseKey) as? Bool ?? true
        cacheRoot = (profileSession?.storage.applicationSupportDirectory ?? URL.applicationSupportDirectory).appendingPathComponent("Enve/StoryAlignCache", isDirectory: true)
        self.libraryCache = libraryCache
        self.bookRepository = bookRepository
        let storedMethod = defaults.string(forKey: Self.methodKey).flatMap(StoryAlignMethod.init(rawValue:))
        if let storedMethod, storedMethod.isAvailable {
            method = storedMethod
        } else {
            method = StoryAlignMethod.allCases.first(where: \.isAvailable) ?? .quartzNet
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pauseIfThermallyConstrained() }
        }
    }

    private func retainOperation(priority: TaskPriority? = nil, _ operation: @escaping @MainActor () async -> Void) {
        guard !isRetired else { return }
        let id = UUID()
        operations[id] = Task(priority: priority) {
            await operation()
            operations[id] = nil
        }
    }

    func retire() async {
        isRetired = true
        runID = UUID()
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        let pending = Array(operations.values) + [currentTask].compactMap { $0 }
        pending.forEach { $0.cancel() }
        for task in pending { await task.value }
        currentTask = nil
        currentSession?.cleanup()
        currentSession = nil
        endExecutionProtection(success: false)
    }

    var activeConversion: ConversionState?

    struct ConversionState: Equatable {
        let ebookStableId: String
        let audiobookStableId: String
        let method: StoryAlignMethod
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
        let method: StoryAlignMethod
        let reason: String

        init(ebookStableId: String, audiobookStableId: String, method: StoryAlignMethod, reason: String) {
            self.ebookStableId = ebookStableId
            self.audiobookStableId = audiobookStableId
            self.method = method
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case ebookStableId, audiobookStableId, method, reason
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            ebookStableId = try values.decode(String.self, forKey: .ebookStableId)
            audiobookStableId = try values.decode(String.self, forKey: .audiobookStableId)
            method = try values.decodeIfPresent(StoryAlignMethod.self, forKey: .method) ?? .appleSpeech
            reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? "Preparation was interrupted."
        }
    }

    private(set) var pausedConversion: PausedConversion? {
        didSet { savePausedConversion() }
    }

    private static let pausedConversionKey = "storyalign.pausedConversion"

    private func savePausedConversion() {
        if let paused = pausedConversion,
            let data = try? JSONEncoder().encode(paused)
        {
            defaults.set(data, forKey: Self.pausedConversionKey)
        } else {
            defaults.removeObject(forKey: Self.pausedConversionKey)
        }
    }

    func loadPausedConversion() {
        guard !isRetired else { return }
        guard let data = defaults.data(forKey: Self.pausedConversionKey),
            let paused = try? JSONDecoder().decode(PausedConversion.self, from: data)
        else { return }
        pausedConversion = paused
    }

    private static let bgTaskIdentifier = "com.enve.enve.storyalign"

    private var currentTask: Task<Void, Never>?
    private var currentSession: AlignmentSession?
    #if !targetEnvironment(macCatalyst)
    private var continuedProcessing: AnyObject?
    #endif
    private var didDisableIdleTimer = false

    #if !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    func handleContinuedProcessingTask(_ task: BGContinuedProcessingTask) {
        guard currentTask?.isCancelled == false,
            let activeConversion, !activeConversion.isComplete, activeConversion.error == nil, !isRetired
        else {
            task.setTaskCompleted(success: false)
            return
        }
        let processing = StoryAlignContinuedProcessing(task: task)
        continuedProcessing = processing
        let operationID = runID
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, operationID == self.runID else { return }
                self.pauseConversion(reason: "The system paused background preparation.")
            }
        }
    }
    #endif

    func needsDownload(ebook: Book, audiobook: Book) -> (ebook: Bool, audiobook: Bool) {
        return (ebook: resolveEpubURL(ebook) == nil, audiobook: resolveAudioURLs(audiobook) == nil)
    }

    func isConverted(ebook: Book, audiobook: Book) -> Bool {
        return cachedNarratedEpubURL(ebook: ebook, audiobook: audiobook) != nil
    }

    func cachedNarratedEpubURL(ebook: Book, audiobook: Book) -> URL? {
        return cachedNarratedEpubURL(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId)
    }

    func cancelConversion() {
        guard !isRetired else { return }
        runID = UUID()
        currentTask?.cancel()
        activeConversion = nil
        pausedConversion = nil
        endExecutionProtection(success: false)
    }

    func resumeConversion(ebook: Book, audiobook: Book) {
        guard !isRetired, let paused = pausedConversion else { return }
        method = paused.method
        downloadAndConvert(ebook: ebook, audiobook: audiobook)
    }

    func pauseConversion() {
        guard !isRetired else { return }
        pauseConversion(reason: "Paused by you.")
    }

    func dismissConversion() {
        guard !isRetired, currentTask == nil else { return }
        activeConversion = nil
    }

    func sceneDidEnterBackground() {
        if #available(iOS 26.0, *) { return }
        pauseConversion(reason: "Keep Enve open to continue preparation on this iOS version.")
    }

    private func pauseIfThermallyConstrained() {
        guard automaticallyPausesForTemperature else { return }
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            pauseConversion(reason: "Your device needs to cool down. Resume when it is cooler.")
        default: break
        }
    }

    private func pauseConversion(reason: String) {
        guard let active = activeConversion, !active.isComplete, active.error == nil else { return }
        runID = UUID()
        pausedConversion = PausedConversion(
            ebookStableId: active.ebookStableId,
            audiobookStableId: active.audiobookStableId,
            method: active.method,
            reason: reason
        )
        currentTask?.cancel()
        activeConversion = nil
        endExecutionProtection(success: false)
    }

    private func beginExecutionProtection() {
        if !UIApplication.shared.isIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = true
            didDisableIdleTimer = true
        }
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.bgTaskIdentifier, title: "StoryAlign", subtitle: "Starting…"
            )
            request.strategy = .queue
            do { try BGTaskScheduler.shared.submit(request) }
            catch { AppLogger.general.error("[StoryAlign] Background preparation unavailable") }
        }
        #endif
    }

    private func updateBackgroundProgress(_ progress: Double, stage: String) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *), let processing = continuedProcessing as? StoryAlignContinuedProcessing {
            processing.update(progress: progress, stage: stage)
        }
        #endif
    }

    private func endExecutionProtection(success: Bool) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *), let processing = continuedProcessing as? StoryAlignContinuedProcessing {
            processing.complete(success: success)
        }
        continuedProcessing = nil
        #endif
        if didDisableIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = false
            didDisableIdleTimer = false
        }
    }

    func downloadAndConvert(ebook: Book, audiobook: Book) {
        guard !isRetired, activeConversion == nil else { return }
        guard ebook.mediaType == .ebook, audiobook.mediaType == .audiobook else { return }

        let chosenMethod = method
        let operationID = UUID()
        runID = operationID
        let previousTask = currentTask
        previousTask?.cancel()
        activeConversion = ConversionState(
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId,
            method: chosenMethod,
            stage: "Preparing",
            progress: 0,
            detailText: nil,
            isDownloadPhase: false,
            startedAt: Date()
        )
        pausedConversion = PausedConversion(
            ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId,
            method: chosenMethod, reason: "Preparation was interrupted."
        )
        beginExecutionProtection()
        currentTask = Task { [weak self] in
            await previousTask?.value
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard operationID == runID, !isRetired else { throw CancellationError() }
                guard chosenMethod.isAvailable else { throw AlignError.appleSpeechUnavailable }
                guard chosenMethod.supports(language: audiobook.language ?? ebook.language) else {
                    throw AlignError.unsupportedLanguage
                }
                pauseIfThermallyConstrained()
                try Task.checkCancellation()
                if resolveEpubURL(ebook) == nil {
                    activeConversion?.stage = "Downloading Ebook"
                    activeConversion?.isDownloadPhase = true
                    await (profileSession?.downloads ?? UnifiedDownloadService.shared).download(book: ebook)
                    try await awaitEbookDownload(ebook)
                }
                try Task.checkCancellation()
                if resolveAudioURLs(audiobook) == nil {
                    activeConversion?.stage = "Downloading Audiobook"
                    activeConversion?.isDownloadPhase = true
                    await (profileSession?.downloads ?? UnifiedDownloadService.shared).download(book: audiobook)
                    try await awaitAudiobookDownload(audiobook)
                }
                try Task.checkCancellation()
                activeConversion?.isDownloadPhase = false
                activeConversion?.detailText = nil
                var modelDirectory: URL?
                if chosenMethod == .quartzNet {
                    activeConversion?.stage = "Preparing alignment model"
                    modelDirectory = try await StoryAlignModelStore.shared.prepare()
                } else {
                    try await ensureSpeechAuthorization()
                }
                try Task.checkCancellation()
                guard operationID == runID, !isRetired else { throw CancellationError() }
                guard let epubURL = try await prepareEpubURL(ebook), let audioURLs = resolveAudioURLs(audiobook) else {
                    throw AlignError.missingFiles
                }
                try await runAlignment(
                    epubURL: epubURL, audioURLs: audioURLs, ebook: ebook, audiobook: audiobook,
                    method: chosenMethod, modelDirectory: modelDirectory, operationID: operationID
                )
                guard operationID == runID else { return }
                pausedConversion = nil
                currentTask = nil
            } catch is CancellationError {
                guard operationID == runID else { return }
                currentSession?.cleanup()
                currentSession = nil
                currentTask = nil
                activeConversion = nil
                endExecutionProtection(success: false)
            } catch {
                guard operationID == runID, !isRetired else { return }
                activeConversion?.error = userFacingErrorMessage(for: error)
                activeConversion?.technicalError = rawErrorString(for: error)
                activeConversion?.stage = "Failed"
                activeConversion?.isDownloadPhase = false
                activeConversion?.detailText = nil
                currentSession?.cleanup()
                currentSession = nil
                currentTask = nil
                endExecutionProtection(success: false)
            }
        }
    }

    private func awaitEbookDownload(_ book: Book) async throws {
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            if resolveEpubURL(book) != nil { return }
            let failed = await MainActor.run {
                (profileSession?.downloads ?? UnifiedDownloadService.shared).tasks
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
                (profileSession?.localStorage ?? LocalStorageManager.shared).isAudiobookDownloaded(book.downloadKey)
            }
            if ready { return }
            let failed = await MainActor.run {
                (profileSession?.downloads ?? UnifiedDownloadService.shared).tasks
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
            (profileSession?.downloads ?? UnifiedDownloadService.shared).tasks
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

    private func runAlignment(
        epubURL: URL,
        audioURLs: [URL],
        ebook: Book,
        audiobook: Book,
        method: StoryAlignMethod,
        modelDirectory: URL?,
        operationID: UUID
    ) async throws {
        let outputDir = cacheDirectory(ebook: ebook, audiobook: audiobook)
        var workingDir = outputDir.appendingPathComponent("working-\(method.rawValue)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDir, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try workingDir.setResourceValues(resources)
        let preparedEpubURL = try prepareStoryAlignInputEpub(epubURL, in: workingDir)
        let request = try AlignmentRequest(
            epubURL: preparedEpubURL, audioBookURLs: audioURLs, sessionDir: workingDir.path
        )
        let config = AlignmentConfig(
            audioLoaderType: .avfoundation, concurrency: 0, reportType: .none, granularity: .sentence
        )
        let session: AlignmentSession
        if method == .quartzNet {
            session = AlignmentSession(request: request, config: config, logger: StoryAlignOSLogger())
        } else {
            session = AlignmentSession(
                request: request, config: config, logger: StoryAlignOSLogger(),
                speechAnalyzerConfig: SpeechAnalyzerConfig(bias: .fast),
                transcriptionStore: DiskTranscriptionStore(
                    directory: workingDir.appendingPathComponent("transcription-cache", isDirectory: true)
                )
            )
        }
        currentSession = session
        var didPromoteOutput = false
        defer {
            session.cleanup()
            if currentSession === session { currentSession = nil }
            if didPromoteOutput {
                for method in StoryAlignMethod.allCases {
                    try? FileManager.default.removeItem(
                        at: outputDir.appendingPathComponent("working-\(method.rawValue)", isDirectory: true)
                    )
                }
            }
        }
        session.addProgressListener(ProgressBridge { [weak self] snapshot in
            Task { @MainActor in
                guard let self, !self.isRetired, operationID == self.runID,
                    self.activeConversion?.isComplete == false, self.activeConversion?.error == nil
                else { return }
                let stage = method == .quartzNet && snapshot.stage == .transcribe
                    ? "Aligning Narration" : snapshot.stage.rawValue.capitalized
                self.activeConversion?.stage = stage
                self.activeConversion?.progress = snapshot.timeEstimateProgress()
                self.activeConversion?.detailText = nil
                self.updateBackgroundProgress(snapshot.timeEstimateProgress(), stage: stage)
            }
        })
        let result: AlignmentResult
        if method == .quartzNet {
            guard let modelDirectory else { throw AlignError.missingFiles }
            result = try await StoryAligner().alignStory(
                session: session, ctcConfiguration: CTCAlignmentConfiguration(modelDirectory: modelDirectory)
            )
        } else {
            result = try await StoryAligner().alignStory(session: session)
        }
        try Task.checkCancellation()
        guard operationID == runID, !isRetired else { throw CancellationError() }
        if let previousURL = cachedNarratedEpubURL(ebook: ebook, audiobook: audiobook) {
            let previous = try await outputQuality(at: previousURL)
            if let candidate = result.ctcQuality, let incumbent = previous.quality {
                guard Self.canReplace(candidate: candidate, incumbent: incumbent) else {
                    throw AlignError.inferiorAlignment
                }
            } else {
                let candidateCount: Int
                if let quality = result.ctcQuality {
                    candidateCount = quality.acceptedSentenceCount
                } else {
                    candidateCount = try await outputQuality(at: result.alignedEpubURL).sentenceCount
                }
                guard candidateCount >= previous.sentenceCount else { throw AlignError.inferiorAlignment }
            }
        }
        try Task.checkCancellation()
        guard operationID == runID, !isRetired else { throw CancellationError() }
        let acceptedURL = outputDir.appendingPathComponent("accepted.epub")
        if FileManager.default.fileExists(atPath: acceptedURL.path) {
            _ = try FileManager.default.replaceItemAt(acceptedURL, withItemAt: result.alignedEpubURL)
        } else {
            try FileManager.default.moveItem(at: result.alignedEpubURL, to: acceptedURL)
        }
        let elapsed = activeConversion.map { Date().timeIntervalSince($0.startedAt) }
        registerReadAloudBook(ebook: ebook, audiobook: audiobook, epubURL: acceptedURL)
        activeConversion?.stage = "Complete"
        activeConversion?.progress = 1
        activeConversion?.elapsedTime = elapsed
        activeConversion?.isComplete = true
        if let quality = result.ctcQuality {
            activeConversion?.detailText = "Matched \(quality.acceptedSentenceCount) of \(quality.eligibleSentenceCount) sentences (\(Int(quality.coverage * 100))%). Unmatched passages have no highlighting."
        }
        currentSession = nil
        endExecutionProtection(success: true)
        didPromoteOutput = true
    }

    static func canReplace(candidate: CTCAlignmentQuality, incumbent: CTCAlignmentQuality) -> Bool {
        candidate.acceptedSentenceCount >= incumbent.acceptedSentenceCount
            && candidate.coverage + 0.02 >= incumbent.coverage
            && candidate.audioCoverage + 0.02 >= incumbent.audioCoverage
    }

    private func outputQuality(at url: URL) async throws -> (quality: CTCAlignmentQuality?, sentenceCount: Int) {
        let archive = try await Archive(url: url, accessMode: .read)
        let entries = try await archive.entries().filter { $0.type == .file }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if let entry = entries.first(where: { $0.path == "META-INF/enve-ctc-quality.json" }) {
            guard entry.uncompressedSize <= 65_536 else { throw AlignError.invalidPreviousAlignment }
            let file = root.appendingPathComponent("quality.json")
            _ = try await archive.extract(entry, to: file)
            let quality = try JSONDecoder().decode(CTCAlignmentQuality.self, from: Data(contentsOf: file))
            guard quality.acceptedSentenceCount > 0,
                quality.eligibleSentenceCount >= quality.acceptedSentenceCount,
                quality.audioCoverage.isFinite, (0...1).contains(quality.audioCoverage)
            else { throw AlignError.invalidPreviousAlignment }
            return (quality, quality.acceptedSentenceCount)
        }
        var count = 0
        for (index, entry) in entries.filter({ $0.path.lowercased().hasSuffix(".smil") }).enumerated() {
            try Task.checkCancellation()
            guard entry.uncompressedSize <= 16_777_216 else { throw AlignError.invalidPreviousAlignment }
            let file = root.appendingPathComponent("\(index).smil")
            _ = try await archive.extract(entry, to: file)
            let parser = XMLParser(data: try Data(contentsOf: file))
            let counter = StoryAlignOverlayCounter()
            parser.delegate = counter
            guard parser.parse() else { throw AlignError.invalidPreviousAlignment }
            count += counter.count
        }
        guard count > 0 else { throw AlignError.invalidPreviousAlignment }
        return (nil, count)
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
        guard !isRetired else { return }
        for dir in cacheDirectories(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId) {
            try? FileManager.default.removeItem(at: dir)
        }
        unregisterReadAloudBook(forSourceStableId: ebook.stableId)
    }

    func deleteConversions(involving book: Book) {
        guard !isRetired else { return }
        let stableId = book.stableId
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: cacheRoot,
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
        guard !isRetired else { return }
        try? FileManager.default.removeItem(at: cacheRoot)
        retainOperation(priority: .utility) { [self] in
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
            (profileSession?.catalog ?? LibraryCatalogCoordinator.shared).flushLocalBooksToCache()
        }
    }

    static let readAloudLibraryId = "__storyalign_readaloud__"

    @MainActor
    private func registerReadAloudBook(ebook: Book, audiobook: Book, epubURL: URL) {
        guard !isRetired else { return }
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
        retainOperation(priority: .utility) { [self] in
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
        retainOperation(priority: .utility) { [self] in
            let readAloud = await self.bookRepository.firstBooksWithReadAloudSource(limit: 5000)
            let removedIds = Set(readAloud.filter { $0.readAloudSourceStableId == stableId }.map(\.uniqueId))
            await MainActor.run {
                for id in removedIds { self.libraryCache.hot.remove(uniqueId: id) }
            }
            if !removedIds.isEmpty {
                await self.bookRepository.deleteBooks(uniqueIds: removedIds)
            }
            (profileSession?.catalog ?? LibraryCatalogCoordinator.shared).flushLocalBooksToCache()
        }
    }

    func completedConversions() async -> [CompletedConversion] {
        let pairs = completedCachePairs()
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
                let url = cachedNarratedEpubURL(ebookStableId: pair.ebookStableId, audiobookStableId: pair.audiobookStableId)
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
        retainOperation { [self] in
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
                retainOperation(priority: .utility) { [self] in
                    await self.bookRepository.deleteBooks(uniqueIds: removeIds)
                    (profileSession?.catalog ?? LibraryCatalogCoordinator.shared).flushLocalBooksToCache()
                }
            }
        }
    }

    func syncReadAloudLibraryOnLaunch() async {
        await MainActor.run {
            self.syncReadAloudLibrary()
        }
    }

    private nonisolated struct CachePair: Hashable {
        let ebookStableId: String
        let audiobookStableId: String

        var id: String { "\(ebookStableId)|\(audiobookStableId)" }

        func contains(_ stableId: String) -> Bool {
            ebookStableId == stableId || audiobookStableId == stableId
        }
    }

    private nonisolated func cachedNarratedEpubURL(ebookStableId: String, audiobookStableId: String) -> URL? {
        for dir in cacheDirectories(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId) {
            let accepted = dir.appendingPathComponent("accepted.epub")
            if FileManager.default.fileExists(atPath: accepted.path) { return accepted }
            let epubFiles = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?.filter {
                $0.pathExtension.lowercased() == "epub"
            }
            if let epub = epubFiles?.first {
                return epub
            }
        }
        return nil
    }

    private nonisolated func cacheDirectory(ebookStableId: String, audiobookStableId: String) -> URL {
        cacheRoot.appendingPathComponent(Self.cacheKey(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId), isDirectory: true)
    }

    private nonisolated func cacheDirectories(ebookStableId: String, audiobookStableId: String) -> [URL] {
        let current = cacheDirectory(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)
        let legacy = cacheRoot.appendingPathComponent(
            Self.legacyCacheKey(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId),
            isDirectory: true
        )
        return current == legacy ? [current] : [current, legacy]
    }

    private nonisolated func completedCachePairs() -> [CachePair] {
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
                let pair = Self.cachePair(from: entry)
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
        cacheDirectory(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId)
    }

    private func resolveEpubURL(_ book: Book) -> URL? {
        (profileSession?.ebooks ?? LocalEbookImporter.shared).resolveExistingLocalEbookURL(
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
        return try await (profileSession?.ebooks ?? LocalEbookImporter.shared).convertMobiToEpub(url)
    }

    private func resolveAudioURLs(_ book: Book) -> [URL]? {
        if let urls = (profileSession?.localStorage ?? LocalStorageManager.shared).localAudiobookFilesIfExists(for: book), !urls.isEmpty {
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
        guard !isRetired else { return }
        guard FileManager.default.fileExists(atPath: cacheRoot.path) else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else {
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
    case appleSpeechUnavailable
    case unsupportedLanguage
    case inferiorAlignment
    case invalidPreviousAlignment

    var errorDescription: String? {
        switch self {
        case .missingFiles: return "Could not locate ebook or audiobook files."
        case .downloadFailed: return "Download failed. Check your connection and try again."
        case .downloadTimeout: return "Download timed out. Please try again."
        case .speechAuthorizationDenied: return "Speech Recognition permission is required to create a read-aloud EPUB."
        case .simulatorUnsupported:
            return
                "StoryAlign alignment is not available in the iOS Simulator. Use a physical device to run the transcription and alignment step."
        case .inferiorAlignment: return "The new alignment matched less of the book. Your previous read-aloud book was kept."
        case .invalidPreviousAlignment: return "The previous alignment could not be verified. It was kept; remove it explicitly before replacing it."
        case .appleSpeechUnavailable: return "Apple Speech alignment requires iOS 26 or later. Choose QuartzNet for English books."
        case .unsupportedLanguage: return "QuartzNet currently supports English narration. Choose Apple Speech for other supported languages on iOS 26 or later."
        case .backgroundExpired:
            return "The system ended StoryAlign\u{2019}s background session. Try again while plugged in and with fewer apps running."
        }
    }
}

#if !targetEnvironment(macCatalyst)
@available(iOS 26.0, *)
@MainActor
private final class StoryAlignContinuedProcessing {
    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = 100
    }

    func update(progress: Double, stage: String) {
        task.progress.completedUnitCount = Int64(min(max(progress, 0), 1) * 100)
        task.updateTitle("StoryAlign", subtitle: stage)
    }

    func complete(success: Bool) {
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }
}
#endif

nonisolated private final class StoryAlignOverlayCounter: NSObject, XMLParserDelegate {
    private(set) var count = 0

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        if elementName.split(separator: ":").last == "audio" { count += 1 }
    }
}
