import SwiftUI

struct DetailDownloadButton: View {
    @Environment(\.profileSession) private var capturedSession
    private var profileSession: ProfileSession { capturedSession ?? .owner }
    let book: Book
    let tint: Color
    let formatName: String?

    init(book: Book, tint: Color, formatName: String? = nil) {
        self.book = book
        self.tint = tint
        self.formatName = formatName
    }

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @State private var confirmRemove = false
    @State private var confirmCellular = false
    @State private var removalError: String?

    private enum Phase {
        case downloaded
        case active(progress: Double, queued: Bool)
        case failed
        case idle
    }

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 7) {
                glyph
                Text(label)
                    .font(.hearthUI(15, weight: .medium))
            }
            .foregroundStyle(hearth.text)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background {
                HearthChromeBackground(
                    shape: .capsule,
                    fill: hearth.bgElevated,
                    stroke: hearth.hairline,
                    tint: tint
                )
            }
        }
        .buttonStyle(PressableStyle())
        .disabled(isLocalOriginal && isDownloaded)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("detail.downloadButton")
        .alert("Remove this download?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { removeDownload() }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The book stays in your library; the files leave this device.")
        }
        .alert("You're on cellular", isPresented: $confirmCellular) {
            Button("Download anyway") { startDownload(overrideCellular: true) }
            Button("Wait for Wi-Fi", role: .cancel) {}
        } message: {
            Text("Cellular downloads are off in settings.")
        }
        .alert("Couldn't remove download", isPresented: Binding(
            get: { removalError != nil },
            set: { if !$0 { removalError = nil } }
        )) {
            Button("OK", role: .cancel) { removalError = nil }
        } message: {
            Text(removalError ?? "")
        }
    }

    private var task: BookDownloadTask? {
        engine.downloads.mostRelevantTask(for: book)
    }

    private var isDownloaded: Bool {
        engine.downloads.isDownloaded(book)
    }

    private var isLocalOriginal: Bool {
        book.source == .local
    }

    private var phase: Phase {
        if isDownloaded { return .downloaded }
        if book.mediaType == .ebook, let progress = profileSession.downloads.tasks.first(where: { $0.bookId == book.downloadKey && $0.isActive })?.progress {
            return .active(progress: progress, queued: false)
        }
        if let task {
            switch task.status {
            case .downloading, .paused:
                return .active(progress: task.progress, queued: false)
            case .queued:
                return .active(progress: task.progress, queued: true)
            case .failed, .cancelled:
                return .failed
            case .completed:
                return .idle
            }
        }
        return .idle
    }

    private var label: String {
        switch phase {
        case .downloaded: formatName.map { "\($0.capitalized) available offline" } ?? "Available offline"
        case .active(let progress, let queued): queued ? "Queued" : "\(Int((progress * 100).rounded()))%"
        case .failed: "Try again"
        case .idle: formatName.map { "Download \($0)" } ?? "Download for offline"
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .downloaded:
            if isLocalOriginal { return "Available on this device" }
            return formatName.map { "\($0.capitalized) available offline. Remove download" } ?? "Available offline. Remove download"
        case .active(let progress, let queued):
            return queued ? "Queued. Cancel download" : "Downloading, \(Int((progress * 100).rounded())) percent. Cancel download"
        case .failed:
            return formatName.map { "\($0.capitalized) download failed. Try again" } ?? "Download failed. Try again"
        case .idle:
            return formatName.map { "Download \($0) for offline" } ?? "Download for offline"
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch phase {
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(hearth.statusOK)
        case .active(let progress, _):
            ZStack {
                Circle()
                    .stroke(hearth.hairline, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(progress, 0.02))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear, value: progress)
            }
            .frame(width: 15, height: 15)
        case .failed:
            Image(systemName: "arrow.clockwise")
                .font(.hearthUI(14, weight: .medium))
        case .idle:
            Image(systemName: "arrow.down.circle")
                .font(.hearthUI(14, weight: .medium))
        }
    }

    private func handleTap() {
        switch phase {
        case .downloaded:
            confirmRemove = true
        case .active:
            if let task {
                PlatformHaptics.impact(.light)
                engine.downloads.cancel(taskId: task.id)
            }
        case .failed:
            PlatformHaptics.impact(.light)
            if let task { engine.downloads.cancel(taskId: task.id) }
            Task {
                try? await Task.sleep(nanoseconds: 150_000_000)
                await engine.downloads.download(book)
            }
        case .idle:
            if engine.downloads.isCellularWithDownloadsDisabled {
                confirmCellular = true
            } else {
                startDownload()
            }
        }
    }

    private func startDownload(overrideCellular: Bool = false) {
        PlatformHaptics.impact(.light)
        Task {
            await engine.downloads.download(book, overrideCellular: overrideCellular)
        }
    }

    private func removeDownload() {
        PlatformHaptics.impact(.medium)
        Task {
            if !(await engine.downloads.removeDownload(for: book)) {
                removalError = engine.downloads.lastError ?? "The files couldn't be removed. Try again."
            }
        }
    }
}
