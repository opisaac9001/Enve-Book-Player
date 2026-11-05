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

    private let stateQueue = DispatchQueue(label: "BookDownloadManager.state")
    nonisolated private let transferStore: BookHTTPTransferStore
    nonisolated(unsafe) private var nativeTasks: [Int: URLSessionDownloadTask] = [:]
    nonisolated(unsafe) private var retiredTransport = false
    var onBackgroundEventsFinished: (@MainActor @Sendable () async -> Void)?
    var transferInventoryOverride: (@MainActor @Sendable () async -> [URLSessionTask])?

    nonisolated static func backgroundSessionIdentifier(for profileID: String) -> String {
        "com.enve.book-http.\(profileID)"
    }

    nonisolated static func profileID(forBackgroundSessionIdentifier identifier: String) -> String? {
        let prefix = "com.enve.book-http."
        guard identifier.hasPrefix(prefix) else { return nil }
        let id = String(identifier.dropFirst(prefix.count))
        return FamilyProfile.validID(id) ? id : nil
    }

    var persistedStagingDirectoryNames: Set<String> {
        stateQueue.sync { Set(transferStore.all.map(\.stagingName)) }
    }

    var pendingTransferResults: [BookHTTPTransferStore.Transfer] {
        stateQueue.sync { transferStore.all.filter { $0.outcome != .active } }
    }

    func ownsTransferResult(_ transfer: BookHTTPTransferStore.Transfer) -> Bool {
        stateQueue.sync {
            let current = transferStore.transfer(for: transfer.bookID)
            return current?.attemptID == transfer.attemptID && current?.outcome == transfer.outcome
        }
    }

    func acknowledgeTransferResult(bookId: String) {
        do { try stateQueue.sync { try transferStore.acknowledge(bookID: bookId) } }
        catch { AppLogger.network.error("Could not acknowledge audiobook transfer result") }
    }

    func handleBackgroundSession(identifier: String) {
        guard !isRetired, Self.profileID(forBackgroundSessionIdentifier: identifier) == storage.profileStorageLocations.profileID else { return }
        _ = session
    }

    func restoreTransfers() async {
        guard !isRetired else { return }
        let attempts = stateQueue.sync { Set(transferStore.all.filter { $0.outcome == .active }.map(\.attemptID)) }
        let inventory: [URLSessionTask]
        if let transferInventoryOverride { inventory = await transferInventoryOverride() }
        else if backgroundURLSession != nil || !attempts.isEmpty { inventory = await session.allTasks }
        else { inventory = [] }
        guard !isRetired else { return }
        do {
            let outcomes = try stateQueue.sync {
                try transferStore.recover(liveTaskDescriptions: Set(inventory.filter {
                    $0 is URLSessionDownloadTask && ($0.state == .running || $0.state == .suspended)
                }.compactMap(\.taskDescription)), attemptIDs: attempts)
                nativeTasks = nativeTasks.filter { transferStore.transfer(taskDescription: $0.value.taskDescription) != nil }
                for task in inventory {
                    guard let download = task as? URLSessionDownloadTask,
                        task.state == .running || task.state == .suspended,
                        transferStore.transfer(taskDescription: task.taskDescription) != nil else { task.cancel(); continue }
                    nativeTasks[task.taskIdentifier] = download
                    if download.state == .suspended { download.resume() }
                }
                return transferStore.all
            }
            for transfer in outcomes { publish(transfer) }
        } catch { AppLogger.network.error("Could not restore audiobook transfer state") }
    }

    private let storage: LocalStorageManager
    let activity: ProfileDownloadActivity
    private let clientCertificate: @Sendable (String) async -> URLCredential?
    private var isRetired = false
    private var runningJobs: [String: Task<Void, Never>] = [:]
    private var smbServices: [String: SMBService] = [:]
    private var backgroundURLSession: URLSession?
    private var invalidationContinuation: CheckedContinuation<Void, Never>?

    init(
        storage: LocalStorageManager,
        activity: ProfileDownloadActivity,
        clientCertificate: @escaping @Sendable (String) async -> URLCredential?
    ) {
        self.storage = storage
        self.transferStore = BookHTTPTransferStore(storage: storage.profileStorageLocations, audioRoot: storage.audiobooksDirectory)
        self.activity = activity
        self.clientCertificate = clientCertificate
        super.init()
    }

    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        stateQueue.sync { retiredTransport = true }
        let jobs = Array(runningJobs.values)
        jobs.forEach { $0.cancel() }
        for service in Array(smbServices.values) { await service.disconnect() }
        let persistedActive = stateQueue.sync { Set(transferStore.all.filter { $0.outcome == .active }.map(\.bookID)) }
        let sessionToInvalidate = backgroundURLSession ?? (persistedActive.isEmpty ? nil : session)
        for bookID in activeBookIds.union(persistedActive) { cancelDownload(bookId: bookID) }
        if let session = sessionToInvalidate {
            await withCheckedContinuation { continuation in
                invalidationContinuation = continuation
                session.invalidateAndCancel()
            }
            backgroundURLSession = nil
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

    private var session: URLSession {
        if let backgroundURLSession { return backgroundURLSession }
        let config = NetworkPolicyService.shared.makeBackgroundSessionConfiguration(
            identifier: Self.backgroundSessionIdentifier(for: storage.profileStorageLocations.profileID),
            allowCellular: true, isolatesCredentials: storage.profileStorageLocations.profileID != FamilyProfile.ownerID
        )
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 3600
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        backgroundURLSession = session
        return session
    }

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
        startHTTPTransfer(bookId: bookId, requests: [request], mode: .single)
    }

    private func startHTTPTransfer(bookId: String, requests: [URLRequest], mode: BookHTTPTransferStore.Mode) {
        guard !isRetired, !activeBookIds.contains(bookId) else { return }
        do {
            let transfer = try stateQueue.sync {
                try transferStore.begin(bookID: bookId, destination: storage.bookAudioDirectory(for: bookId), mode: mode, count: requests.count)
            }
            let tasks = requests.enumerated().map { index, request in
                var normalized = request
                if normalized.timeoutInterval <= 0 { normalized.timeoutInterval = 300 }
                let task = session.downloadTask(with: normalized)
                task.taskDescription = transfer.taskDescription(for: index)
                return task
            }
            stateQueue.sync { for task in tasks { nativeTasks[task.taskIdentifier] = task } }
            activeBookIds.insert(bookId)
            progressByBookId[bookId] = 0
            lastErrorByBookId.removeValue(forKey: bookId)
            completedBookIds.remove(bookId)
            tasks.forEach { $0.resume() }
        } catch {
            activeBookIds.remove(bookId)
            lastErrorByBookId[bookId] = "Could not prepare the audiobook download."
        }
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
        let tasks: [URLSessionDownloadTask] = stateQueue.sync {
            let matches = nativeTasks.values.filter { transferStore.transfer(taskDescription: $0.taskDescription)?.0.bookID == bookId }
            do { try transferStore.cancel(bookID: bookId) }
            catch { AppLogger.network.error("Could not persist audiobook transfer cancellation") }
            for task in matches { nativeTasks.removeValue(forKey: task.taskIdentifier) }
            return matches
        }
        tasks.forEach { $0.cancel() }
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
        startHTTPTransfer(bookId: bookId, requests: requests.map(\.request), mode: .multiTrack)
    }

    private func publish(_ transfer: BookHTTPTransferStore.Transfer) {
        guard !isRetired, stateQueue.sync(execute: {
            let current = transferStore.transfer(for: transfer.bookID)
            return current?.attemptID == transfer.attemptID && current?.outcome == transfer.outcome
        }) else { return }
        let bookID = transfer.bookID
        switch transfer.outcome {
        case .active:
            activeBookIds.insert(bookID)
            progressByBookId[bookID] = Double(transfer.parts.filter { !$0.fileNames.isEmpty }.count) / Double(transfer.parts.count)
        case .completed:
            activeBookIds.remove(bookID)
            progressByBookId[bookID] = 1
            let newlyCompleted = completedBookIds.insert(bookID).inserted
            lastErrorByBookId.removeValue(forKey: bookID)
            lastProgressEmissionByBookId.removeValue(forKey: bookID)
            if newlyCompleted {
                NotificationCenter.default.post(name: Self.downloadDidCompleteNotification, object: nil, userInfo: ["bookId": bookID])
            }
        case .failed:
            activeBookIds.remove(bookID)
            progressByBookId.removeValue(forKey: bookID)
            lastErrorByBookId[bookID] = transfer.failureMessage
            lastProgressEmissionByBookId.removeValue(forKey: bookID)
        }
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
        if fm.fileExists(atPath: destinationURL.path) { try fm.removeItem(at: destinationURL) }
        do { try fm.moveItem(at: tempURL, to: destinationURL) }
        catch {
            try fm.copyItem(at: tempURL, to: destinationURL)
            try? fm.removeItem(at: tempURL)
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
            defer {
                #if os(iOS)
                CarPlayAppDelegate.consumeBackgroundCompletionHandler(forIdentifier: identifier)?()
                #endif
            }
            guard !isRetired, Self.profileID(forBackgroundSessionIdentifier: identifier) == storage.profileStorageLocations.profileID else { return }
            await restoreTransfers()
            await onBackgroundEventsFinished?()
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
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let context = stateQueue.sync { transferStore.transfer(taskDescription: downloadTask.taskDescription) }
        guard let (transfer, _) = context else { return }
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let completed = transfer.parts.filter { !$0.fileNames.isEmpty }.count
        let progress = (Double(completed) + fraction) / Double(transfer.parts.count)
        Task { @MainActor in
            guard !isRetired, stateQueue.sync(execute: { transferStore.transfer(for: transfer.bookID)?.attemptID == transfer.attemptID && transferStore.transfer(for: transfer.bookID)?.outcome == .active }) else { return }
            if shouldEmitProgressUpdate(bookId: transfer.bookID, progress: progress) { progressByBookId[transfer.bookID] = max(0, min(progress, 1)) }
            if totalBytesExpectedToWrite > 0 { totalBytesByBookId[transfer.bookID] = totalBytesExpectedToWrite * Int64(transfer.parts.count) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // URLSession removes this location when the delegate returns; publication stays inside the serial boundary.
        let outcome: BookHTTPTransferStore.Transfer? = stateQueue.sync {
            guard !retiredTransport, let (transfer, index) = transferStore.transfer(taskDescription: downloadTask.taskDescription),
                transfer.parts[index].fileNames.isEmpty else { try? FileManager.default.removeItem(at: location); return nil }
            defer { nativeTasks.removeValue(forKey: downloadTask.taskIdentifier) }
            do {
                if let http = downloadTask.response as? HTTPURLResponse {
                    guard (200...299).contains(http.statusCode) else { throw CocoaError(.fileReadCorruptFile) }
                    let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    guard !type.contains("text/html"), !type.contains("text/plain"), !type.contains("application/json") else { throw CocoaError(.fileReadCorruptFile) }
                }
                try Self.validateDownloadedFileLength(at: location, response: downloadTask.response)
                let size = ((try FileManager.default.attributesOfItem(atPath: location.path))[.size] as? NSNumber)?.int64Value ?? 0
                guard size > 1024 else { throw CocoaError(.fileReadCorruptFile) }
                let ext = UnifiedDownloadService.detectAudioExtension(urlPathExtension: downloadTask.originalRequest?.url?.pathExtension.lowercased(), response: downloadTask.response, fileURL: location)
                let directory = try transferStore.directory(for: transfer)
                let files: [URL]
                if transfer.mode == .single && (ext == "zip" || isZipFile(at: location)) {
                    files = try extractAudioFilesFromZip(at: location, into: directory.staging)
                } else {
                    if UnifiedDownloadService.detectExtensionFromMagicBytes(at: location) == nil {
                        let data = try Data(contentsOf: location, options: .mappedIfSafe)
                        if let text = String(data: data.prefix(512), encoding: .utf8)?.lowercased(), text.contains("<!doctype") || text.contains("<html") {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                    }
                    guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw CocoaError(.fileWriteInvalidFileName) }
                    let destination = directory.staging.appendingPathComponent("chapter_\(index).\(ext)")
                    try persistDownloadedTempFile(tempURL: location, destinationURL: destination)
                    files = [destination]
                }
                for file in files { try AtomicDownloadDirectory.makeBackgroundReadable(file) }
                return try transferStore.completePart(bookID: transfer.bookID, attemptID: transfer.attemptID, index: index, fileNames: files.map(\.lastPathComponent))
            } catch {
                try? FileManager.default.removeItem(at: location)
                let failed = failTransfer(bookID: transfer.bookID, attemptID: transfer.attemptID, category: .invalidResponse,
                    httpStatusCode: (downloadTask.response as? HTTPURLResponse).flatMap { (200...299).contains($0.statusCode) ? nil : $0.statusCode })
                cancelNativeTasks(for: transfer.attemptID)
                return failed
            }
        }
        if let outcome { Task { @MainActor in publish(outcome) } }
    }

    nonisolated private func failTransfer(
        bookID: String, attemptID: UUID, category: BookHTTPTransferStore.Failure, httpStatusCode: Int? = nil
    ) -> BookHTTPTransferStore.Transfer? {
        do {
            return try transferStore.fail(bookID: bookID, attemptID: attemptID, category: category, httpStatusCode: httpStatusCode)
        } catch {
            AppLogger.network.error("Could not persist the audiobook transfer failure")
            return transferStore.transfer(for: bookID).flatMap { $0.outcome == .active ? nil : $0 }
        }
    }

    nonisolated private func cancelNativeTasks(for attemptID: UUID) {
        let matches = nativeTasks.filter { $0.value.taskDescription?.hasPrefix("enve-http.\(attemptID.uuidString).") == true }
        for (identifier, task) in matches {
            nativeTasks.removeValue(forKey: identifier)
            task.cancel()
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        let outcome: BookHTTPTransferStore.Transfer? = stateQueue.sync {
            guard !retiredTransport, let (transfer, _) = transferStore.transfer(taskDescription: task.taskDescription) else { return nil }
            nativeTasks.removeValue(forKey: task.taskIdentifier)
            let result = failTransfer(bookID: transfer.bookID, attemptID: transfer.attemptID, category: .transport,
                httpStatusCode: (task.response as? HTTPURLResponse).flatMap { (200...299).contains($0.statusCode) ? nil : $0.statusCode })
            cancelNativeTasks(for: transfer.attemptID)
            return result
        }
        if let outcome { Task { @MainActor in publish(outcome) } }
    }
}
