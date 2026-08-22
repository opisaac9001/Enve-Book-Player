import Darwin
import Foundation
import Logging
import os

nonisolated final class FileWatcher: Sendable {
    private let source = OSAllocatedUnfairLock<DispatchSourceFileSystemObject?>(initialState: nil)
    private let fileDescriptor = OSAllocatedUnfairLock<Int32>(initialState: -1)
    private let path: String
    private let label: String
    private let onChange: @Sendable () -> Void

    init(path: String, label: String, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.label = label
        self.onChange = onChange
    }

    nonisolated func start() -> Bool {
        source.withLock { currentSource in
            guard currentSource == nil else { return }

            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                AppLogger.network.warning(
                    "Could not watch folder pathId=\(DiagnosticLogSanitizer.identifier(for: path)) (fd=\(fd))"
                )
                return
            }

            fileDescriptor.withLock { $0 = fd }
            AppLogger.network.info("Opened file descriptor \(fd) for \(label)")

            let queue = DispatchQueue(label: "enve.fileSharing.watch.\(label)", qos: .utility)
            let newSource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: queue
            )

            let handler = onChange
            let capturedLabel = label
            newSource.setEventHandler {
                AppLogger.network.info("\(capturedLabel) folder changed!")
                handler()
            }

            let capturedFD = fd
            newSource.setCancelHandler {
                close(capturedFD)
            }

            currentSource = newSource
            newSource.resume()
        }
        return true
    }

    nonisolated func stop() {
        source.withLock { currentSource in
            currentSource?.cancel()
            currentSource = nil
        }
        fileDescriptor.withLock { $0 = -1 }
    }
}

@MainActor
final class FileSharingImportCoordinator {
    static let shared = FileSharingImportCoordinator()

    private let fingerprintKey = "fileSharingImport.lastFolderFingerprint"

    private var currentTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?
    private var needsRefreshAfterCurrent = false
    private var lastRunAt: Date?
    private var suppressWatcherEventsUntil: Date = .distantPast

    private var documentsWatcher: FileWatcher?
    private var inboxWatcher: FileWatcher?

    private let refreshDebounceNanoseconds: UInt64 = 1_000_000_000
    private let refreshThrottleSeconds: TimeInterval = 2
    private let watcherSuppressionSeconds: TimeInterval = 4

    private init() {}

    func startWatching() {
        startWatchingDocumentsIfNeeded()
        startWatchingInboxIfNeeded()
    }

    func stopWatching() {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil

        documentsWatcher?.stop()
        documentsWatcher = nil
        inboxWatcher?.stop()
        inboxWatcher = nil
    }

