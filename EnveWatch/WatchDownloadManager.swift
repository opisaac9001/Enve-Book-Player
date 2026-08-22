import Foundation
import Observation
import WatchKit

enum WatchDownloadStatus: Equatable, Sendable {
    case preparing
    case downloading(Double)
    case failed(String)
}

@MainActor
@Observable
final class WatchDownloadManager: NSObject {
    static let shared = WatchDownloadManager()

    private(set) var active: [String: WatchDownloadStatus] = [:]

    private var sessions: [String: URLSession] = [:]
    private var pendingRefreshTasks: [String: WKRefreshBackgroundTask] = [:]
    private let progressBox = ProgressBox()

    private nonisolated static let identifierPrefix = "com.enve.enve.watch.dl."
    private nonisolated static let mappingKey = "watchDownloadSessionMap"

    private override init() {
        super.init()

        let map = (UserDefaults.standard.dictionary(forKey: Self.mappingKey) as? [String: String]) ?? [:]
        for identifier in map.keys {
            reconnect(identifier: identifier)
        }
    }

    func isDownloading(_ stableId: String) -> Bool {
        active[stableId] != nil
    }

    func start(stableId: String) async {
        guard active[stableId] == nil else { return }
        if let local = WatchLocalStore.shared.book(stableId: stableId), local.isComplete { return }
        active[stableId] = .preparing

        do {

            let descriptor = try await PhoneLink.shared.request(
                .requestDescriptor,
                WatchDescriptorRequest(stableId: stableId),
                as: WatchPlaybackDescriptor.self
            )
            let existing = WatchLocalStore.shared.book(stableId: stableId)
            let manifest = WatchLocalBook(
                descriptor: descriptor,
                completedTracks: existing?.completedTracks ?? [:],
                savedPosition: existing?.savedPosition ?? descriptor.startTime,
                savedAt: existing?.savedAt ?? Date()
            )
            WatchLocalStore.shared.upsert(manifest)
            Task { _ = await WatchCoverStore.shared.image(for: stableId) }

            let session = session(for: stableId)

            let inFlight = Set(await session.allTasks.compactMap(\.taskDescription))
            var enqueued = 0
            for track in descriptor.tracks where manifest.completedTracks[track.index] == nil {
                let description = "\(track.index)|track_\(track.index).\(track.fileExtension)"
                if inFlight.contains(description) {
                    enqueued += 1
                    continue
                }
                guard let url = URL(string: track.url) else { continue }
                var request = URLRequest(url: url)
                for (key, value) in descriptor.headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                let task = session.downloadTask(with: request)
                task.taskDescription = description
                task.resume()
                enqueued += 1
            }
            if enqueued == 0 {
                finish(stableId: stableId)
            } else {
                active[stableId] = .downloading(progress(for: stableId))
            }
        } catch {
            active[stableId] = .failed(error.localizedDescription)
        }
    }

    func cancel(stableId: String) {
        let identifier = Self.identifier(for: stableId)
        sessions[identifier]?.invalidateAndCancel()
        sessions[identifier] = nil
        Self.removeMapping(identifier: identifier)
        active[stableId] = nil
        if WatchLocalStore.shared.book(stableId: stableId)?.isComplete != true {
            WatchLocalStore.shared.delete(stableId: stableId)
        }
    }

    func dismissFailure(stableId: String) {
        if case .failed = active[stableId] {
            active[stableId] = nil
        }
    }

    private nonisolated static func identifier(for stableId: String) -> String {
        identifierPrefix + WatchCoverStore.sanitized(stableId)
    }

