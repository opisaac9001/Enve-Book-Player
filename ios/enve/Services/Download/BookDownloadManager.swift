import Combine
import Foundation
import Logging
import Zip

#if canImport(UIKit)
import UIKit
#endif

final class BookDownloadManager: NSObject, ObservableObject {
    static let shared = BookDownloadManager()

    nonisolated static let downloadDidCompleteNotification = Notification.Name("BookDownloadManager.downloadDidComplete")

    @Published private(set) var progressByBookId: [String: Double] = [:]
    @Published private(set) var totalBytesByBookId: [String: Int64] = [:]
    @Published private(set) var activeBookIds: Set<String> = [] {
        didSet {

            activeBookIdsMirrorLock.lock()
            activeBookIdsMirror = activeBookIds
            activeBookIdsMirrorLock.unlock()
        }
    }
    @Published private(set) var completedBookIds: Set<String> = []
    @Published private(set) var lastErrorByBookId: [String: String] = [:]

    private let activeBookIdsMirrorLock = NSLock()
    nonisolated(unsafe) private var activeBookIdsMirror: Set<String> = []

    nonisolated func isBookIdActiveDownload(_ bookId: String) -> Bool {
        activeBookIdsMirrorLock.lock()
        defer { activeBookIdsMirrorLock.unlock() }
        return activeBookIdsMirror.contains(bookId)
    }
    private var lastProgressEmissionByBookId: [String: (time: Date, progress: Double)] = [:]
    private let minProgressUpdateInterval: TimeInterval = 0.25
    private let minProgressDelta: Double = 0.005

    private let stateQueue = DispatchQueue(label: "BookDownloadManager.state", attributes: .concurrent)
    nonisolated(unsafe) private var taskIdToBookId: [Int: String] = [:]
    nonisolated(unsafe) private var bookIdToTask: [String: URLSessionDownloadTask] = [:]

    nonisolated private final class MultiTrackDownloadState: @unchecked Sendable {
        let bookId: String
        let bookDir: URL
        let total: Int
        var completedCount: Int = 0
        var failed: Bool = false
        var firstErrorMessage: String?
        init(bookId: String, bookDir: URL, total: Int) {
            self.bookId = bookId
            self.bookDir = bookDir
            self.total = total
        }
    }
    nonisolated(unsafe) private var multiTrackStateByBookId: [String: MultiTrackDownloadState] = [:]
    nonisolated(unsafe) private var multiTrackTaskIdToContext: [Int: (bookId: String, chapterIndex: Int)] = [:]
    nonisolated(unsafe) private var multiTrackTasksByBookId: [String: [URLSessionDownloadTask]] = [:]

    private let storage = LocalStorageManager.shared

    @MainActor
    private func shouldEmitProgressUpdate(bookId: String, progress: Double) -> Bool {
        let clamped = max(0, min(progress, 1))
        let now = Date()
        if let last = lastProgressEmissionByBookId[bookId] {
            let delta = abs(clamped - last.progress)
            let elapsed = now.timeIntervalSince(last.time)
            if delta < minProgressDelta && elapsed < minProgressUpdateInterval {
                return false
            }
        }
        lastProgressEmissionByBookId[bookId] = (time: now, progress: clamped)
        return true
    }

    @MainActor
    func markAsCompleted(bookId: String) {
        completedBookIds.insert(bookId)
        activeBookIds.remove(bookId)
        lastErrorByBookId.removeValue(forKey: bookId)
    }

    @MainActor
    func clearCompletedState(bookId: String) {
        completedBookIds.remove(bookId)
    }

    func pauseDownload(bookId: String) {
        var taskToPause: URLSessionDownloadTask?
        stateQueue.sync {
            taskToPause = bookIdToTask[bookId]
        }
        taskToPause?.suspend()
        AppLogger.network.info("Paused download for: \(bookId)")
    }

    func resumeDownload(bookId: String) {
        var taskToResume: URLSessionDownloadTask?
        stateQueue.sync {
            taskToResume = bookIdToTask[bookId]
        }
        taskToResume?.resume()
        AppLogger.network.info("Resumed download for: \(bookId)")
    }

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    @MainActor
    func progress(for bookId: String) -> Double { progressByBookId[bookId] ?? 0 }