    func scheduleRefresh(reason: String) {
        let now = Date()

        if now < suppressWatcherEventsUntil {
            AppLogger.network.info("Ignoring \(reason) refresh (suppressed for self-trigger protection)")
            return
        }

        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.refreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.refreshOnForeground(reason: reason)
            }
        }
    }

    func refreshOnForeground(reason: String = "manual") {
        AppLogger.network.info("FileSharingImportCoordinator.refreshOnForeground() called (reason: \(reason))")

        if let lastRunAt, Date().timeIntervalSince(lastRunAt) < refreshThrottleSeconds {
            AppLogger.network.info("Throttled (last run \(Date().timeIntervalSince(lastRunAt))s ago)")
            return
        }

        if currentTask != nil {
            AppLogger.network.info("Already running - will re-run after current task")
            needsRefreshAfterCurrent = true
            return
        }

        suppressWatcherEventsUntil = Date().addingTimeInterval(watcherSuppressionSeconds)

        currentTask = Task { [weak self] in
            guard let self else { return }
            defer {
                Task { @MainActor in
                    self.lastRunAt = Date()
                    self.currentTask = nil
                    self.suppressWatcherEventsUntil = Date().addingTimeInterval(self.watcherSuppressionSeconds)
                    if self.needsRefreshAfterCurrent {
                        self.needsRefreshAfterCurrent = false
                        self.refreshOnForeground(reason: "queued")
                    }
                }
            }

            if reason != "watcher" {

                let fpStart = Date()
                let fingerprint: String? = await Task.detached(priority: .userInitiated) { [weak self] in
                    do {
                        return try self?.computeFolderFingerprint()
                    } catch is CancellationError {
                        return nil
                    } catch {
                        AppLogger.network.error("File-sharing fingerprint skipped: \(error.localizedDescription)")
                        return nil
                    }
                }.value
                let fpMs = Int(Date().timeIntervalSince(fpStart) * 1000)
                AppLogger.network.info("FileSharing fingerprint computed in \(fpMs)ms")
                if let currentFingerprint = fingerprint,
                    currentFingerprint == UserDefaults.standard.string(forKey: self.fingerprintKey)
                {
                    let existingBooks = LocalLibraryStorageStore.shared.loadBooks(libraryId: LocalLibraryService.fileSharingLibraryId)
                    if !existingBooks.isEmpty {
                        AppLogger.network.warning("No file-sharing folder changes detected, skipping scan")
                        return
                    }
                    AppLogger.network.info("Fingerprint matches but book cache is empty - forcing re-scan")
                }
            }

            AppLogger.network.info("Seeding library if needed...")
            seedFileSharingLibraryIfNeeded()

            do {
                AppLogger.network.debug(
                    "Documents pathId=\(DiagnosticLogSanitizer.identifier(for: LocalLibraryService.fileSharingRootURL.standardizedFileURL.path))"
                )

                let fm = FileManager.default
                if let items = try? fm.contentsOfDirectory(
                    at: LocalLibraryService.fileSharingRootURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    AppLogger.network.debug("Documents contains \(items.count) items")
                    for item in items.prefix(10) {
                        AppLogger.network.debug(
                            "itemId=\(DiagnosticLogSanitizer.identifier(for: item.lastPathComponent))"
                        )
                    }
                }

                AppLogger.network.info("Ingesting pending file-sharing items...")
                let ingestResult = try await LocalLibraryService.shared.ingestFileSharingPendingItems()
                if ingestResult.movedItems > 0 {
                    AppLogger.network.info("Ingest moved \(ingestResult.movedItems) item(s) to Individual_Audiobooks")
                } else {
                    AppLogger.network.info("No pending items to ingest")
                }

                let pendingZIPs = collectPendingZIPFiles()
                if !pendingZIPs.isEmpty {
                    AppLogger.network.info("Found \(pendingZIPs.count) ZIP file(s) to extract...")
                    let extracted = try await RemoteImportService.shared.importFromFilesApp(urls: pendingZIPs)
                    AppLogger.network.info("Extracted \(extracted.count) book(s) from ZIP file(s)")
                    for zipURL in pendingZIPs {
                        try? FileManager.default.removeItem(at: zipURL)
                    }
                }

                let library = LocalLibrary(
                    id: LocalLibraryService.fileSharingLibraryId,
                    name: "Drag & Drop Books",
                    folderPath: LocalLibraryService.fileSharingRootURL.path,
                    createdAt: Date(),
                    isEnabled: true,
                    type: .fileSharing
                )

                let existingBooks = LocalLibraryStorageStore.shared.loadBooks(libraryId: LocalLibraryService.fileSharingLibraryId)
                let previousSignature = scanSignature(for: existingBooks)

                AppLogger.network.info("Starting scan...")
                let result = try await LocalLibraryService.shared.scanLibrary(library)
                AppLogger.network.info("Scan complete: found \(result.booksFound.count) books")

                let updatedFingerprint: String? = await Task.detached(priority: .utility) { [weak self] in
                    do {
                        return try self?.computeFolderFingerprint()
                    } catch is CancellationError {
                        return nil
                    } catch {
                        AppLogger.network.error("File-sharing fingerprint update skipped: \(error.localizedDescription)")
                        return nil
                    }
                }.value
                if let updatedFingerprint {
                    UserDefaults.standard.set(updatedFingerprint, forKey: self.fingerprintKey)
                }

                let newSignature = scanSignature(for: result.booksFound)
                if newSignature != previousSignature {
                    LocalLibraryStorageStore.shared.saveScanResult(result)
                    NotificationCenter.default.post(name: .localLibraryUpdated, object: LocalLibraryService.fileSharingLibraryId)
                    AppLogger.network.info("Posted .localLibraryUpdated notification")
                } else {
                    AppLogger.network.info("File-sharing scan unchanged - skipping .localLibraryUpdated notification")
                }
            } catch {
                AppLogger.network.error("File sharing refresh failed: \(error)")
            }
        }
    }

    private func scanSignature(for books: [LocalBookFile]) -> Set<String> {
        Set(
            books.map { book in
                let normalizedPath = URL(fileURLWithPath: book.filePath).standardizedFileURL.path
                let hash = book.fileHash ?? "nohash"
                return "\(normalizedPath)|\(book.fileSize)|\(hash)|\(book.format)"
            }
        )
    }

    nonisolated private func computeFolderFingerprint() throws -> String? {
        let rootURL = LocalLibraryService.fileSharingRootURL
        let canonicalURL = rootURL.appendingPathComponent("Individual_Audiobooks", isDirectory: true)
        let inboxURL = rootURL.appendingPathComponent("Inbox", isDirectory: true)
        let ebooksURL = rootURL.appendingPathComponent("Ebooks/local", isDirectory: true)

        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
        let fm = FileManager.default

        var fragments: [String] = []
        var budget = ImportScanBudget()

        for url in [canonicalURL, inboxURL, ebooksURL] {
            guard fm.fileExists(atPath: url.path) else { continue }
            if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    try budget.record(url: fileURL, root: url)
                    guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
                    let mod = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    let size = values.fileSize ?? 0
                    let dir = values.isDirectory == true ? 1 : 0
                    fragments.append("\(fileURL.path)|\(mod)|\(size)|\(dir)")
                }
            }
        }

        if let rootItems = try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) {
            for item in rootItems {
                let name = item.lastPathComponent
                if name == "Individual_Audiobooks" || name == "Inbox" { continue }
                try budget.record(url: item, root: rootURL)
                guard let values = try? item.resourceValues(forKeys: keys) else { continue }
                let ext = item.pathExtension.lowercased()
                let isAudio = ["m4b", "m4a", "mp3", "aac", "flac", "ogg", "opus", "mp4", "aiff", "wav"].contains(ext)
                let isEbook = ["epub", "pdf", "cbz", "cbr", "mobi", "azw3", "azw"].contains(ext)
                let isImage = EbookFormat.isImagePageExtension(ext)
                let isZip = ext == "zip"
                let isDir = values.isDirectory == true
                if isAudio || isEbook || isImage || isZip || isDir {
                    let mod = values.contentModificationDate?.timeIntervalSince1970 ?? 0
                    let size = values.fileSize ?? 0
                    fragments.append("root/\(item.path)|\(mod)|\(size)|\(isDir ? 1 : 0)")
                }
            }
        }

        if fragments.isEmpty {
            return "empty"
        }
        return fragments.sorted().joined(separator: "#")
    }

    private func startWatchingDocumentsIfNeeded() {
        guard documentsWatcher == nil else {
            AppLogger.network.info("Documents watcher already active")
            return
        }

        let watchURL = LocalLibraryService.fileSharingRootURL.appendingPathComponent("Individual_Audiobooks", isDirectory: true)
        if !FileManager.default.fileExists(atPath: watchURL.path) {
            try? FileManager.default.createDirectory(at: watchURL, withIntermediateDirectories: true)
        }
        AppLogger.network.debug(
            "Starting Documents watcher pathId=\(DiagnosticLogSanitizer.identifier(for: watchURL.standardizedFileURL.path))"
        )

        let watcher = FileWatcher(path: watchURL.path, label: "Documents") {
            Task { @MainActor in
                FileSharingImportCoordinator.shared.scheduleRefresh(reason: "watcher")
            }
        }

        if watcher.start() {
            documentsWatcher = watcher
        }
    }

    private func startWatchingInboxIfNeeded() {
        guard inboxWatcher == nil else { return }

        let inboxURL = LocalLibraryService.fileSharingRootURL.appendingPathComponent("Inbox", isDirectory: true)
        if !FileManager.default.fileExists(atPath: inboxURL.path) {
            try? FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: inboxURL.path) else { return }

        let watcher = FileWatcher(path: inboxURL.path, label: "Inbox") {
            Task { @MainActor in
                FileSharingImportCoordinator.shared.scheduleRefresh(reason: "watcher")
            }
        }

        if watcher.start() {
            inboxWatcher = watcher
        }
    }

    private func seedFileSharingLibraryIfNeeded() {
        let existing = LocalLibraryStorageStore.shared.loadLibraries()

        if existing.contains(where: { $0.id == LocalLibraryService.fileSharingLibraryId }) {
            return
        }

        let library = LocalLibrary(
            id: LocalLibraryService.fileSharingLibraryId,
            name: "Drag & Drop Books",
            folderPath: LocalLibraryService.fileSharingRootURL.path,
            createdAt: Date(),
            isEnabled: true,
            type: .fileSharing
        )

        LocalLibraryStorageStore.shared.saveLibrary(library)
    }

    private func collectPendingZIPFiles() -> [URL] {
        let fm = FileManager.default
        let root = LocalLibraryService.fileSharingRootURL
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let canonical = root.appendingPathComponent("Individual_Audiobooks", isDirectory: true)

        var zips: [URL] = []

        if let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for item in items {
                if item.standardizedFileURL.path == canonical.standardizedFileURL.path { continue }
                if item.lastPathComponent == "Inbox" { continue }
                if item.pathExtension.lowercased() == "zip" {
                    appendValidatedZIP(item, to: &zips)
                }
            }
        }

        if fm.fileExists(atPath: inbox.path),
            let items = try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        {
            for item in items where item.pathExtension.lowercased() == "zip" {
                appendValidatedZIP(item, to: &zips)
            }
        }

        return zips
    }

    private func appendValidatedZIP(_ item: URL, to zips: inout [URL]) {
        do {
            try ImportLimits.validateArchiveFile(item)
            zips.append(item)
        } catch {
            AppLogger.network.error(
                "Skipping ZIP import fileId=\(DiagnosticLogSanitizer.identifier(for: item.lastPathComponent)): \(error.localizedDescription)"
            )
        }
    }
}
