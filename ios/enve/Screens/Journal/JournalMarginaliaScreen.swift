import SwiftUI
import UIKit

struct JournalMarginaliaScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var entries: [JournalMarginaliaEntry] = []
    @State private var loaded = false
    @State private var cardRequest: QuoteCardRequest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 6) {
                    Overline("Notes in the margins")
                    Text("Marginalia")
                        .font(.hearthScreenTitle)
                        .foregroundStyle(hearth.text)
                }
                .padding(.horizontal, 24)

                if loaded && entries.isEmpty {
                    Text("Nothing in the margins yet.")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                        .padding(.horizontal, 24)
                }

                ForEach(entries) { entry in
                    bookSection(entry)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            entries = await engine.journal.marginaliaEntries()
            loaded = true
        }
        .sheet(item: $cardRequest) { request in
            QuoteCardSheet(quote: request.text, book: request.book, attribution: request.attribution)
                .enveEnvironment()
                .presentationDetents([.large])
        }
    }

    private func bookSection(_ entry: JournalMarginaliaEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                CoverTile(book: entry.book, width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.book.title)
                        .font(.hearthDisplay(18, weight: .semibold))
                        .foregroundStyle(hearth.text)
                        .lineLimit(2)
                    if let author = entry.book.author {
                        Text(author)
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            ForEach(entry.annotations) { annotation in
                Button {
                    cardRequest = QuoteCardRequest(text: annotation.text, book: entry.book, attribution: annotation.chapterTitle)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        JournalQuoteView(text: annotation.text, attribution: annotation.chapterTitle ?? entry.book.title)
                        if let note = annotation.note, !note.isEmpty {
                            Text(note)
                                .font(.hearthUI(14))
                                .foregroundStyle(hearth.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .contextMenu {
                    Button {
                        cardRequest = QuoteCardRequest(text: annotation.text, book: entry.book, attribution: annotation.chapterTitle)
                    } label: {
                        Label("Make a quote card", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = annotation.text
                    } label: {
                        Label("Copy text", systemImage: "doc.on.doc")
                    }
                }
            }

            Rectangle()
                .fill(hearth.hairline)
                .frame(height: 1)
        }
        .padding(.horizontal, 24)
    }
}
