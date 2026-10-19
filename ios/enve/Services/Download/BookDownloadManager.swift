import Combine
import Foundation
import Logging
import Zip

#if canImport(UIKit)
import UIKit
#endif

final class BookDownloadManager: NSObject, ObservableObject {
    static let shared = BookDownloadManager(
        storage: .shared,
        activity: ProfileDownloadActivity(),
        clientCertificate: { host in
            guard let identity = NetworkHostUtils.findMTLSIdentity(forHost: host) else { return nil }
            return URLCredential(identity: identity, certificates: nil, persistence: .forSession)
        }
    )

    nonisolated static let downloadDidCompleteNotification = Notification.Name("BookDownloadManager.downloadDidComplete")

    @Published private(set) var progressByBookId: [String: Double] = [:]
    @Published private(set) var totalBytesByBookId: [String: Int64] = [:]
    @Published private(set) var activeBookIds: Set<String> = [] {
        didSet {
            activity.externalBookIDs = activeBookIds
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
        let id = UUID()
        let directory: AtomicDownloadDirectory
        let total: Int
        var published = false
        var completedCount: Int = 0
        var failed: Bool = false
        var firstErrorMessage: String?
        init(bookId: String, directory: AtomicDownloadDirectory, total: Int) {
            self.bookId = bookId
            self.directory = directory
            self.total = total
        }
    }
    nonisolated(unsafe) private var multiTrackStateByBookId: [String: MultiTrackDownloadState] = [:]
    nonisolated(unsafe) private var multiTrackTaskIdToContext: [Int: (bookId: String, chapterIndex: Int, generation: UUID)] = [:]
    nonisolated(unsafe) private var multiTrackTasksByBookId: [String: [URLSessionDownloadTask]] = [:]

    private let storage: LocalStorageManager
    let activity: ProfileDownloadActivity
    private let clientCertificate: @Sendable (String) async -> URLCredential?
    private var isRetired = false
    private var runningJobs: [String: Task<Void, Never>] = [:]
    private var smbServices: [String: SMBService] = [:]
    private var invalidationContinuation: CheckedContinuation<Void, Never>?

    init(
        storage: LocalStorageManager,
        activity: ProfileDownloadActivity,
        clientCertificate: @escaping @Sendable (String) async -> URLCredential?
    ) {
        self.storage = storage
        self.activity = activity
        self.clientCertificate = clientCertificate
        super.init()
    }

    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        let jobs = Array(runningJobs.values)
        jobs.forEach { $0.cancel() }
        for service in Array(smbServices.values) { await service.disconnect() }
        for bookID in activeBookIds { cancelDownload(bookId: bookID) }
        await withCheckedContinuation { continuation in
            invalidationContinuation = continuation
            session.invalidateAndCancel()
        }
        for job in jobs { await job.value }
        runningJobs.removeAll()
        activeBookIds.removeAll()
    }

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

