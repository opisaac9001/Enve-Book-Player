import Foundation

@MainActor
@Observable
final class MaintenanceEngine {
    private let appState: AppState
    private let recovery: LibraryRecoveryCoordinator

    private unowned let profileSession: ProfileSession?

    init(profileSession: ProfileSession? = nil,
        appState: AppState = .shared,
        recovery: LibraryRecoveryCoordinator = .shared
    ) {
        self.profileSession = profileSession
        self.appState = appState
        self.recovery = recovery
    }

    func clearImageCache() async {
        await (profileSession?.imageCache ?? DiskImageCache.shared).clearAllCache()
        await (profileSession?.appCache ?? AppCache.shared).clearCoverCache()
        await (profileSession?.localStorage ?? LocalStorageManager.shared).clearCoverOverrides()
    }

    func clearMetadata() async {
        try? await (profileSession?.metadataStorage ?? MetadataStorage.shared).clearAllMetadata()
        await (profileSession?.appCache ?? AppCache.shared).clearMetadataCache()
    }

    func performDeviceOnlyFactoryReset() async {
        guard profileSession?.isOwner ?? true else { return }
        ServerConnectionCloudKitSync.shared.isEnabled = false
        (profileSession?.sync ?? SyncCoordinator.shared).setSyncEnabled(false)

        recovery.prepareForFullDataClear()
        await appState.bookStore.clearAllData()
        BookStoreManager.shared.resetStore()
        await recovery.resetBookDataState()
        await (profileSession?.appCache ?? AppCache.shared).clearActiveCaches()
        await (profileSession?.imageCache ?? DiskImageCache.shared).clearAllCache()

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
        (profileSession?.legacyKeychain ?? KeychainHelper.shared).clearAll()
        StorageService.shared.clearAll()
    }
}