    @MainActor
    func isDownloading(bookId: String) -> Bool { activeBookIds.contains(bookId) }

    @MainActor
    func isDownloading(_ book: Book) -> Bool { activeBookIds.contains(book.downloadKey) }

    @MainActor
    func isDownloaded(bookId: String) -> Bool {
        storage.isAudiobookDownloaded(bookId)
    }

    func startDownload(bookId: String, request: URLRequest) async {
        if storage.isAudiobookDownloaded(bookId) {
            await MainActor.run {
                completedBookIds.insert(bookId)
                lastErrorByBookId.removeValue(forKey: bookId)
            }
            return
        }

        let alreadyActive = await MainActor.run { activeBookIds.contains(bookId) }
        if alreadyActive { return }

        await MainActor.run {
            activeBookIds.insert(bookId)
            progressByBookId[bookId] = 0
            lastErrorByBookId.removeValue(forKey: bookId)
            completedBookIds.remove(bookId)
        }

        var normalized = request
        if normalized.timeoutInterval <= 0 {
            normalized.timeoutInterval = 300
        }

        let task = session.downloadTask(with: normalized)

        stateQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.taskIdToBookId[task.taskIdentifier] = bookId
            self.bookIdToTask[bookId] = task
        }

        task.resume()
    }

    func startFileCopyDownload(bookId: String, sourceURL: URL, securityScopedRootURL: URL? = nil) async {
        if storage.isAudiobookDownloaded(bookId) {
            await MainActor.run {
                completedBookIds.insert(bookId)
                lastErrorByBookId.removeValue(forKey: bookId)
            }
            return
        }

        let alreadyActive = await MainActor.run { activeBookIds.contains(bookId) }
        if alreadyActive { return }

        await MainActor.run {
            activeBookIds.insert(bookId)
            progressByBookId[bookId] = 0
            lastErrorByBookId.removeValue(forKey: bookId)
            completedBookIds.remove(bookId)
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                var isAccessing = false
                if let root = securityScopedRootURL {
                    isAccessing = root.startAccessingSecurityScopedResource()
                    AppLogger.network.info("Started accessing security-scoped resource for copy: \(isAccessing)")
                }
                defer {
                    if isAccessing, let root = securityScopedRootURL {
                        root.stopAccessingSecurityScopedResource()
                        AppLogger.network.info("Stopped accessing security-scoped resource for copy")
                    }
                }

                let fm = FileManager.default

                let fileSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0

                let bookDir = self.storage.bookAudioDirectory(for: bookId)
                try fm.createDirectory(at: bookDir, withIntermediateDirectories: true, attributes: nil)

                let ext = sourceURL.pathExtension.isEmpty ? "m4b" : sourceURL.pathExtension
                let destination = bookDir.appendingPathComponent("chapter_0.\(ext)")

                if fm.fileExists(atPath: destination.path) {
                    try? fm.removeItem(at: destination)
                }

                fm.createFile(atPath: destination.path, contents: nil, attributes: nil)

                let readHandle = try FileHandle(forReadingFrom: sourceURL)
                defer { try? readHandle.close() }

                let writeHandle = try FileHandle(forWritingTo: destination)
                defer { try? writeHandle.close() }

                var totalWritten: Int64 = 0
                let chunkSize = 1_048_576

                while true {
                    let data = try readHandle.read(upToCount: chunkSize) ?? Data()
                    if data.isEmpty { break }
                    try writeHandle.write(contentsOf: data)
                    totalWritten += Int64(data.count)

                    if fileSize > 0 {
                        let progress = Double(totalWritten) / Double(fileSize)
                        await MainActor.run {
                            self.progressByBookId[bookId] = max(0, min(progress, 1))
                        }
                    }
                }

                if !fm.fileExists(atPath: destination.path) {
                    throw NSError(
                        domain: NSCocoaErrorDomain,
                        code: CocoaError.fileNoSuchFile.rawValue,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to persist copied file to \(destination.path())"]
                    )
                }

                await MainActor.run {
                    self.activeBookIds.remove(bookId)
                    self.progressByBookId[bookId] = 1
                    self.completedBookIds.insert(bookId)
                    self.lastErrorByBookId.removeValue(forKey: bookId)
                    NotificationCenter.default.post(
                        name: Self.downloadDidCompleteNotification,
                        object: nil,
                        userInfo: ["bookId": bookId]
                    )
                }
            } catch {
                await MainActor.run {
                    self.activeBookIds.remove(bookId)
                    self.progressByBookId.removeValue(forKey: bookId)
                    self.lastErrorByBookId[bookId] = error.localizedDescription
                }
            }
        }
    }

    func cancelDownload(bookId: String) {
        var taskToCancel: URLSessionDownloadTask?
        var collectedMultiTrackTasks: [URLSessionDownloadTask] = []
        stateQueue.sync {
            taskToCancel = bookIdToTask[bookId]
            collectedMultiTrackTasks = multiTrackTasksByBookId[bookId] ?? []
        }

        let multiTrackTasksToCancel = collectedMultiTrackTasks
        if !multiTrackTasksToCancel.isEmpty {
            for t in multiTrackTasksToCancel { t.cancel() }
        } else {
            taskToCancel?.cancel()
        }

        stateQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.bookIdToTask.removeValue(forKey: bookId)
            self.multiTrackStateByBookId.removeValue(forKey: bookId)
            self.multiTrackTasksByBookId.removeValue(forKey: bookId)
            for t in multiTrackTasksToCancel {
                self.taskIdToBookId.removeValue(forKey: t.taskIdentifier)
                self.multiTrackTaskIdToContext.removeValue(forKey: t.taskIdentifier)
            }
        }

        Task { @MainActor in
            activeBookIds.remove(bookId)
            progressByBookId.removeValue(forKey: bookId)
        }
    }

    func startSMBDownload(bookId: String, smbBook: SMBBook, source: SMBLibrarySource, password: String) async {
        AppLogger.network.info("[SMB Download] Starting for bookId: \(bookId)")

        let alreadyActive = await MainActor.run { activeBookIds.contains(bookId) }
        if alreadyActive {
            AppLogger.network.warning("[SMB Download] Already active, skipping: \(bookId)")
            return
        }

        await MainActor.run {
            activeBookIds.insert(bookId)
            progressByBookId[bookId] = 0
            lastErrorByBookId.removeValue(forKey: bookId)
            completedBookIds.remove(bookId)
        }

        do {
            let smbService = SMBService()
            let config = source.toServerConfiguration()
            try await smbService.connect(config: config, password: password)

            let fm = FileManager.default
            let bookDir = storage.bookAudioDirectory(for: bookId)

            if fm.fileExists(atPath: bookDir.path) {
                try? fm.removeItem(at: bookDir)
                AppLogger.network.info("[SMB Download] Removed existing directory")
            }

            try fm.createDirectory(at: bookDir, withIntermediateDirectories: true, attributes: nil)
            AppLogger.network.info(
                "[SMB Download] Directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookDir.standardizedFileURL.path))"
            )

            let totalFiles = smbBook.audioFiles.count
            guard totalFiles > 0 else {
                throw NSError(domain: "BookDownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No audio files to download"])
            }

            var completedFiles = 0

            for (index, audioFile) in smbBook.audioFiles.enumerated() {
                let ext = (audioFile.name as NSString).pathExtension.isEmpty ? "m4b" : (audioFile.name as NSString).pathExtension
                let destFileName = totalFiles == 1 ? "chapter_0.\(ext)" : "chapter_\(index).\(ext)"
                let destURL = bookDir.appendingPathComponent(destFileName)

                AppLogger.network.debug(
                    "[SMB Download] Downloading \(index + 1)/\(totalFiles) type=.\(ext.lowercased())"
                )

                let currentCompleted = completedFiles
                let totalFilesCapture = totalFiles

                try await smbService.downloadFile(from: audioFile.path, to: destURL) { [weak self] downloaded, total in
                    guard let self else { return }
                    let fileProgress = total > 0 ? Double(downloaded) / Double(total) : 0
                    let overallProgress = (Double(currentCompleted) + fileProgress) / Double(totalFilesCapture)

                    Task { @MainActor in
                        let clamped = max(0, min(overallProgress, 1))
                        if self.shouldEmitProgressUpdate(bookId: bookId, progress: clamped) {
                            self.progressByBookId[bookId] = clamped
                        }
                    }
                }

                guard let attrs = try? fm.attributesOfItem(atPath: destURL.path),
                    let size = attrs[.size] as? Int64, size > 1024
                else {
                    throw NSError(
                        domain: "BookDownloadManager",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Downloaded file is empty or too small: \(destURL.lastPathComponent)"]
                    )
                }

                AppLogger.network.debug(
                    "[SMB Download] File complete \(DiagnosticLogSanitizer.fileDescriptor(for: destURL)) sizeKB=\(size / 1024)"
                )
                completedFiles += 1
            }

            await smbService.disconnect()

            AppLogger.network.info("[SMB Download] Completed downloading \(totalFiles) files for book: \(bookId)")

            await MainActor.run {
                self.activeBookIds.remove(bookId)
                self.progressByBookId[bookId] = 1
                self.completedBookIds.insert(bookId)
                self.lastErrorByBookId.removeValue(forKey: bookId)
                self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
                NotificationCenter.default.post(
                    name: Self.downloadDidCompleteNotification,
                    object: nil,
                    userInfo: ["bookId": bookId]
                )
            }

        } catch {
            await MainActor.run {
                self.activeBookIds.remove(bookId)
                self.progressByBookId.removeValue(forKey: bookId)
                self.lastErrorByBookId[bookId] = error.localizedDescription
                self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
            }
            AppLogger.network.error("[SMB Download] Failed: \(error.localizedDescription)")
        }
    }

    func startMultiTrackHTTPDownload(bookId: String, requests: [(request: URLRequest, mimeType: String?)]) async {
        let alreadyActive = await MainActor.run { activeBookIds.contains(bookId) }
        if alreadyActive { return }

        await MainActor.run {
            activeBookIds.insert(bookId)
            progressByBookId[bookId] = 0
            lastErrorByBookId.removeValue(forKey: bookId)
            completedBookIds.remove(bookId)
        }

        let fm = FileManager.default
        let bookDir = storage.bookAudioDirectory(for: bookId)

        do {
            if fm.fileExists(atPath: bookDir.path) {
                try fm.removeItem(at: bookDir)
            }
            try fm.createDirectory(at: bookDir, withIntermediateDirectories: true)
        } catch {
            await failMultiTrackDownload(bookId: bookId, errorMessage: error.localizedDescription)
            return
        }

        guard !requests.isEmpty else {
            await failMultiTrackDownload(bookId: bookId, errorMessage: "No tracks to download")
            return
        }

        let state = MultiTrackDownloadState(bookId: bookId, bookDir: bookDir, total: requests.count)

        let scheduledTasks: [URLSessionDownloadTask] = requests.map { entry in
            var req = entry.request
            if req.timeoutInterval <= 0 { req.timeoutInterval = 300 }
            return session.downloadTask(with: req)
        }
        let contextEntries: [(taskId: Int, chapterIndex: Int)] = scheduledTasks.enumerated().map { index, task in
            (task.taskIdentifier, index)
        }

        stateQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.multiTrackStateByBookId[bookId] = state
            self.multiTrackTasksByBookId[bookId] = scheduledTasks
            for entry in contextEntries {
                self.multiTrackTaskIdToContext[entry.taskId] = (bookId, entry.chapterIndex)
                self.taskIdToBookId[entry.taskId] = bookId
            }

            if let last = scheduledTasks.last {
                self.bookIdToTask[bookId] = last
            }
        }

        AppLogger.network.info("[MultiTrack] Scheduled \(scheduledTasks.count) tracks for \(bookId) on background session")

        for task in scheduledTasks {
            task.resume()
        }
    }

    private func failMultiTrackDownload(bookId: String, errorMessage: String) async {
        await MainActor.run {
            activeBookIds.remove(bookId)
            progressByBookId.removeValue(forKey: bookId)
            lastErrorByBookId[bookId] = errorMessage
            lastProgressEmissionByBookId.removeValue(forKey: bookId)
        }
        AppLogger.network.error("[MultiTrack] Failed for \(bookId): \(errorMessage)")
    }

    func cancelDownload(book: Book) {
        cancelDownload(bookId: book.id)
    }

    @MainActor
    func clearState(bookId: String) {
        activeBookIds.remove(bookId)
        progressByBookId.removeValue(forKey: bookId)
        completedBookIds.remove(bookId)
        lastErrorByBookId.removeValue(forKey: bookId)
    }

    nonisolated private func persistDownloadedTempFile(tempURL: URL, destinationURL: URL) throws {
        let fm = FileManager.default
        let destPath = destinationURL.path

        if fm.fileExists(atPath: destPath) {
            var lastError: Error?
            for attempt in 0..<3 {
                do {
                    try fm.removeItem(at: destinationURL)
                    lastError = nil
                    break
                } catch {
                    lastError = error
                    if attempt < 2 {
                        usleep(useconds_t(50_000 * (attempt + 1)))
                    }
                }
            }
            if let lastError { throw lastError }
        }

        do {
            try fm.moveItem(at: tempURL, to: destinationURL)
            return
        } catch let nsError as NSError {

            let isFileExists =
                (nsError.domain == NSCocoaErrorDomain && nsError.code == 516)
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == 17)
            if isFileExists {
                if fm.fileExists(atPath: destPath) {
                    try? fm.removeItem(at: destinationURL)
                }
                do {
                    try fm.moveItem(at: tempURL, to: destinationURL)
                    return
                } catch {
                    AppLogger.general.debug("Move retry failed; will check if destination exists: \(error.localizedDescription)")
                }
            }

            if fm.fileExists(atPath: destPath) {
                return
            }
        }

        guard fm.fileExists(atPath: tempURL.path) else {

            if fm.fileExists(atPath: destPath) { return }
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileNoSuchFile.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Source file disappeared during persist to \(destinationURL.path())"]
            )
        }
        try fm.copyItem(at: tempURL, to: destinationURL)
        try? fm.removeItem(at: tempURL)

        if !fm.fileExists(atPath: destPath) {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: CocoaError.fileNoSuchFile.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Failed to persist download to \(destinationURL.path())"]
            )
        }
    }

    private nonisolated func isZipFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4), header.count >= 4 else { return false }
        return header[0] == 0x50 && header[1] == 0x4B && header[2] == 0x03 && header[3] == 0x04
    }

    private nonisolated func extractAudioFilesFromZip(at zipURL: URL, into destinationDir: URL) throws -> [URL] {
        let fm = FileManager.default
        let unzipDir = destinationDir.appendingPathComponent("temp_unzip", isDirectory: true)
        if fm.fileExists(atPath: unzipDir.path) {
            try? fm.removeItem(at: unzipDir)
        }
        try fm.createDirectory(at: unzipDir, withIntermediateDirectories: true)

        let renamedZip = destinationDir.appendingPathComponent("download.zip")
        try? fm.removeItem(at: renamedZip)
        try fm.moveItem(at: zipURL, to: renamedZip)

        defer {
            try? fm.removeItem(at: unzipDir)
            try? fm.removeItem(at: renamedZip)
        }

        try Zip.unzipFile(renamedZip, destination: unzipDir, overwrite: true, password: nil)

        var audioItems: [(url: URL, name: String)] = []
        let enumerator = fm.enumerator(at: unzipDir, includingPropertiesForKeys: [.isDirectoryKey])
        while let itemURL = enumerator?.nextObject() as? URL {
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }

            let ext = itemURL.pathExtension.lowercased()
            guard AudiobookFormat.from(fileExtension: ext) != nil else { continue }
            audioItems.append((url: itemURL, name: itemURL.lastPathComponent.lowercased()))
        }

        audioItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        var extracted: [URL] = []
        for (index, item) in audioItems.enumerated() {
            let ext = item.url.pathExtension.lowercased()
            let outputURL = destinationDir.appendingPathComponent("chapter_\(index).\(ext)", isDirectory: false)
            if fm.fileExists(atPath: outputURL.path) {
                try? fm.removeItem(at: outputURL)
            }
            try fm.moveItem(at: item.url, to: outputURL)
            extracted.append(outputURL)
        }

        if extracted.isEmpty {
            throw NSError(
                domain: "BookDownloadManager",
                code: -10,
                userInfo: [
                    NSLocalizedDescriptionKey: "ZIP archive contains no supported audio files (found \(audioItems.count) candidates)"
                ]
            )
        }

        AppLogger.network.info("Extracted \(extracted.count) audio file(s) from ZIP")
        return extracted
    }
}