    private nonisolated static func stableId(forIdentifier identifier: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: mappingKey) as? [String: String]
        return map?[identifier]
    }

    private nonisolated static func storeMapping(identifier: String, stableId: String) {
        var map = (UserDefaults.standard.dictionary(forKey: mappingKey) as? [String: String]) ?? [:]
        map[identifier] = stableId
        UserDefaults.standard.set(map, forKey: mappingKey)
    }

    private nonisolated static func removeMapping(identifier: String) {
        var map = (UserDefaults.standard.dictionary(forKey: mappingKey) as? [String: String]) ?? [:]
        map.removeValue(forKey: identifier)
        UserDefaults.standard.set(map, forKey: mappingKey)
    }

    private func session(for stableId: String) -> URLSession {
        let identifier = Self.identifier(for: stableId)
        if let existing = sessions[identifier] {
            return existing
        }
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 4 * 60 * 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        sessions[identifier] = session
        Self.storeMapping(identifier: identifier, stableId: stableId)
        return session
    }

    func handle(_ refreshTask: WKURLSessionRefreshBackgroundTask) {
        guard Self.stableId(forIdentifier: refreshTask.sessionIdentifier) != nil else {
            refreshTask.setTaskCompletedWithSnapshot(false)
            return
        }
        pendingRefreshTasks[refreshTask.sessionIdentifier] = refreshTask
        reconnect(identifier: refreshTask.sessionIdentifier)
    }

    private func reconnect(identifier: String) {
        guard sessions[identifier] == nil else { return }
        guard let stableId = Self.stableId(forIdentifier: identifier) else { return }
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        sessions[identifier] = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        if active[stableId] == nil {
            active[stableId] = .downloading(progress(for: stableId))
        }
    }

    private func progress(for stableId: String) -> Double {
        guard let book = WatchLocalStore.shared.book(stableId: stableId) else { return 0 }
        let total = max(book.descriptor.tracks.count, 1)
        let completed = Double(book.completedTracks.count)
        let inFlight = progressBox.aggregateFraction(stableId: stableId)
        return min((completed + inFlight) / Double(total), 1)
    }

    private func trackLanded(stableId: String, trackIndex: Int, fileName: String) {
        WatchLocalStore.shared.markTrackComplete(stableId: stableId, trackIndex: trackIndex, fileName: fileName)
        if WatchLocalStore.shared.book(stableId: stableId)?.isComplete == true {
            finish(stableId: stableId)
        } else if case .downloading = active[stableId] {

            active[stableId] = .downloading(progress(for: stableId))
        }
    }

    private func finish(stableId: String) {
        let identifier = Self.identifier(for: stableId)
        sessions[identifier]?.finishTasksAndInvalidate()
        sessions[identifier] = nil
        Self.removeMapping(identifier: identifier)
        progressBox.clear(stableId: stableId)
        active[stableId] = nil
    }

    private func failed(stableId: String, message: String) {
        active[stableId] = .failed(message)
    }
}

extension WatchDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let identifier = session.configuration.identifier,
            let stableId = Self.stableId(forIdentifier: identifier),
            let description = downloadTask.taskDescription,
            let separator = description.firstIndex(of: "|"),
            let trackIndex = Int(description[..<separator])
        else { return }
        let fileName = String(description[description.index(after: separator)...])

        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            progressBox.remove(stableId: stableId, taskId: downloadTask.taskIdentifier)
            Task { @MainActor in
                WatchDownloadManager.shared.failed(stableId: stableId, message: "Server error \(http.statusCode)")
            }
            return
        }

        if let mime = downloadTask.response?.mimeType?.lowercased(), mime.hasPrefix("text/") || mime.contains("html") {
            progressBox.remove(stableId: stableId, taskId: downloadTask.taskIdentifier)
            Task { @MainActor in
                WatchDownloadManager.shared.failed(
                    stableId: stableId,
                    message: "Server returned a web page instead of audio - check the connection's login."
                )
            }
            return
        }

        let directory = URL.documentsDirectory
            .appendingPathComponent("Audiobooks", isDirectory: true)
            .appendingPathComponent(WatchCoverStore.sanitized(stableId), isDirectory: true)
        let destination = directory.appendingPathComponent(fileName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in
                WatchDownloadManager.shared.failed(stableId: stableId, message: error.localizedDescription)
            }
            return
        }

        progressBox.remove(stableId: stableId, taskId: downloadTask.taskIdentifier)
        Task { @MainActor in
            WatchDownloadManager.shared.trackLanded(stableId: stableId, trackIndex: trackIndex, fileName: fileName)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let identifier = session.configuration.identifier,
            let stableId = Self.stableId(forIdentifier: identifier),
            totalBytesExpectedToWrite > 0
        else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        guard progressBox.update(stableId: stableId, taskId: downloadTask.taskIdentifier, fraction: fraction) else { return }
        Task { @MainActor in
            let manager = WatchDownloadManager.shared
            if case .downloading = manager.active[stableId] {
                manager.active[stableId] = .downloading(manager.progress(for: stableId))
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled,
            let identifier = session.configuration.identifier,
            let stableId = Self.stableId(forIdentifier: identifier)
        else { return }
        let message = error.localizedDescription
        Task { @MainActor in
            WatchDownloadManager.shared.failed(stableId: stableId, message: message)
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            let manager = WatchDownloadManager.shared
            manager.pendingRefreshTasks.removeValue(forKey: identifier)?.setTaskCompletedWithSnapshot(false)
        }
    }
}

private nonisolated final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [String: [Int: Double]] = [:]
    private var lastPush: [String: Date] = [:]

    func update(stableId: String, taskId: Int, fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        fractions[stableId, default: [:]][taskId] = fraction
        let now = Date()
        if let last = lastPush[stableId], now.timeIntervalSince(last) < 0.3 {
            return false
        }
        lastPush[stableId] = now
        return true
    }

    func aggregateFraction(stableId: String) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let values = fractions[stableId], !values.isEmpty else { return 0 }
        return values.values.reduce(0, +)
    }

    func remove(stableId: String, taskId: Int) {
        lock.lock()
        defer { lock.unlock() }
        fractions[stableId]?.removeValue(forKey: taskId)
    }

    func clear(stableId: String) {
        lock.lock()
        defer { lock.unlock() }
        fractions[stableId] = nil
        lastPush[stableId] = nil
    }
}
