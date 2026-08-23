import Logging
import SwiftUI
import UIKit

struct MetadataEditScreen: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var author: String
    @State private var narrator: String
    @State private var series: String
    @State private var seriesNumber: String
    @State private var details: String
    @State private var publisher: String
    @State private var genres: String

    @State private var storedMetadata: BookMetadata?
    @State private var layersLoaded = false
    @State private var isSaving = false

    init(book: Book) {
        self.book = book
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author ?? "")
        _narrator = State(initialValue: book.narrator ?? "")
        _series = State(initialValue: book.series ?? "")
        _seriesNumber = State(initialValue: book.seriesSequence ?? book.seriesNumber.map(String.init) ?? "")
        _details = State(initialValue: book.description ?? "")
        _publisher = State(initialValue: book.publisher ?? "")
        _genres = State(initialValue: book.genres?.joined(separator: ", ") ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("In your own hand")
                        Text("Edit the record")
                            .font(.hearthDisplay(24, weight: .semibold))
                            .foregroundStyle(hearth.text)
                    }
                    Spacer()
                    GlyphButton(systemImage: "xmark", size: 40, glyphSize: 14, label: "Close") {
                        dismiss()
                    }
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 12) {
                    Overline("The book")
                    matchesEditField("Title", text: $title)
                    matchesEditField("Author", text: $author)
                    matchesEditField("Narrator", text: $narrator)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Overline("Series")
                    matchesEditField("Series name", text: $series)
                    matchesEditField("Number in series", text: $seriesNumber, keyboard: .decimalPad)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Overline("About")
                    TextEditor(text: $details)
                        .font(.hearthBody)
                        .foregroundStyle(hearth.text)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                        .padding(10)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(hearth.bg)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(hearth.hairline, lineWidth: 1)
                                }
                        }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Overline("Particulars")
                    matchesEditField("Publisher", text: $publisher)
                    matchesEditField("Genres, comma separated", text: $genres)
                }

                providerMergeSection

                HStack(spacing: 12) {
                    QuietButton(title: "Cancel") { dismiss() }
                    EmberButton(title: isSaving ? "Keeping\u{2026}" : "Keep changes") {
                        save()
                    }
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(isSaving || title.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .hearthPresentationBackground()
        .presentationDragIndicator(.visible)
        .task {
            storedMetadata = await engine.matches.metadata(for: book)
            layersLoaded = true
        }
    }

    private var providerMergeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Overline("Where the record comes from")
            if !layersLoaded {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(hearth.ember)
                    Text("Reading the stored layers.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(matchesLayerRows(), id: \.name) { layer in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(layer.present ? hearth.statusOK : hearth.hairline)
                                .frame(width: 7, height: 7)
                            Text(layer.name)
                                .font(.hearthUI(14, weight: layer.present ? .medium : .regular))
                                .foregroundStyle(layer.present ? hearth.text : hearth.textTertiary)
                            Spacer()
                            Text(layer.detail)
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textTertiary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 9)
                        if layer.name != matchesLayerRows().last?.name {
                            Rectangle().fill(hearth.hairline).frame(height: 1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(dedupCardBackground(hearth))
                Text("Higher layers win. Your edits sit on top of every provider.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private struct MatchesLayerRow {
        let name: String
        let present: Bool
        let detail: String
    }

    private func matchesLayerRows() -> [MatchesLayerRow] {
        let meta = storedMetadata
        return [
            MatchesLayerRow(
                name: "Your edits",
                present: meta?.userOverrides != nil,
                detail: meta?.userOverrides?.customTitle ?? ""
            ),
            MatchesLayerRow(
                name: "Enve Search",
                present: meta?.enve != nil,
                detail: meta?.enve?.title ?? ""
            ),
            MatchesLayerRow(
                name: "Audible",
                present: meta?.audible != nil,
                detail: meta?.audible?.title ?? ""
            ),
            MatchesLayerRow(
                name: "iTunes",
                present: meta?.iTunes != nil,
                detail: meta?.iTunes?.title ?? ""
            ),
            MatchesLayerRow(
                name: "Google Books",
                present: meta?.googleBooks != nil,
                detail: meta?.googleBooks?.title ?? ""
            ),
            MatchesLayerRow(
                name: "File tags",
                present: meta.map { $0.file.title != nil } ?? false,
                detail: meta?.file.title ?? ""
            ),
            MatchesLayerRow(
                name: "Server",
                present: meta?.backend != nil,
                detail: meta?.backend?.title ?? ""
            ),
        ]
    }

    private func matchesEditField(_ placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField(placeholder, text: text)
            .font(.hearthBody)
            .foregroundStyle(hearth.text)
            .keyboardType(keyboard)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hearth.bg)
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        isSaving = true
        Task {
            do {
                try await engine.matches.saveManualMetadataEdits(
                    for: book,
                    values: MatchesManualMetadataEditValues(
                        title: trimmedTitle,
                        author: author,
                        narrator: narrator,
                        series: series,
                        seriesNumber: seriesNumber,
                        details: details,
                        publisher: publisher,
                        genres: genres
                    )
                )
                dismiss()
            } catch {
                AppLogger.general.error("Failed to save metadata overrides: \(error)")
                isSaving = false
            }
        }
    }
}
