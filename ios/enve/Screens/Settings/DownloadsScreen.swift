import Accessibility
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
                    DownloadBulkControls()
                    ForEach(engine.downloads.activeTasks) { task in
                        SettingsDownloadRow(task: task)
                    }
                    ForEach(engine.downloads.pausedTasks) { task in
                        SettingsDownloadRow(task: task)
                    }
                    ForEach(engine.downloads.failedTasks) { task in
                        SettingsDownloadRow(task: task)
                    }
                    ForEach(engine.downloads.cancelledTasks) { task in
                        SettingsDownloadRow(task: task)
                    }
                    ForEach(engine.downloads.completedTasks) { task in
                        SettingsDownloadRow(task: task)
                    }
                    if !engine.downloads.completedTasks.isEmpty || !engine.downloads.cancelledTasks.isEmpty {
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

private struct DownloadBulkControls: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    var body: some View {
        let downloads = engine.downloads
        let pausable = downloads.pausableTasks.count
        let resumable = downloads.resumableTasks.count
        let retryable = downloads.retryableTasks.count
        let missing = downloads.tasksMissingBooks.count
        let blockedReason = downloads.lastBulkOutcome?.blockedReason
        if pausable + resumable + retryable + missing > 0 || blockedReason != nil {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        buttons(pausable: pausable, resumable: resumable, retryable: retryable, missing: missing)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        buttons(pausable: pausable, resumable: resumable, retryable: retryable, missing: missing)
                    }
                }
                .disabled(downloads.bulkActionInProgress != nil)
                .opacity(downloads.bulkActionInProgress != nil ? 0.5 : 1)

                if let blockedReason {
                    Text("Downloads didn't start. \(blockedReason).")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                if missing > 0 {
                    Text(missing == 1
                        ? "1 book is no longer in your library. Remove it, or add it back and try again."
                        : "\(missing) books are no longer in your library. Remove them, or add them back and try again.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            Divider().overlay(hearth.hairline)
        }
    }

    @ViewBuilder
    private func buttons(pausable: Int, resumable: Int, retryable: Int, missing: Int) -> some View {
        if pausable > 0 {
            QuietButton(title: "Pause all (\(pausable))", systemImage: "pause") {
                let paused = engine.downloads.pauseAll()
                announce("Paused \(Self.downloadCount(paused)).")
            }
            .accessibilityLabel("Pause all, \(Self.downloadCount(pausable))")
        }
        if resumable > 0 {
            QuietButton(title: "Resume all (\(resumable))", systemImage: "play") {
                launch(.resume)
            }
            .accessibilityLabel("Resume all, \(resumable) paused")
        }
        if retryable > 0 {
            QuietButton(title: "Retry failed (\(retryable))", systemImage: "arrow.clockwise") {
                launch(.retry)
            }
            .accessibilityLabel("Retry failed, \(Self.downloadCount(retryable))")
        }
        if missing > 0 {
            QuietButton(title: "Remove missing (\(missing))", systemImage: "xmark") {
                let removed = engine.downloads.removeTasksWithMissingBooks()
                announce("Removed \(Self.downloadCount(removed)).")
            }
            .accessibilityLabel("Remove \(Self.downloadCount(missing)) whose books are no longer in your library")
        }
    }

    private func launch(_ action: DownloadBulkAction) {
        Task {
            guard let outcome = await engine.downloads.restartAll(action) else { return }
            if let reason = outcome.blockedReason {
                announce("Downloads didn't start. \(reason).")
                return
            }
            var parts: [String] = []
            if outcome.started > 0 {
                parts.append("\(action == .resume ? "Resumed" : "Retrying") \(Self.downloadCount(outcome.started)).")
            }
            if !outcome.missingTaskIds.isEmpty {
                parts.append("\(outcome.missingTaskIds.count) no longer in your library.")
            }
            announce(parts.joined(separator: " "))
        }
    }

    private func announce(_ message: String) {
        guard !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    private static func downloadCount(_ count: Int) -> String {
        count == 1 ? "1 download" : "\(count) downloads"
    }
}

private struct SettingsDownloadRow: View {
    let task: BookDownloadTask

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    private var bookMissing: Bool { engine.downloads.isBookMissing(for: task) }

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
        if bookMissing { return "This book is no longer in your library" }
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
                Task { _ = await engine.downloads.restart(task) }
            }
            GlyphButton(systemImage: "xmark", glyphSize: 14, label: "Cancel download") {
                engine.downloads.cancel(taskId: task.id)
            }
        case .failed:
            GlyphButton(systemImage: "arrow.clockwise", glyphSize: 14, label: "Retry download") {
                Task { _ = await engine.downloads.restart(task) }
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
