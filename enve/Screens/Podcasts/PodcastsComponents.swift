import SwiftUI

struct PodcastsArt: View {
    let url: URL?
    var size: CGFloat
    var corner: CGFloat = Hearth.radiusCover
    var book: Book? = nil

    @Environment(\.hearth) private var hearth

    var body: some View {
        Group {
            if url != nil || book != nil {
                CachedAsyncCoverImage(
                    url: url,
                    fallbackColor: "Blue",
                    headers: book.map { CachedAsyncCoverImage.authHeaders(for: $0) } ?? [:],
                    book: book
                )
                .aspectRatio(1, contentMode: .fill)
            } else {
                Rectangle()
                    .fill(hearth.emberSoft)
                    .overlay {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.hearthUI(size * 0.3, weight: .medium))
                            .foregroundStyle(hearth.ember.opacity(0.7))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(hearth.hairline, lineWidth: 1)
        }
    }
}

struct PodcastsDownloadControl: View {
    let episode: Book
    var size: CGFloat = 44

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @State private var confirmDelete = false
    @State private var confirmCellular = false

    private var task: BookDownloadTask? {
        engine.downloads.tasks
            .filter { $0.bookId == episode.downloadKey }
            .sorted { lhs, rhs in
                let lhsActive = (lhs.status == .downloading || lhs.status == .queued || lhs.status == .paused) ? 0 : 1
                let rhsActive = (rhs.status == .downloading || rhs.status == .queued || rhs.status == .paused) ? 0 : 1
                if lhsActive != rhsActive { return lhsActive < rhsActive }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    private var isDownloaded: Bool {
        engine.downloads.isAudiobookDownloaded(downloadKey: episode.downloadKey)
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            glyph
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityText)
        .confirmationDialog("Remove this download?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove download", role: .destructive) {
                Task { await engine.downloads.deleteDownload(bookId: episode.downloadKey) }
            }
        } message: {
            Text("The episode leaves this device. The feed keeps it.")
        }
        .alert("On cellular", isPresented: $confirmCellular) {
            Button("Download anyway") { start(overrideCellular: true) }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("Cellular downloads are off in settings.")
        }
    }

    @ViewBuilder
    private var glyph: some View {
        if isDownloaded {
            Image(systemName: "checkmark.circle.fill")
                .font(.hearthUI(20))
                .foregroundStyle(hearth.statusOK)
        } else if let task {
            switch task.status {
            case .downloading, .queued:
                ZStack {
                    Circle()
                        .stroke(hearth.hairline, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(task.progress, 0.02))
                        .stroke(hearth.ember, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill")
                        .font(.hearthUI(8))
                        .foregroundStyle(hearth.ember)
                }
                .frame(width: 22, height: 22)
            case .paused:
                Image(systemName: "pause.circle")
                    .font(.hearthUI(20))
                    .foregroundStyle(hearth.statusWarn)
            case .failed, .cancelled:
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.hearthUI(20))
                    .foregroundStyle(hearth.statusError)
            default:
                idleGlyph
            }
        } else {
            idleGlyph
        }
    }

    private var idleGlyph: some View {
        Image(systemName: "arrow.down.circle")
            .font(.hearthUI(20))
            .foregroundStyle(hearth.textSecondary)
    }

    private var accessibilityText: String {
        if isDownloaded { return "Remove download" }
        guard let task else { return "Download episode" }
        switch task.status {
        case .downloading, .queued: return "Stop download"
        case .failed, .cancelled: return "Retry download"
        default: return "Download episode"
        }
    }

    private func handleTap() {
        if isDownloaded {
            confirmDelete = true
        } else if let task {
            switch task.status {
            case .failed, .cancelled:
                engine.downloads.cancel(taskId: task.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    start()
                }
            case .downloading, .queued:
                engine.downloads.cancel(taskId: task.id)
            default:
                start()
            }
        } else {
            start()
        }
    }

    private func start(overrideCellular: Bool = false) {
        if !overrideCellular, engine.downloads.isCellularWithDownloadsDisabled {
            confirmCellular = true
            return
        }
        Task { await engine.downloads.download(episode, overrideCellular: overrideCellular) }
    }
}

enum PodcastsFormat {
    static func cleanHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func displayAuthor(_ value: String?, fallback: String? = nil) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return fallback
        }
        if value.hasSuffix(")"), let open = value.lastIndex(of: "(") {
            let name = value[value.index(after: open)..<value.index(before: value.endIndex)]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        if value.contains("@") {
            return fallback
        }
        return value
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