    private lazy var session: URLSession = {
        let config = NetworkPolicyService.shared.makeSessionConfiguration(
            allowCellular: true, isolatesCredentials: storage.profileStorageLocations.profileID != FamilyProfile.ownerID
        )
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
        guard !isRetired, !Task.isCancelled else { return }
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
        guard !isRetired, !Task.isCancelled else { return }
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

        let job = Task.detached(priority: .utility) { [weak self] in
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
                    try Task.checkCancellation()
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
        runningJobs[bookId] = job
        await job.value
        runningJobs.removeValue(forKey: bookId)
    }

    func cancelDownload(bookId: String) {
        runningJobs[bookId]?.cancel()
        var tasksToCancel: [URLSessionDownloadTask] = []
        stateQueue.sync(flags: .barrier) {
            tasksToCancel = multiTrackTasksByBookId.removeValue(forKey: bookId) ?? []
            if let task = bookIdToTask.removeValue(forKey: bookId), tasksToCancel.isEmpty { tasksToCancel = [task] }
            if let state = multiTrackStateByBookId.removeValue(forKey: bookId) {
                state.failed = true
                state.directory.discard()
            }
            for task in tasksToCancel {
                taskIdToBookId.removeValue(forKey: task.taskIdentifier)
                multiTrackTaskIdToContext.removeValue(forKey: task.taskIdentifier)
            }
        }
        tasksToCancel.forEach { $0.cancel() }
        activeBookIds.remove(bookId)
        progressByBookId.removeValue(forKey: bookId)
    }

    func startSMBDownload(bookId: String, smbBook: SMBBook, source: SMBLibrarySource, password: String) async {
        guard !isRetired, !Task.isCancelled, runningJobs[bookId] == nil else { return }
        let job = Task { await performSMBDownload(bookId: bookId, smbBook: smbBook, source: source, password: password) }
        runningJobs[bookId] = job
        await job.value
        runningJobs.removeValue(forKey: bookId)
    }

    private func performSMBDownload(bookId: String, smbBook: SMBBook, source: SMBLibrarySource, password: String) async {
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
            smbServices[bookId] = smbService
            defer { smbServices.removeValue(forKey: bookId) }
            let config = source.toServerConfiguration()
            try await smbService.connect(config: config, password: password)
            try Task.checkCancellation()

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
                try Task.checkCancellation()
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

                try Task.checkCancellation()
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
        guard !isRetired, !Task.isCancelled else { return }
        let alreadyActive = await MainActor.run { activeBookIds.contains(bookId) }
        if alreadyActive { return }

        await MainActor.run {
            activeBookIds.insert(bookId)
            progressByBookId[bookId] = 0
            lastErrorByBookId.removeValue(forKey: bookId)
            completedBookIds.remove(bookId)
        }

        guard !requests.isEmpty else {
            await failMultiTrackDownload(bookId: bookId, errorMessage: "No tracks to download")
            return
        }
        let state: MultiTrackDownloadState
        do {
            let directory = try AtomicDownloadDirectory(destination: storage.bookAudioDirectory(for: bookId))
            state = MultiTrackDownloadState(bookId: bookId, directory: directory, total: requests.count)
        } catch {
            await failMultiTrackDownload(bookId: bookId, errorMessage: error.localizedDescription)
            return
        }

        let scheduledTasks: [URLSessionDownloadTask] = requests.map { entry in
            var req = entry.request
            if req.timeoutInterval <= 0 { req.timeoutInterval = 300 }
            return session.downloadTask(with: req)
        }
        let contextEntries: [(taskId: Int, chapterIndex: Int)] = scheduledTasks.enumerated().map { index, task in
            (task.taskIdentifier, index)
        }

        stateQueue.sync(flags: .barrier) {
            self.multiTrackStateByBookId[bookId] = state
            self.multiTrackTasksByBookId[bookId] = scheduledTasks
            for entry in contextEntries {
                self.multiTrackTaskIdToContext[entry.taskId] = (bookId, entry.chapterIndex, state.id)
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

    // A dropped connection can still finish a task without error; compare against the declared full-body length.
    nonisolated static func validateDownloadedFileLength(at url: URL, response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, http.expectedContentLength > 0,
            (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity"
        else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size == http.expectedContentLength else {
            throw NSError(domain: "BookDownloadManager", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "Download incomplete: received \(size) of \(http.expectedContentLength) bytes"
            ])
        }
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
    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        Task { @MainActor in
            invalidationContinuation?.resume()
            invalidationContinuation = nil
        }
    }

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
            Task {
                let credential = await clientCertificate(host)
                completionHandler(credential == nil ? .performDefaultHandling : .useCredential, credential)
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

    /// Restore credentials only on the original request origin; strip them elsewhere and reject unsafe redirects.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, HTTPRedirectPolicy.isFollowable(url, from: response.url) else {
            AppLogger.network.warning("Refused an unsafe download redirect")
            completionHandler(nil)
            return
        }

        let origin = HTTPRedirectPolicy.origin(ofOriginalRequestIn: task)
        guard origin?.matches(url) == true else {
            completionHandler(HTTPRedirectPolicy.sanitized(request, keepingCredentialsFor: origin))
            return
        }

        var redirected = request
        if let originalAuth = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
            redirected.value(forHTTPHeaderField: "Authorization") == nil
        {
            redirected.setValue(originalAuth, forHTTPHeaderField: "Authorization")
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
        var multiTrackContext: (bookId: String, chapterIndex: Int, generation: UUID)?
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

            try Self.validateDownloadedFileLength(at: location, response: downloadTask.response)

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
        var multiTrackContext: (bookId: String, chapterIndex: Int, generation: UUID)?
        stateQueue.sync {
            bookId = taskIdToBookId[taskId]
            multiTrackContext = multiTrackTaskIdToContext[taskId]
        }
        guard let bookId else { return }

        if let context = multiTrackContext {
            handleMultiTrackChapterFailure(bookId: bookId, taskId: taskId, generation: context.generation, error: error)
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
        taskId: Int, downloadTask: URLSessionDownloadTask, location: URL,
        context: (bookId: String, chapterIndex: Int, generation: UUID)
    ) {
        let bookId = context.bookId
        do {
            let update: (completed: Int, total: Int, finalized: Bool)? = try stateQueue.sync(flags: .barrier) {
                guard let state = multiTrackStateByBookId[bookId], state.id == context.generation,
                    !state.failed, !state.published else { return nil }
                if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw NSError(domain: NSURLErrorDomain, code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Track \(context.chapterIndex) HTTP \(http.statusCode)"])
                }
                let ext = UnifiedDownloadService.detectAudioExtension(
                    urlPathExtension: downloadTask.originalRequest?.url?.pathExtension.lowercased(),
                    response: downloadTask.response, fileURL: location)
                let destination = state.directory.staging.appendingPathComponent("chapter_\(context.chapterIndex).\(ext)")
                try persistDownloadedTempFile(tempURL: location, destinationURL: destination)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path),
                    let size = attrs[.size] as? Int64, size > 1024 else {
                    throw NSError(domain: "BookDownloadManager", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Downloaded track is too small"])
                }
                try Self.validateDownloadedFileLength(at: destination, response: downloadTask.response)
                state.completedCount += 1
                multiTrackTaskIdToContext.removeValue(forKey: taskId)
                taskIdToBookId.removeValue(forKey: taskId)
                let finalized = state.completedCount == state.total
                if finalized {
                    try state.directory.publish()
                    state.published = true
                }
                return (state.completedCount, state.total, finalized)
            }
            guard let update else { try? FileManager.default.removeItem(at: location); return }
            Task { @MainActor in
                guard self.isCurrentMultiTrackAttempt(bookId, generation: context.generation) else { return }
                let progress = Double(update.completed) / Double(update.total)
                if self.shouldEmitProgressUpdate(bookId: bookId, progress: progress) { self.progressByBookId[bookId] = progress }
                if update.finalized {
                    self.activeBookIds.remove(bookId)
                    self.progressByBookId[bookId] = 1
                    self.completedBookIds.insert(bookId)
                    self.lastErrorByBookId.removeValue(forKey: bookId)
                    self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
                    self.finishMultiTrackAttempt(bookId, generation: context.generation)
                    NotificationCenter.default.post(name: Self.downloadDidCompleteNotification,
                        object: nil, userInfo: ["bookId": bookId])
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: location)
            handleMultiTrackChapterFailure(bookId: bookId, taskId: taskId, generation: context.generation, error: error)
        }
    }

    nonisolated private func isCurrentMultiTrackAttempt(_ bookId: String, generation: UUID) -> Bool {
        stateQueue.sync { multiTrackStateByBookId[bookId]?.id == generation }
    }

    nonisolated private func finishMultiTrackAttempt(_ bookId: String, generation: UUID) {
        stateQueue.sync(flags: .barrier) {
            guard multiTrackStateByBookId[bookId]?.id == generation else { return }
            multiTrackStateByBookId.removeValue(forKey: bookId)?.directory.discard()
            let tasks = multiTrackTasksByBookId.removeValue(forKey: bookId) ?? []
            bookIdToTask.removeValue(forKey: bookId)
            for task in tasks {
                taskIdToBookId.removeValue(forKey: task.taskIdentifier)
                multiTrackTaskIdToContext.removeValue(forKey: task.taskIdentifier)
            }
        }
    }

    nonisolated private func handleMultiTrackChapterFailure(bookId: String, taskId: Int, generation: UUID, error: Error) {
        let siblings: [URLSessionDownloadTask]? = stateQueue.sync(flags: .barrier) {
            guard let state = multiTrackStateByBookId[bookId], state.id == generation,
                !state.failed, !state.published else { return nil }
            state.failed = true
            state.directory.discard()
            return multiTrackTasksByBookId[bookId] ?? []
        }
        guard let siblings else { return }
        siblings.forEach { $0.cancel() }
        let message = error.localizedDescription
        Task { @MainActor in
            guard self.isCurrentMultiTrackAttempt(bookId, generation: generation) else { return }
            self.activeBookIds.remove(bookId)
            self.progressByBookId.removeValue(forKey: bookId)
            self.lastErrorByBookId[bookId] = message
            self.lastProgressEmissionByBookId.removeValue(forKey: bookId)
            self.finishMultiTrackAttempt(bookId, generation: generation)
        }
    }
}
