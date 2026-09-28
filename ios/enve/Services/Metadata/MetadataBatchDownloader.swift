import Combine
import Foundation
import Logging

#if os(iOS)
import UIKit
#endif

final class MetadataBatchDownloader: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = MetadataBatchDownloader()

    @Published private(set) var queue: [DownloadItem] = []
    @Published private(set) var isDownloading = false

    private let persistence = DownloadPersistence.shared
    private let networkPolicyService = NetworkPolicyService.shared
    private let settingsManager = SettingsManager.shared

    private var urlSession: URLSession?
    private var delegateQueue = DispatchQueue(label: "com.narrator.MetadataBatchDownloader.delegate")
    private var stateQueue = DispatchQueue(label: "com.narrator.MetadataBatchDownloader.state", attributes: .concurrent)

    nonisolated(unsafe) private var activeBatches: [String: URLSessionDataTask] = [:]
    private var taskToItemMapping: [Int: String] = [:]
    nonisolated(unsafe) private var cancelledItems: Set<String> = []

    private var metadataCache: [String: Data] = [:]

    private override init() {
        super.init()
        restoreQueueFromDisk()
    }

    private func setupSession() {
        if urlSession == nil {
            let config = networkPolicyService.makeBackgroundSessionConfiguration(
                identifier: "com.narrator.metadata-downloads",
                allowCellular: settingsManager.allowCellularMetadataDownloads
            )
            urlSession = URLSession(
                configuration: config,
                delegate: self,
                delegateQueue: OperationQueue.main
            )
        }
    }

    func loadQueue() {
        restoreQueueFromDisk()

        setupSession()
    }

    func pauseBatch(_ id: String) {
        if let task = activeBatches[id] {
            task.suspend()
        }

        if let index = queue.firstIndex(where: { $0.id == id }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index].status = .paused
                }
            }
        }
    }

    func resumeBatch(_ id: String) {
        if let task = activeBatches[id] {
            task.resume()
        }

        if let index = queue.firstIndex(where: { $0.id == id }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index].status = .downloading
                    self.isDownloading = true
                }
            }
        }
    }

    func cancelBatch(_ id: String) {
        if let task = activeBatches.removeValue(forKey: id) {
            task.cancel()
        }

        stateQueue.async(flags: .barrier) { [weak self] in
            self?.cancelledItems.insert(id)
        }

        if let index = queue.firstIndex(where: { $0.id == id }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index].status = .cancelled
                }
            }
        }

        updateIsDownloading()
    }

    private func failBatch(_ itemId: String, withError error: Error) async {
        guard let index = queue.firstIndex(where: { $0.id == itemId }) else { return }

        var item = queue[index]
        item.status = .failed
        item.errorDescription = error.localizedDescription
        item.lastUpdated = Date()

        stateQueue.async(flags: .barrier) { [weak self] in
            self?.activeBatches.removeValue(forKey: itemId)
        }

        await updateItem(item)
        updateIsDownloading()
    }

    private func updateItem(_ item: DownloadItem) async {
        if let index = queue.firstIndex(where: { $0.id == item.id }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index] = item
                }
            }
        }

        do {
            var loadedQueue = persistence.loadMetadataDownloadQueue()
            loadedQueue.updateItem(item)
            try persistence.saveMetadataDownloadQueue(loadedQueue)
        } catch {
            AppLogger.network.error("Failed to update metadata download: \(error)")
        }

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }

        updateIsDownloading()
    }

    private func restoreQueueFromDisk() {
        let loaded = persistence.loadMetadataDownloadQueue()
        Task { @MainActor in
            self.queue = loaded.items
        }
    }

    private func updateIsDownloading() {
        let hasActive = queue.contains { $0.status == .downloading || $0.status == .pending }
        DispatchQueue.main.async {
            self.isDownloading = hasActive
            self.objectWillChange.send()
        }
    }
}

extension MetadataBatchDownloader: URLSessionDataDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let key = "\(dataTask.taskIdentifier)"
        let capturedData = data
        Task { @MainActor in
            if self.metadataCache[key] != nil {
                self.metadataCache[key]?.append(capturedData)
            } else {
                self.metadataCache[key] = capturedData
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let key = "\(task.taskIdentifier)"
        let taskId = task.taskIdentifier
        let capturedError = error

        Task { @MainActor in
            self.metadataCache.removeValue(forKey: key)

            if let error = capturedError {
                if (error as NSError).code != NSURLErrorCancelled {
                    if let itemId = self.taskToItemMapping[taskId] {
                        await self.failBatch(itemId, withError: error)
                    }
                }
            }

            self.taskToItemMapping.removeValue(forKey: taskId)
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
}
