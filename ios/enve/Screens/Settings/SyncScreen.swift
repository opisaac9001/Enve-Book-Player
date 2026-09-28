import SwiftUI

struct SyncScreen: View {
    @Environment(\.hearth) private var hearth
    private var coordinator: SyncCoordinator { .shared }
    @State private var isManualSyncing = false

    var body: some View {
        SettingsScaffold(
            overline: "Downloads & storage",
            title: "Sync",
            subtitle: "Keep reading and listening progress in step across your Apple devices."
        ) {
            SourcesCard {
                SourcesToggleRow(
                    title: "Sync progress with iCloud",
                    subtitle: coordinator.isCloudKitAvailable ? nil : "iCloud isn't available right now.",
                    isOn: Binding(
                        get: { coordinator.syncEnabled },
                        set: { coordinator.setSyncEnabled($0) }
                    )
                )

                SourcesToggleRow(
                    title: "Sync to Apple TV",
                    subtitle: "Share your server connections with Enve on Apple TV.",
                    isOn: Binding(
                        get: { ServerConnectionCloudKitSync.shared.isEnabled },
                        set: { ServerConnectionCloudKitSync.shared.isEnabled = $0 }
                    )
                )

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        if coordinator.isSyncing || isManualSyncing {
                            Text("Syncing…")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        } else if let date = coordinator.lastSyncDate {
                            Text("Last synced \(date.formatted(.relative(presentation: .named)))")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        } else {
                            Text("Not synced yet")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                        if coordinator.pendingSyncCount > 0 {
                            Text("\(coordinator.pendingSyncCount) waiting to send")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textTertiary)
                        }
                        if let device = coordinator.lastSyncDeviceName, !device.isEmpty {
                            Text("From \(device)")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textTertiary)
                        }
                    }
                    Spacer()
                    QuietButton(title: "Sync now", systemImage: "arrow.triangle.2.circlepath") {
                        guard !isManualSyncing else { return }
                        isManualSyncing = true
                        Task {
                            await coordinator.manualSync()
                            isManualSyncing = false
                        }
                    }
                }
            }
        }
    }
}
