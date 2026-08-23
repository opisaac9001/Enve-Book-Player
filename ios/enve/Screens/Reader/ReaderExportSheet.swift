import Combine
import SwiftUI
import UIKit

struct ReaderExportSheet: View {
    let book: Book
    let annotations: [ReaderAnnotation]
    let bookmarks: [Bookmark]

    @Environment(\.hearth) private var hearth
    @State private var format: AnnotationExportFormat = .markdown
    @State private var sharedText: String?
    @State private var obsidianSyncing = false
    @State private var obsidianSyncedAt: Date?

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Overline("Take your notes with you")

                HStack(spacing: 8) {
                    ForEach(AnnotationExportFormat.allCases) { option in
                        HearthChip(title: option.rawValue, isSelected: format == option) {
                            PlatformHaptics.selection()
                            format = option
                        }
                    }
                }

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
                    Text(exporter.export(format: format))
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

                    EmberButton(title: "Share", systemImage: "square.and.arrow.up") {
                        sharedText = exporter.export(format: format)
                    }
                    .frame(maxWidth: .infinity)

                    obsidianSection
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 26)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .sheet(
            item: Binding(
                get: { sharedText.map(ReaderSharePayload.init) },
                set: { sharedText = $0?.text }
            )
        ) { payload in
            ReaderShareSheet(items: [payload.text])
                .presentationDetents([.medium, .large])
        }
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
}

private struct ReaderSharePayload: Identifiable {
    let text: String
    var id: String { text }
}

private struct ReaderShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
