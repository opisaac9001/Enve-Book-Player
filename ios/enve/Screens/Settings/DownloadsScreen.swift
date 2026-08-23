import SwiftUI

struct DownloadsScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    var body: some View {
        SettingsScaffold(overline: "Downloads & storage", title: "Downloads") {
            SourcesCard {
                SourcesToggleRow(
                    title: "Download over cellular",
                    subtitle: "Off uses Wi-Fi only.",
                    isOn: Binding(
                        get: { SettingsManager.shared.allowCellularBookDownloads },
                        set: { SettingsManager.shared.allowCellularBookDownloads = $0 }
                    )
                )
            }

            SourcesCard {
                if engine.downloads.tasks.isEmpty {
                    Text("Nothing downloading.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                } else {
                    ForEach(engine.downloads.activeTasks) { task in
                        SettingsDownloadRow(task: task)
                    }
                    ForEach(engine.downloads.failedTasks) { task in
                        SettingsDownloadRow(task: task)
                    }
                    ForEach(engine.downloads.completedTasks) { task in
                        SettingsDownloadRow(task: task)
                    }
                    if !engine.downloads.completedTasks.isEmpty {
                        Divider().overlay(hearth.hairline)
                        QuietButton(title: "Clear finished", systemImage: "checkmark.circle") {
                            engine.downloads.clearCompleted()
                        }
                    }
                }
            }
        }
    }
}

private struct SettingsDownloadRow: View {
    let task: BookDownloadTask

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.hearthBody.weight(.medium))
                        .foregroundStyle(hearth.text)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                Spacer()
                controls
            }
            if task.status == .downloading || task.status == .paused {
                Ribbon(progress: task.progress, tint: hearth.ember)
            }
        }
    }

    private var statusText: String {
        switch task.status {
        case .queued: return "Waiting"
        case .downloading: return task.progressText
        case .paused: return "Paused"
        case .completed: return "Downloaded"
        case .failed: return task.errorMessage ?? "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch task.status {
        case .downloading, .queued:
            GlyphButton(systemImage: "pause", glyphSize: 14, label: "Pause download") {
                engine.downloads.pause(taskId: task.id)
            }
            GlyphButton(systemImage: "xmark", glyphSize: 14, label: "Cancel download") {
                engine.downloads.cancel(taskId: task.id)
            }
        case .paused:
            GlyphButton(systemImage: "play", glyphSize: 14, label: "Resume download") {
                Task {
                    if let book = await engine.library.book(stableId: task.bookId) {
                        await engine.downloads.resume(taskId: task.id, book: book)
                    }
                }
            }
            GlyphButton(systemImage: "xmark", glyphSize: 14, label: "Cancel download") {
                engine.downloads.cancel(taskId: task.id)
            }
        case .failed:
            GlyphButton(systemImage: "arrow.clockwise", glyphSize: 14, label: "Retry download") {
                Task {
                    if let book = await engine.library.book(stableId: task.bookId) {
                        await engine.downloads.retry(taskId: task.id, book: book)
                    }
                }
            }
            GlyphButton(systemImage: "xmark", glyphSize: 14, label: "Remove from list") {
                engine.downloads.remove(taskId: task.id)
            }
        case .completed:
            GlyphButton(systemImage: "trash", glyphSize: 14, label: "Delete download") {
                Task { await engine.downloads.deleteDownload(bookId: task.bookId) }
            }
        case .cancelled:
            GlyphButton(systemImage: "xmark", glyphSize: 14, label: "Remove from list") {
                engine.downloads.remove(taskId: task.id)
            }
        }
    }
}
