import SwiftUI

struct SettingsView_tvOS: View {
    @Environment(AppState.self) private var appState
    @State private var isShowingAddServer = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Servers") {
                    if appState.providerConnections.connections.isEmpty {
                        Text("No servers connected yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.providerConnections.connections, id: \.id) { server in
                            connectionRow(server)
                        }
                    }

                    Button {
                        isShowingAddServer = true
                    } label: {
                        Label("Add Server", systemImage: "plus.circle.fill")
                    }
                }

                Section("Sync") {
                    LabeledContent(
                        "iCloud / Apple TV sync",
                        value: ServerConnectionCloudKitSync.shared.isEnabled ? "On" : "Off"
                    )
                    Text("Turn on \"Sync to Apple TV\" in enve on your iPhone to bring servers over automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("About") {
                    LabeledContent(
                        "Version",
                        value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
                    )
                }
            }
            .navigationTitle("Settings")
            .fullScreenCover(isPresented: $isShowingAddServer) {
                AddServerView_tvOS()
            }
        }
    }

    private func connectionRow(_ server: ServerConnection) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                Text(server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(server.type.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button(role: .destructive) {
                removeConnection(server)
            } label: {
                Label("Remove Server", systemImage: "trash")
            }
        }
    }

    private func removeConnection(_ server: ServerConnection) {
        appState.providerConnections.connections.removeAll { $0.id == server.id }
        Task {
            await ServerConnectionCloudKitSync.shared.deleteConnection(id: server.id)
        }
    }
}
