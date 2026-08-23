import SwiftUI

struct DetailDownloadButton: View {
    let book: Book
    let tint: Color

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @State private var confirmRemove = false
    @State private var confirmCellular = false

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
        .accessibilityLabel(accessibilityText)
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
    }

    private var task: BookDownloadTask? {
        engine.downloads.mostRelevantTask(for: book)
    }

    private var isDownloaded: Bool {
        engine.downloads.isDownloaded(book)
    }

    private var phase: Phase {
        if isDownloaded { return .downloaded }
        if book.mediaType == .ebook, let progress = EbookDownloadProgressStore.shared.progress(for: book.downloadKey) {
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
        case .downloaded: "Downloaded"
        case .active(let progress, let queued): queued ? "Queued" : "\(Int((progress * 100).rounded()))%"
        case .failed: "Try again"
        case .idle: "Download"
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .downloaded: "Downloaded. Remove download"
        case .active(let progress, let queued):
            queued ? "Queued. Cancel download" : "Downloading, \(Int((progress * 100).rounded())) percent. Cancel download"
        case .failed: "Download failed. Try again"
        case .idle: "Download"
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch phase {
        case .downloaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.hearthUI(14, weight: .medium))
                .foregroundStyle(tint)
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
            await engine.downloads.removeDownload(for: book)
        }
    }
}
