import SwiftUI

struct SourcesSMBBrowser: View {
    let config: SMBServerConfiguration
    let password: String

    let onFolderSelected: (String) -> Void

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var model = SourcesSMBBrowserModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if let error = model.errorMessage {
                        SourcesErrorText(message: error)
                        QuietButton(title: "Try again", systemImage: "arrow.clockwise") { model.refresh() }
                    } else if model.isLoading && model.entries.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView().tint(hearth.ember)
                            Text("Asking the server…")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                        }
                    } else if model.entries.isEmpty {
                        Text("This folder is empty.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                    } else {
                        SourcesCard {
                            ForEach(model.entries, id: \.path) { entry in
                                entryRow(entry)
                            }
                        }
                    }

                    if let status = model.downloadStatus {
                        Text(status)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }

                    EmberButton(title: "Use this folder as the library", systemImage: "folder.badge.plus", tint: nil) {
                        onFolderSelected(model.currentPath)
                        model.disconnect()
                        dismiss()
                    }
                    Text("Current folder: \(model.currentPath)")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(24)
            }
            .scrollIndicators(.hidden)
            .background(HearthBackground())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.disconnect()
                        dismiss()
                    }
                    .foregroundStyle(hearth.textSecondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 4) {
                        GlyphButton(systemImage: "chevron.up", size: 36, glyphSize: 13, label: "Up one folder") {
                            model.goUp()
                        }
                        GlyphButton(systemImage: "arrow.clockwise", size: 36, glyphSize: 13, label: "Refresh") {
                            model.refresh()
                        }
                    }
                }
            }
        }
        .onAppear {
            model.connect(config: config, password: password)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Overline("Browsing")
            Text(browserTitle)
                .font(.hearthDisplay(24))
                .foregroundStyle(hearth.text)
                .lineLimit(1)
            Text(model.connectedDisplay)
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var browserTitle: String {
        let last = (model.currentPath as NSString).lastPathComponent
        return last.isEmpty ? config.shareName : last
    }

    private func entryRow(_ entry: SMBService.FileEntry) -> some View {
        Button {
            if entry.isDirectory { model.goInto(entry) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory ? "folder" : "doc")
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.ember)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    if !entry.isDirectory {
                        Text(smbByteCount(entry.size))
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                    }
                }
                Spacer()
                if entry.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.hearthUI(11, weight: .semibold))
                        .foregroundStyle(hearth.textTertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            if !entry.isDirectory {
                Button {
                    model.download(entry: entry, downloads: engine.downloads)
                } label: {
                    Label("Download to library", systemImage: "arrow.down.to.line")
                }
            }
        }
    }
}

private func smbByteCount(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

@Observable
final class SourcesSMBBrowserModel {
    var isLoading = false
    var errorMessage: String?
    var entries: [SMBService.FileEntry] = []
    var currentPath = "/"
    var connectedDisplay = ""
    var downloadStatus: String?

    @ObservationIgnored private let service = SMBService()
    @ObservationIgnored private var config: SMBServerConfiguration?
    @ObservationIgnored private var password = ""

    func connect(config: SMBServerConfiguration, password: String) {
        guard self.config == nil else { return }
        self.config = config
        self.password = password
        connectedDisplay = "\(config.username)@\(config.hostname):\(config.port)/\(config.shareName)"
        Task {
            isLoading = true
            errorMessage = nil
            do {
                try await service.connect(config: config, password: password)
                await load(path: config.rootPath)
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    func refresh() {
        errorMessage = nil
        Task { await load(path: currentPath) }
    }

    func goInto(_ entry: SMBService.FileEntry) {
        guard entry.isDirectory else { return }
        Task { await load(path: entry.path) }
    }

    func goUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        Task { await load(path: parent.isEmpty ? "/" : parent) }
    }

    func download(entry: SMBService.FileEntry, downloads: DownloadsEngine) {
        guard !entry.isDirectory else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(entry.name)
                try? FileManager.default.removeItem(at: temp)
                try await service.downloadFile(from: entry.path, to: temp) { [weak self] written, total in
                    Task { @MainActor in
                        if total > 0 {
                            self?.downloadStatus = "Downloading… \(Int(Double(written) / Double(total) * 100))%"
                        } else {
                            self?.downloadStatus = "Downloading…"
                        }
                    }
                }
                let bookId = "smb:\(entry.path.hashValue)"
                await downloads.downloadFileCopy(bookId: bookId, title: entry.name, sourceURL: temp)
                downloadStatus = "Saved to the library."
            } catch {
                downloadStatus = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            try? await Task.sleep(for: .seconds(2))
            downloadStatus = nil
        }
    }

    func disconnect() {
        Task { await service.disconnect() }
    }

    private func load(path: String) async {
        isLoading = true
        do {
            let items = try await service.listDirectory(at: path)
            entries = items.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            currentPath = path
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }
}
