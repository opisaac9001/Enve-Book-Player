import SwiftUI

struct AdminABSServerScreen: View {
    let model: AdminABSModel

    @Environment(\.hearth) private var hearth
    @Environment(\.openURL) private var openURL
    @State private var deletingBackup: ABSBackup?

    var body: some View {
        AdminSubScreen(overline: model.connection.name, title: "Server & backups") {
            SourcesCard {
                Overline("Settings")
                Text("The server keeps its own settings. Open the web interface to change scanners, schedules, and the rest.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = model.serverURL {
                    EmberButton(title: "Open the web interface", systemImage: "safari") {
                        openURL(url)
                    }
                }
            }

            SourcesCard {
                HStack {
                    Overline("Backups")
                    Spacer()
                    GlyphButton(systemImage: "plus", size: 40, glyphSize: 15, label: "Write a backup") {
                        Task { await model.createBackup() }
                    }
                }
                if model.backups.isEmpty {
                    AdminEmptyText(model.isLoading ? "Fetching the backups…" : "No backups have been written yet.")
                } else {
                    ForEach(model.backups) { backup in
                        adminBackupRow(backup)
                    }
                }
            }
        }
        .alert(
            "Delete this backup",
            isPresented: Binding(
                get: { deletingBackup != nil },
                set: { if !$0 { deletingBackup = nil } }
            )
        ) {
            Button("Delete", role: .destructive) {
                if let backup = deletingBackup, let filename = backup.filename {
                    Task { await model.deleteBackup(filename: filename) }
                }
                deletingBackup = nil
            }
            Button("Cancel", role: .cancel) { deletingBackup = nil }
        } message: {
            Text("\(deletingBackup?.filename ?? "The backup") will be gone from the server.")
        }
        .adminMessageAlert(
            error: Binding(get: { model.error }, set: { model.error = $0 }),
            success: Binding(get: { model.successMessage }, set: { model.successMessage = $0 })
        )
    }

    private func adminBackupRow(_ backup: ABSBackup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(backup.filename ?? "Backup")
                    .font(.hearthUI(14, weight: .medium))
                    .foregroundStyle(hearth.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let size = backup.size {
                        Text(AdminFormat.bytes(size))
                    }
                    if let date = backup.createdAtDate {
                        Text(date.formatted(.dateTime.day().month(.abbreviated).year()))
                    }
                }
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
            }
            Spacer()
            GlyphButton(systemImage: "trash", size: 40, glyphSize: 14, label: "Delete this backup") {
                deletingBackup = backup
            }
        }
        .frame(minHeight: 44)
    }
}
