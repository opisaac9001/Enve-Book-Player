import SwiftUI
import UniformTypeIdentifiers

struct DataManagementScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var pending: DataAction?
    @State private var status: String?
    @State private var isWorking = false
    @State private var isResetting = false
    @State private var settingsExportURL: URL?
    @State private var isImportingSettings = false

    private func settingsBackupLabel(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(hearth.ember)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Text(subtitle)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        SettingsScaffold(
            overline: "Downloads & storage",
            title: "Data management",
            subtitle: "Free up space or start over. Cleared caches and metadata are rebuilt automatically on the next sync."
        ) {
            if let status {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(hearth.statusOK)
                    Text(status)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }

            SourcesCard {
                actionRow(.clearCache)
                Divider().overlay(hearth.hairline)
                actionRow(.clearMetadata)
                Divider().overlay(hearth.hairline)
                actionRow(.clearDownloads)
            }

            SourcesCard {
                Overline("Settings backup")
                if let settingsExportURL {
                    ShareLink(item: settingsExportURL) {
                        settingsBackupLabel(
                            title: "Export settings",
                            subtitle: "Save speeds, skips, sleep and display preferences to a file",
                            systemImage: "square.and.arrow.up"
                        )
                    }
                }
                Divider().overlay(hearth.hairline)
                Button {
                    isImportingSettings = true
                } label: {
                    settingsBackupLabel(
                        title: "Import settings",
                        subtitle: "Restore preferences from an exported file",
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.plain)
            }

            SourcesCard {
                actionRow(.resetApp)
            }
        }
        .task {
            settingsExportURL = try? SettingsBackupService.shared.exportBackup()
        }
        .fileImporter(
            isPresented: $isImportingSettings,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    try SettingsBackupService.shared.importBackup(from: url)
                    status = "Settings restored."
                    settingsExportURL = try? SettingsBackupService.shared.exportBackup()
                } catch {
                    status = error.localizedDescription
                }
            case .failure:
                break
            }
        }
        .disabled(isResetting)
        .overlay {
            if isResetting {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(hearth.ember)
                        Text("Resetting Enve…")
                            .font(.hearthBody)
                            .foregroundStyle(.white)
                    }
                }
            }
        }
        .alert(
            pending?.title ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            Button(action.confirmLabel, role: action.isDestructive ? .destructive : nil) {
                perform(action)
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    private func actionRow(_ action: DataAction) -> some View {
        Button {
            pending = action
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action.icon)
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(action.isDestructive ? hearth.statusError : hearth.ember)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill((action.isDestructive ? hearth.statusError : hearth.ember).opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.rowTitle)
                        .font(.hearthBody)
                        .foregroundStyle(action.isDestructive ? hearth.statusError : hearth.text)
                    Text(action.rowSubtitle)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isWorking && pending == nil {
                    ProgressView().tint(hearth.ember)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(isWorking)
    }

    private func perform(_ action: DataAction) {
        switch action {
        case .clearCache:
            isWorking = true
            Task {
                await engine.maintenance.clearImageCache()
                await MainActor.run { finish("Image cache cleared.") }
            }
        case .clearMetadata:
            isWorking = true
            Task {
                await engine.maintenance.clearMetadata()
                await engine.sources.refreshVisibleLibraryScope(.all)
                await MainActor.run { finish("Metadata cleared and rebuilt from your sources.") }
            }
        case .clearDownloads:
            isWorking = true
            Task {
                let result = await engine.downloads.clearAllDownloads()
                let message =
                    result.remaining == 0
                    ? "Removed \(result.removed) downloaded \(result.removed == 1 ? "book" : "books")."
                    : "Removed \(result.removed) downloads. \(result.remaining) could not be removed."
                await MainActor.run { finish(message) }
            }
        case .resetApp:
            isResetting = true
            Task {
                await performFullReset()
                try? await Task.sleep(for: .milliseconds(400))
                exit(0)
            }
        }
    }

    private func finish(_ message: String) {
        isWorking = false
        status = message
        PlatformHaptics.notification(.success)
    }

    @MainActor
    private func performFullReset() async {
        await engine.maintenance.performDeviceOnlyFactoryReset()
    }
}

private enum DataAction: Identifiable {
    case clearCache, clearMetadata, clearDownloads, resetApp

    var id: Int {
        switch self {
        case .clearCache: return 0
        case .clearMetadata: return 1
        case .clearDownloads: return 2
        case .resetApp: return 3
        }
    }

    var isDestructive: Bool { self == .resetApp }

    var icon: String {
        switch self {
        case .clearCache: return "photo.stack"
        case .clearMetadata: return "wand.and.stars"
        case .clearDownloads: return "arrow.down.circle"
        case .resetApp: return "exclamationmark.triangle.fill"
        }
    }

    var rowTitle: String {
        switch self {
        case .clearCache: return "Clear image cache"
        case .clearMetadata: return "Clear metadata"
        case .clearDownloads: return "Clear downloads"
        case .resetApp: return "Reset Enve"
        }
    }

    var rowSubtitle: String {
        switch self {
        case .clearCache: return "Cached covers and artwork. Re-fetched as you browse."
        case .clearMetadata: return "Downloaded metadata and your edits. Re-fetched on the next sync."
        case .clearDownloads: return "Delete all downloaded books from this device."
        case .resetApp: return "Erase sources, library, progress, and settings, then close the app."
        }
    }

    var title: String {
        switch self {
        case .clearCache: return "Clear image cache?"
        case .clearMetadata: return "Clear metadata?"
        case .clearDownloads: return "Clear downloads?"
        case .resetApp: return "Reset Enve?"
        }
    }

    var message: String {
        switch self {
        case .clearCache: return "Covers and artwork will be removed and re-downloaded as you browse."
        case .clearMetadata:
            return "Cached metadata and any metadata you've edited will be removed, then re-fetched from your servers on the next sync."
        case .clearDownloads: return "All downloaded books will be deleted from this device. You can download them again later."
        case .resetApp:
            return
                "This erases all sources, your whole library, reading progress, and every setting. After clearing, the app will close. Reopen it to start fresh. This can't be undone."
        }
    }

    var confirmLabel: String {
        switch self {
        case .clearCache, .clearMetadata, .clearDownloads: return "Clear"
        case .resetApp: return "Erase & Close"
        }
    }
}
