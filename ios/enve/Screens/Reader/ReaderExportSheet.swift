import Combine
import SwiftUI
import UIKit

struct ReaderExportSheet: View {
    let book: Book
    let annotations: [ReaderAnnotation]
    let bookmarks: [Bookmark]

    @Environment(\.hearth) private var hearth
    @Environment(\.profileSession) private var profileSession
    @State private var format: AnnotationExportFormat = .markdown
    @State private var sharedFile: AnnotationExportFile?
    @State private var exportError: String?
    @State private var obsidianSyncing = false
    @State private var obsidianSyncedAt: Date?
    @State private var showReadwiseConnect = false
    @State private var readwiseSentFromHere = false

    private var session: ProfileSession { profileSession ?? .owner }
    private var readwise: ReadwiseExportService { session.readwise }

    private var exporter: AnnotationExporter {
        AnnotationExporter(
            bookTitle: book.title,
            bookAuthor: book.author,
            annotations: annotations,
            bookmarks: bookmarks
        )
    }

    private var ebookBookmarkCount: Int {
        bookmarks.filter { $0.mediaType == .ebook }.count
    }

    private var readwiseAnnotations: [ReaderAnnotation] {
        annotations.filter {
            !$0.isRemotePlaceholder && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Overline("Take your notes with you")

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(AnnotationExportFormat.allCases) { option in
                            HearthChip(title: option.rawValue, isSelected: format == option) {
                                PlatformHaptics.selection()
                                format = option
                                exportError = nil
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .scrollClipDisabled()

                Text(readerExportSummary)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)

                if annotations.isEmpty && ebookBookmarkCount == 0 {
                    Text("Nothing written in the margins yet.")
                        .font(.hearthDisplay(16, weight: .regular))
                        .foregroundStyle(hearth.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                } else {
                    Text(exporter.preview(format: format))
                        .font(.hearthUI(12).monospaced())
                        .foregroundStyle(hearth.textSecondary)
                        .lineLimit(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background {
                            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                .fill(hearth.bgElevated)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                        .strokeBorder(hearth.hairline, lineWidth: 1)
                                }
                        }

                    if format == .pdf {
                        Text("The preview shows the text. It's shared as a paginated PDF.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    EmberButton(title: "Share", systemImage: "square.and.arrow.up") {
                        share()
                    }
                    .frame(maxWidth: .infinity)

                    if let exportError {
                        SourcesErrorText(message: exportError)
                    }

                    obsidianSection
                }

                readwiseSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .sheet(item: $sharedFile) { file in
            ReaderShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showReadwiseConnect) {
            NavigationStack {
                ReadwiseScreen()
            }
            .enveEnvironment(session: session)
        }
    }

    private func share() {
        exportError = nil
        do {
            sharedFile = try exporter.makeFile(format: format)
        } catch {
            exportError = "Couldn't create the \(format.rawValue) file: \(error.localizedDescription)"
        }
    }

    private func sendToReadwise() {
        readwiseSentFromHere = true
        let items = readwiseAnnotations
        Task { await readwise.send(book: book, annotations: items) }
    }

    private var readerExportSummary: String {
        var parts: [String] = []
        parts.append(annotations.count == 1 ? "One highlight" : "\(annotations.count) highlights")
        parts.append(ebookBookmarkCount == 1 ? "one bookmark" : "\(ebookBookmarkCount) bookmarks")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var obsidianSection: some View {
        let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        if prefs.obsidianSyncEnabled, prefs.obsidianVaultBookmarkData != nil {
            VStack(alignment: .leading, spacing: 10) {
                Overline("Obsidian")
                QuietButton(
                    title: obsidianSyncing ? "Sending…" : "Send to Obsidian",
                    systemImage: "doc.text"
                ) {
                    guard !obsidianSyncing else { return }
                    obsidianSyncing = true
                    ObsidianNotesCoordinator.shared.manualExport(book: book)
                    Task {

                        try? await Task.sleep(for: .seconds(1))
                        obsidianSyncing = false
                        obsidianSyncedAt = ObsidianNotesCoordinator.shared.lastSuccessAt
                    }
                }
                if let syncedAt = obsidianSyncedAt ?? prefs.obsidianLastSyncDates[book.stableId] {
                    Text("Last sent \(syncedAt.formatted(.relative(presentation: .named)))")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
                if let error = ObsidianNotesCoordinator.shared.lastError {
                    Text(error.localizedDescription)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.statusError)
                }
            }
            .padding(.top, 4)
        }
    }

    private var readwiseSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline("Readwise")
            Text("Send shares this book's highlights, their attached notes, the title and author, and each highlight's position with Readwise. Nothing is sent until you tap Send.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Circle()
                    .fill(readwise.isConnected ? hearth.statusOK : hearth.textTertiary)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                Text(readwise.isConnected ? "Connected" : "Not connected")
                    .font(.hearthCaption.weight(.medium))
                    .foregroundStyle(hearth.text)
            }
            .accessibilityElement(children: .combine)

            if !readwise.isConnected {
                QuietButton(title: "Connect Readwise", systemImage: "link") {
                    showReadwiseConnect = true
                }
            } else if readwise.isWorking {
                ProgressView(
                    value: Double(readwise.sentCount),
                    total: Double(max(readwise.totalCount, 1))
                )
                .tint(hearth.ember)
                Text("Sent \(readwise.sentCount) of \(readwise.totalCount)")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .monospacedDigit()
                QuietButton(title: "Cancel", systemImage: "xmark") {
                    readwise.cancel()
                }
            } else {
                QuietButton(
                    title: readwiseAnnotations.count == 1
                        ? "Send 1 highlight"
                        : "Send \(readwiseAnnotations.count) highlights",
                    systemImage: "paperplane"
                ) {
                    sendToReadwise()
                }
                .disabled(readwiseAnnotations.isEmpty)
                .opacity(readwiseAnnotations.isEmpty ? 0.5 : 1)

                if readwiseAnnotations.isEmpty {
                    Text("This book has no highlights with text to send.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }

            if readwiseSentFromHere, !readwise.isWorking {
                if let error = readwise.lastError {
                    SourcesErrorText(message: error)
                    if readwise.isConnected, !readwiseAnnotations.isEmpty {
                        QuietButton(title: "Try again", systemImage: "arrow.clockwise") {
                            sendToReadwise()
                        }
                    }
                } else if let status = readwise.statusMessage {
                    Text(status)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.statusOK)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if readwise.isConnected, let lastSentAt = readwise.lastSentAt {
                Text("Last Readwise send from this profile, any book: \(lastSentAt.formatted(.relative(presentation: .named)))")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }
}

private struct ReaderShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
