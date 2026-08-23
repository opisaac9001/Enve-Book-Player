import Foundation

@MainActor
@Observable
final class MaintenanceEngine {
    private let appState: AppState
    private let recovery: LibraryRecoveryCoordinator
    private let downloads: UnifiedDownloadService

    init(
        appState: AppState = .shared,
        recovery: LibraryRecoveryCoordinator = .shared,
        downloads: UnifiedDownloadService = .shared
    ) {
        self.appState = appState
        self.recovery = recovery
        self.downloads = downloads
    }

    func clearImageCache() async {
        DiskImageCache.shared.clearAllCache()
        await AppCache.shared.clearCoverCache()
    }

    func clearMetadata() async {
        try? await MetadataStorage.shared.clearAllMetadata()
        await AppCache.shared.clearActiveCaches()
    }

    func clearFinishedDownloads() async {
        for task in downloads.completedTasks {
            await downloads.deleteDownload(bookId: task.bookId)
        }
        downloads.clearCompleted()
    }

    func performDeviceOnlyFactoryReset() async {
        ServerConnectionCloudKitSync.shared.isEnabled = false
        SyncCoordinator.shared.setSyncEnabled(false)

        recovery.prepareForFullDataClear()
        await appState.bookStore.clearAllData()
        BookStoreManager.shared.resetStore()
        await recovery.resetBookDataState()
        await AppCache.shared.clearActiveCaches()
        DiskImageCache.shared.clearAllCache()

        let fileManager = FileManager.default
        var roots: [URL] = []
        for directory in [FileManager.SearchPathDirectory.documentDirectory, .applicationSupportDirectory, .cachesDirectory] {
            if let base = fileManager.urls(for: directory, in: .userDomainMask).first {
                roots.append(base)
            }
        }
        roots.append(fileManager.temporaryDirectory)
        for base in roots {
            guard let children = try? fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { continue }
            for child in children {
                try? fileManager.removeItem(at: child)
            }
        }

        try? SecureTokenStorage.shared.clearAll()
        KeychainHelper.shared.clearAll()
        StorageService.shared.clearAll()
    }
}