extension BookDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            #if os(iOS)
            guard let delegate = UIApplication.shared.delegate as? CarPlayAppDelegate else { return }
            delegate.consumeBackgroundCompletionHandler(forIdentifier: identifier)?()
            #endif
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host

        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = NetworkHostUtils.findMTLSIdentity(forHost: host) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        {
            if NetworkHostUtils.isLocalNetworkHost(host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var redirected = request
        if let originalAuth = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
            redirected.value(forHTTPHeaderField: "Authorization") == nil
        {
            redirected.setValue(originalAuth, forHTTPHeaderField: "Authorization")
            AppLogger.network.info("Re-applied auth header through redirect to \(redirected.url?.host ?? "?")")
        }
        completionHandler(redirected)
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        var bookId: String?
        stateQueue.sync {
            bookId = taskIdToBookId[downloadTask.taskIdentifier]
        }
        guard let bookId else { return }

        let progress: Double
        if totalBytesExpectedToWrite > 0 {
            progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else {
            progress = 0
        }
        Task { @MainActor in
            let clamped = max(0, min(progress, 1))
            if self.shouldEmitProgressUpdate(bookId: bookId, progress: clamped) {
                self.progressByBookId[bookId] = clamped
            }
            if totalBytesExpectedToWrite > 0 {
                self.totalBytesByBookId[bookId] = totalBytesExpectedToWrite
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let taskId = downloadTask.taskIdentifier

        var bookId: String?
        var multiTrackContext: (bookId: String, chapterIndex: Int)?
        stateQueue.sync {
            bookId = taskIdToBookId[taskId]
            multiTrackContext = multiTrackTaskIdToContext[taskId]
        }
        guard let bookId else { return }

        if let ctx = multiTrackContext {
            handleMultiTrackChapterFinished(taskId: taskId, downloadTask: downloadTask, location: location, context: ctx)
            return
        }

        do {
            if let http = downloadTask.response as? HTTPURLResponse,
                !(200...299).contains(http.statusCode)
            {
                try? FileManager.default.removeItem(at: location)
                throw NSError(
                    domain: NSURLErrorDomain,
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Download failed with HTTP status: \(http.statusCode)"]
                )
            }

            if let http = downloadTask.response as? HTTPURLResponse,
                let ct = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            {
                if ct.contains("text/html") || ct.contains("text/plain") || ct.contains("application/json") {
                    let snippet: String
                    if let data = try? Data(contentsOf: location, options: .mappedIfSafe) {
                        snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                    } else {
                        snippet = "<unreadable>"
                    }
                    try? FileManager.default.removeItem(at: location)
                    throw NSError(
                        domain: "BookDownloadManager",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Server returned \(ct) instead of audio. The file may require re-authentication. (\(snippet.prefix(80)))"
                        ]
                    )
                }
            }

            if UnifiedDownloadService.detectExtensionFromMagicBytes(at: location) == nil {
                if let data = try? Data(contentsOf: location, options: .mappedIfSafe),
                    data.count < 50_000,
                    let text = String(data: data.prefix(512), encoding: .utf8),
                    text.lowercased().contains("<!doctype") || text.lowercased().contains("<html")
                {
                    try? FileManager.default.removeItem(at: location)
                    throw NSError(
                        domain: "BookDownloadManager",
                        code: -3,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Downloaded file is an HTML page, not audio. This usually means the server requires re-authentication."
                        ]
                    )
                }
            }

            let fm = FileManager.default
            if !fm.fileExists(atPath: location.path) {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileNoSuchFile.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Temp download file missing at \(location.path)"]
                )
            }

            let bookDir = storage.bookAudioDirectory(for: bookId)
            try fm.createDirectory(at: bookDir, withIntermediateDirectories: true, attributes: nil)

            let ext = UnifiedDownloadService.detectAudioExtension(
                urlPathExtension: downloadTask.originalRequest?.url?.pathExtension.lowercased(),
                response: downloadTask.response,
                fileURL: location
            )

            let extractedFiles: [URL]
            if ext == "zip" || isZipFile(at: location) {
                extractedFiles = try extractAudioFilesFromZip(at: location, into: bookDir)
            } else {
                let destination = bookDir.appendingPathComponent("chapter_0.\(ext)", isDirectory: false)
                try persistDownloadedTempFile(tempURL: location, destinationURL: destination)
                extractedFiles = [destination]
            }

            let didPersistOnDisk = extractedFiles.contains(where: { url in
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
            })
            if !didPersistOnDisk {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: CocoaError.fileNoSuchFile.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded file missing after persist/extract for \(bookId)"]
                )
            }

            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                self.taskIdToBookId.removeValue(forKey: taskId)
                self.bookIdToTask.removeValue(forKey: bookId)
            }

            Task { @MainActor in
                self.activeBookIds.remove(bookId)
                self.progressByBookId[bookId] = 1.0
                self.completedBookIds.insert(bookId)
                self.lastErrorByBookId.removeValue(forKey: bookId)
                self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
                NotificationCenter.default.post(
                    name: BookDownloadManager.downloadDidCompleteNotification,
                    object: nil,
                    userInfo: ["bookId": bookId]
                )
            }
        } catch {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                self.taskIdToBookId.removeValue(forKey: taskId)
                self.bookIdToTask.removeValue(forKey: bookId)
            }

            Task { @MainActor in
                self.activeBookIds.remove(bookId)
                self.progressByBookId.removeValue(forKey: bookId)
                self.lastErrorByBookId[bookId] = error.localizedDescription
                self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }

        let taskId = task.taskIdentifier
        var bookId: String?
        var multiTrackContext: (bookId: String, chapterIndex: Int)?
        stateQueue.sync {
            bookId = taskIdToBookId[taskId]
            multiTrackContext = multiTrackTaskIdToContext[taskId]
        }
        guard let bookId else { return }

        if multiTrackContext != nil {
            handleMultiTrackChapterFailure(bookId: bookId, taskId: taskId, error: error)
            return
        }

        stateQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.taskIdToBookId.removeValue(forKey: taskId)
            self.bookIdToTask.removeValue(forKey: bookId)
        }

        Task { @MainActor in
            self.activeBookIds.remove(bookId)
            self.progressByBookId.removeValue(forKey: bookId)
            self.lastErrorByBookId[bookId] = error.localizedDescription
            self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
        }

        let storageCopy = storage
        Task { @MainActor in
            _ = storageCopy.deleteAudiobook(bookId)
        }
    }

    nonisolated private func handleMultiTrackChapterFinished(
        taskId: Int,
        downloadTask: URLSessionDownloadTask,
        location: URL,
        context: (bookId: String, chapterIndex: Int)
    ) {
        let bookId = context.bookId
        let chapterIndex = context.chapterIndex

        var state: MultiTrackDownloadState?
        stateQueue.sync { state = multiTrackStateByBookId[bookId] }
        guard let state else {
            try? FileManager.default.removeItem(at: location)
            return
        }

        do {

            if state.failed {
                try? FileManager.default.removeItem(at: location)
                return
            }

            if let http = downloadTask.response as? HTTPURLResponse,
                !(200...299).contains(http.statusCode)
            {
                try? FileManager.default.removeItem(at: location)
                throw NSError(
                    domain: NSURLErrorDomain,
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Track \(chapterIndex) HTTP \(http.statusCode)"]
                )
            }

            let ext = UnifiedDownloadService.detectAudioExtension(
                urlPathExtension: downloadTask.originalRequest?.url?.pathExtension.lowercased(),
                response: downloadTask.response,
                fileURL: location
            )
            let destURL = state.bookDir.appendingPathComponent("chapter_\(chapterIndex).\(ext)")
            try persistDownloadedTempFile(tempURL: location, destinationURL: destURL)

            guard let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
                let size = attrs[.size] as? Int64, size > 1024
            else {
                try? FileManager.default.removeItem(at: destURL)
                throw NSError(
                    domain: "BookDownloadManager",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Track \(chapterIndex) too small after persist"]
                )
            }

            let progressTuple: (newCompleted: Int, total: Int, shouldFinalize: Bool) = stateQueue.sync(flags: .barrier) {
                state.completedCount += 1
                self.multiTrackTaskIdToContext.removeValue(forKey: taskId)
                self.taskIdToBookId.removeValue(forKey: taskId)
                return (state.completedCount, state.total, state.completedCount >= state.total)
            }
            let newCompleted = progressTuple.newCompleted
            let total = progressTuple.total
            let shouldFinalize = progressTuple.shouldFinalize

            let progress = Double(newCompleted) / Double(total)
            AppLogger.network.info("[MultiTrack] \(newCompleted)/\(total) chapters done for \(bookId)")

            Task { @MainActor in
                if self.shouldEmitProgressUpdate(bookId: bookId, progress: progress) {
                    self.progressByBookId[bookId] = progress
                }
                if shouldFinalize {
                    self.activeBookIds.remove(bookId)
                    self.progressByBookId[bookId] = 1
                    self.completedBookIds.insert(bookId)
                    self.lastErrorByBookId.removeValue(forKey: bookId)
                    self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
                    NotificationCenter.default.post(
                        name: Self.downloadDidCompleteNotification,
                        object: nil,
                        userInfo: ["bookId": bookId]
                    )
                }
            }

            if shouldFinalize {
                stateQueue.async(flags: .barrier) { [weak self] in
                    guard let self else { return }
                    self.multiTrackStateByBookId.removeValue(forKey: bookId)
                    self.multiTrackTasksByBookId.removeValue(forKey: bookId)
                    self.bookIdToTask.removeValue(forKey: bookId)
                }
            }
        } catch {
            handleMultiTrackChapterFailure(bookId: bookId, taskId: taskId, error: error)
        }
    }

    nonisolated private func handleMultiTrackChapterFailure(bookId: String, taskId: Int, error: Error) {
        var collectedSiblingTasks: [URLSessionDownloadTask] = []
        var alreadyFailed = false
        stateQueue.sync(flags: .barrier) {
            if let state = multiTrackStateByBookId[bookId] {
                alreadyFailed = state.failed
                state.failed = true
                if state.firstErrorMessage == nil {
                    state.firstErrorMessage = error.localizedDescription
                }
            }
            collectedSiblingTasks = multiTrackTasksByBookId[bookId] ?? []
            multiTrackTaskIdToContext.removeValue(forKey: taskId)
            taskIdToBookId.removeValue(forKey: taskId)
        }
        guard !alreadyFailed else { return }

        let siblingTasks = collectedSiblingTasks

        AppLogger.network.error("[MultiTrack] Chapter \(taskId) failed for \(bookId): \(error.localizedDescription); cancelling siblings")
        for t in siblingTasks where t.taskIdentifier != taskId {
            t.cancel()
        }

        let message = error.localizedDescription
        Task { @MainActor in
            self.activeBookIds.remove(bookId)
            self.progressByBookId.removeValue(forKey: bookId)
            self.lastErrorByBookId[bookId] = message
            self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
        }

        stateQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            self.multiTrackStateByBookId.removeValue(forKey: bookId)
            self.multiTrackTasksByBookId.removeValue(forKey: bookId)
            self.bookIdToTask.removeValue(forKey: bookId)
            for t in siblingTasks {
                self.taskIdToBookId.removeValue(forKey: t.taskIdentifier)
                self.multiTrackTaskIdToContext.removeValue(forKey: t.taskIdentifier)
            }
        }

        let storageCopy = storage
        Task { @MainActor in
            _ = storageCopy.deleteAudiobook(bookId)
        }
    }
}
