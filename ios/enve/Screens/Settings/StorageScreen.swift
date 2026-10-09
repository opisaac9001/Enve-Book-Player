import SwiftUI

struct StorageScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(ProfileSwitchCoordinator.self) private var profiles
    @Environment(\.hearth) private var hearth
    @Environment(\.profileSession) private var profileSession

    @State private var prefs: UserPreferences
    @State private var cacheToICloud: Bool

    @State private var coversBytes: Int64 = 0
    @State private var metadataBytes: Int64 = 0
    @State private var downloadsBytes: Int64 = 0
    @State private var otherCacheBytes: Int64 = 0
    @State private var availableBytes: Int64 = 0
    @State private var sizesLoaded = false

    @State private var isWorking = false
    @State private var pendingAction: StorageAction?
    @State private var resultMessage: String?

    init(profileSession: ProfileSession = .owner) {
        _prefs = State(initialValue: profileSession.preferences.loadPreferences())
        _cacheToICloud = State(initialValue: profileSession.preferences.loadCacheScope() == .iCloudIfAvailable)
    }

    private var session: ProfileSession { profileSession ?? .owner }
    private var totalBytes: Int64 { coversBytes + metadataBytes + downloadsBytes + otherCacheBytes }

    private enum StorageAction: String, Identifiable {
        case clearCovers, clearMetadata, clearCache

        var id: String { rawValue }

        var title: String {
            switch self {
            case .clearCovers: "Clear cover cache"
            case .clearMetadata: "Clear metadata cache"
            case .clearCache: "Clear all caches"
            }
        }

        var message: String {
            switch self {
            case .clearCovers: "Covers are fetched again as you browse."
            case .clearMetadata: "Cached metadata is fetched again from your servers."
            case .clearCache: "Everything cached is rebuilt as needed. Downloads stay."
            }
        }
    }

    var body: some View {
        SettingsScaffold(
            overline: "Downloads & storage",
            title: "Storage",
            subtitle: "What Enve keeps on this phone, and how it tidies up."
        ) {
            overviewCard
            breakdownCard

            SourcesCard {
                NavigationLink {
                    DownloadedBooksScreen()
                } label: {
                    SettingsLinkRow(title: "Downloaded books", subtitle: "See and remove individual downloads")
                }
                .buttonStyle(PressableStyle())
            }

            keepNextOfflineCard
            cleanupPoliciesCard
            downloadCleanupCard

            if let resultMessage {
                Text(resultMessage)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        .task { await loadSizes() }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action.title, role: .destructive) {
                Task { await perform(action) }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        } message: { action in
            Text(action.message)
        }
    }

    private var keepNextOfflineCard: some View {
        SourcesCard {
            Overline("Offline automation")
            SourcesToggleRow(
                title: "Keep next items offline",
                subtitle: "Download what comes next in a started series or podcast",
                isOn: Binding(
                    get: { prefs.keepNextItemsOfflineEnabled },
                    set: { value in
                        prefs = SettingsPrefs.mutate(in: session.preferences) { $0.keepNextItemsOfflineEnabled = value }
                    }
                )
            )
            if prefs.keepNextItemsOfflineEnabled {
                SettingsMenuRow(
                    title: "Items to keep",
                    value: "\(prefs.keepNextItemsOfflineCount)"
                ) {
                    ForEach(KeepNextOfflineService.allowedCounts, id: \.self) { count in
                        Button(count == 1 ? "1 item" : "\(count) items") {
                            prefs = SettingsPrefs.mutate(in: session.preferences) { $0.keepNextItemsOfflineCount = count }
                        }
                    }
                }
                Text("Only runs when the current item is downloaded. Cellular use follows your download settings.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var overviewCard: some View {
        SourcesCard {
            Overline("On this phone")
            if !sizesLoaded {
                HStack(spacing: 10) {
                    ProgressView().tint(hearth.ember)
                    Text("Measuring…")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(storageFormatBytes(totalBytes))
                        .font(.hearthDisplay(30))
                        .foregroundStyle(hearth.text)
                    Spacer()
                    Text("\(storageFormatBytes(availableBytes)) free on the device")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    private var breakdownCard: some View {
        SourcesCard {
            Overline("Where it goes")
            storageRow("Covers", bytes: coversBytes) { pendingAction = .clearCovers }
            storageRow("Cached metadata", bytes: metadataBytes) { pendingAction = .clearMetadata }
            storageRow("Downloads", bytes: downloadsBytes, clearAction: nil)
            storageRow("Other caches", bytes: otherCacheBytes) { pendingAction = .clearCache }
            if isWorking {
                HStack(spacing: 10) {
                    ProgressView().tint(hearth.ember)
                    Text("Tidying…")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
        }
    }

    private func storageRow(_ title: String, bytes: Int64, clearAction: (() -> Void)?) -> some View {
        HStack {
            Text(title)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
            Spacer()
            Text(storageFormatBytes(bytes))
                .font(.hearthCaption.monospacedDigit())
                .foregroundStyle(hearth.textSecondary)
            if let clearAction {
                Button("Clear", action: clearAction)
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.ember)
                    .disabled(isWorking)
            }
        }
    }

    private var cleanupPoliciesCard: some View {
        SourcesCard {
            Overline("Cache policies")
            SourcesToggleRow(
                title: "Tidy caches automatically",
                isOn: Binding(
                    get: { prefs.autoClearCacheEnabled },
                    set: { value in prefs = SettingsPrefs.mutate(in: session.preferences) { $0.autoClearCacheEnabled = value } }
                )
            )
            SourcesToggleRow(
                title: "Expire old metadata",
                isOn: Binding(
                    get: { prefs.expireOldMetadataEnabled },
                    set: { value in prefs = SettingsPrefs.mutate(in: session.preferences) { $0.expireOldMetadataEnabled = value } }
                )
            )
            SourcesToggleRow(
                title: "Compress covers",
                subtitle: "Store covers as JPEG to save space",
                isOn: Binding(
                    get: { prefs.compressCoversEnabled },
                    set: { value in prefs = SettingsPrefs.mutate(in: session.preferences) { $0.compressCoversEnabled = value } }
                )
            )
            if session.isOwner {
                SourcesToggleRow(
                    title: "Keep the cover cache in iCloud",
                    subtitle: "Uses iCloud Drive when it's available",
                    isOn: Binding(
                        get: { cacheToICloud },
                        set: { setCacheScope($0) }
                    )
                )
            }
        }
    }

    private var downloadCleanupCard: some View {
        SourcesCard {
            Overline("Download cleanup")
            SourcesToggleRow(
                title: "Remove after finishing",
                subtitle: "Delete a download once the book is done",
                isOn: Binding(
                    get: { prefs.autoDeleteFinishedBooks },
                    set: { value in prefs = SettingsPrefs.mutate(in: session.preferences) { $0.autoDeleteFinishedBooks = value } }
                )
            )
            SourcesToggleRow(
                title: "Clear failed downloads",
                subtitle: "Remove failures automatically after a week",
                isOn: Binding(
                    get: { prefs.autoDeleteFailedDownloads },
                    set: { value in prefs = SettingsPrefs.mutate(in: session.preferences) { $0.autoDeleteFailedDownloads = value } }
                )
            )
            SourcesToggleRow(
                title: "Storage limit",
                subtitle: "Remove the oldest downloads past the limit",
                isOn: Binding(
                    get: { prefs.storageLimitEnabled },
                    set: { value in
                        prefs = SettingsPrefs.mutate(in: session.preferences) { $0.storageLimitEnabled = value }
                        if value {
                            Task { await engine.downloads.checkStorageLimit() }
                        }
                    }
                )
            )
            if prefs.storageLimitEnabled {
                HStack(spacing: 12) {
                    Text("\(prefs.storageLimitGB) GB")
                        .font(.hearthCaption.monospacedDigit())
                        .foregroundStyle(hearth.textSecondary)
                        .frame(width: 52, alignment: .leading)
                    Slider(
                        value: Binding(
                            get: { Double(prefs.storageLimitGB) },
                            set: { value in prefs = SettingsPrefs.mutate(in: session.preferences) { $0.storageLimitGB = Int(value) } }
                        ),
                        in: 1...50,
                        step: 1
                    )
                    .tint(hearth.ember)
                }
            }
        }
    }

    private func setCacheScope(_ toICloud: Bool) {
        guard (try? profiles.authorizeChanges(in: session)) != nil, session.isOwner else { return }
        cacheToICloud = toICloud
        let scope: CacheScope = toICloud ? .iCloudIfAvailable : .local
        session.preferences.saveCacheScope(scope)
        Task { await session.appCache.setPreferredScope(scope) }
    }

    private var legacyCoversDirectory: URL {
        session.storage.documentsDirectory.appendingPathComponent("Covers")
    }

    // The owner's caches root also holds every other profile's caches under Profiles/.
    private var otherProfilesCachesDirectory: URL? {
        session.isOwner ? session.storage.cachesDirectory.appendingPathComponent("Profiles", isDirectory: true) : nil
    }

    private func loadSizes() async {
        async let appCacheSizesRequest = session.appCache.activeCacheSizes()
        async let diskCoverBytesRequest = session.imageCache.diskBytes()
        async let coverOverrideBytesRequest = session.localStorage.coverOverridesDiskBytes()
        async let legacyCoverBytesRequest = SourcesCacheMetrics.size(at: legacyCoversDirectory)
        async let downloadsBytesRequest = engine.downloads.downloadedStorageBytes()
        async let cachesDirectoryBytesRequest = SourcesCacheMetrics.size(at: session.storage.cachesDirectory)
        var otherProfilesBytes: Int64 = 0
        if let otherProfilesCachesDirectory {
            otherProfilesBytes = await SourcesCacheMetrics.size(at: otherProfilesCachesDirectory)
        }

        var downloadedCacheBytes: Int64 = 0
        for name in ["ReaderEbooks", "StreamedEpubs"] {
            downloadedCacheBytes += await SourcesCacheMetrics.size(at: session.storage.cachesDirectory.appendingPathComponent(name))
        }
        let appCacheSizes = await appCacheSizesRequest
        let diskCoverBytes = await diskCoverBytesRequest
        coversBytes = appCacheSizes.coversBytes + diskCoverBytes + (await coverOverrideBytesRequest) + (await legacyCoverBytesRequest)
        metadataBytes = appCacheSizes.metadataBytes
        downloadsBytes = await downloadsBytesRequest
        otherCacheBytes = max((await cachesDirectoryBytesRequest) - otherProfilesBytes - diskCoverBytes - downloadedCacheBytes, 0)
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
            let free = attrs[.systemFreeSize] as? NSNumber
        {
            availableBytes = free.int64Value
        }
        sizesLoaded = true
    }

    private func perform(_ action: StorageAction) async {
        guard (try? profiles.authorizeChanges(in: session)) != nil else { return }
        isWorking = true
        defer { isWorking = false }
        pendingAction = nil
        switch action {
        case .clearCovers:
            await session.imageCache.clearAllCache()
            guard (try? profiles.authorizeChanges(in: session)) != nil else { return }
            await session.appCache.clearCoverCache()
            guard (try? profiles.authorizeChanges(in: session)) != nil else { return }
            await session.localStorage.clearCoverOverrides()
            guard (try? profiles.authorizeChanges(in: session)) != nil else { return }
            try? FileManager.default.removeItem(at: legacyCoversDirectory)
            resultMessage = "Cover cache cleared."
        case .clearMetadata:
            await session.appCache.clearMetadataCache()
            resultMessage = "Metadata cache cleared."
        case .clearCache:
            await session.imageCache.clearAllCache()
            guard (try? profiles.authorizeChanges(in: session)) != nil else { return }
            await session.appCache.clearActiveCaches()
            guard (try? profiles.authorizeChanges(in: session)) != nil else { return }
            await session.localStorage.clearCoverOverrides()
            guard (try? profiles.authorizeChanges(in: session)) != nil else { return }
            let preservedDirectories: Set<String> = ["Profiles", "ReaderEbooks", "StreamedEpubs", "ConvertedEbooks"]
            if let contents = try? FileManager.default.contentsOfDirectory(at: session.storage.cachesDirectory, includingPropertiesForKeys: nil) {
                for item in contents where !preservedDirectories.contains(item.lastPathComponent) {
                    try? FileManager.default.removeItem(at: item)
                }
            }
            resultMessage = "Caches cleared."
        }
        await loadSizes()
        PlatformHaptics.notification(.success)
    }
}

enum SourcesCacheMetrics {
    static func size(at url: URL) async -> Int64 {
        let path = url
        return await Task.detached(priority: .utility) {
            guard let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.fileSizeKey]) else {
                return Int64(0)
            }
            var total: Int64 = 0
            while let fileURL = enumerator.nextObject() as? URL {
                if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    total += Int64(size)
                }
            }
            return total
        }.value
    }
}

private func storageFormatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

struct DownloadedBooksScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var items: [SourcesDownloadedItem] = []
    @State private var loaded = false
    @State private var pendingDelete: SourcesDownloadedItem?

    var body: some View {
        SettingsScaffold(
            overline: "Downloads & storage",
            title: "Downloaded books"
        ) {
            if !loaded {
                SourcesCard {
                    HStack(spacing: 10) {
                        ProgressView().tint(hearth.ember)
                        Text("Looking through the shelf…")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            } else if items.isEmpty {
                SourcesCard {
                    Text("Nothing downloaded. Books you keep on the phone will appear here.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                SourcesCard {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.hearthBody.weight(.medium))
                                    .foregroundStyle(hearth.text)
                                    .lineLimit(1)
                                Text(item.subtitle ?? item.id)
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(item.sizeText)
                                .font(.hearthCaption.monospacedDigit())
                                .foregroundStyle(hearth.textSecondary)
                            GlyphButton(systemImage: "trash", size: 36, glyphSize: 13, label: "Delete \(item.title)") {
                                pendingDelete = item
                            }
                        }
                    }
                }
            }
        }
        .task { await reload() }
        .confirmationDialog(
            "Delete this download",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("Delete", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { item in
            Text("\(item.title) (\(item.sizeText)) will be removed from this phone.")
        }
    }

    private func delete(_ item: SourcesDownloadedItem) {
        items.removeAll { $0.id == item.id }
        Task {
            await engine.downloads.deleteStorageItem(item.storageItem)
            await reload()
        }
    }

    private func reload() async {
        items = await engine.downloads.downloadedStorageItems().map {
            SourcesDownloadedItem(storageItem: $0)
        }
        loaded = true
    }
}

private struct SourcesDownloadedItem: Identifiable {
    let storageItem: DownloadedStorageItem

    var id: String { storageItem.id }
    var title: String { storageItem.title }
    var subtitle: String? { storageItem.subtitle }
    var sizeBytes: Int64 { storageItem.sizeBytes }

    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }
}
