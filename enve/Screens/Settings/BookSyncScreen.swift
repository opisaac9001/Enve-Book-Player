import SwiftUI

struct BookSyncScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth

    @State private var ebookCount = 0
    @State private var allEbooks: [Book] = []
    @State private var loaded = false
    @State private var unlinkTarget: Book?
    @State private var matchTarget: Book?

    private var linkedPairs: [(ebook: Book, audiobook: Book)] {
        allEbooks.compactMap { ebook in
            guard let audiobook = EbookAudiobookLinker.shared.linkedAudiobook(for: ebook) else { return nil }
            return (ebook, audiobook)
        }
    }

    private var unlinkedEbooks: [Book] {
        allEbooks.filter { EbookAudiobookLinker.shared.linkedAudiobook(for: $0) == nil }
    }

    var body: some View {
        SettingsScaffold(
            overline: "Library & content",
            title: "Book sync",
            subtitle: "Read and listen to the same story, picking up where the other left off."
        ) {
            if !loaded {
                SourcesCard {
                    HStack(spacing: 10) {
                        ProgressView().tint(hearth.ember)
                        Text("Gathering your ebooks…")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    }
                }
            } else {
                overviewCard
                if !linkedPairs.isEmpty { linkedCard }
                if !unlinkedEbooks.isEmpty { unlinkedCard }
                if allEbooks.isEmpty {
                    SourcesCard {
                        Text("No ebooks yet. Once you have both formats of a story, link them from the book's page or right here.")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                howItWorksCard
            }
        }
        .confirmationDialog(
            "Unlink this pair?",
            isPresented: Binding(get: { unlinkTarget != nil }, set: { if !$0 { unlinkTarget = nil } }),
            titleVisibility: .visible,
            presenting: unlinkTarget
        ) { ebook in
            Button("Unlink", role: .destructive) { unlink(ebook) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The ebook and audiobook part ways. Any read-aloud alignment between them is removed too.")
        }
        .sheet(item: $matchTarget) { ebook in
            EbookAudiobookMatchScreen(book: ebook)
                .enveEnvironment()
        }
        .task {
            for await snapshot in engine.library.bookSyncSnapshots(limit: 5000) {
                if Task.isCancelled { break }
                ebookCount = snapshot.ebookCount
                allEbooks = snapshot.ebooks
                loaded = true
            }
        }
    }

    private var overviewCard: some View {
        SourcesCard {
            Overline("Overview")
            HStack {
                Text("Ebooks")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Spacer()
                Text("\(ebookCount)")
                    .font(.hearthBody.monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
            }
            HStack {
                Text("Linked pairs")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
                Spacer()
                Text("\(linkedPairs.count)")
                    .font(.hearthBody.monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }

    private var linkedCard: some View {
        SourcesCard {
            Overline("Linked pairs")
            ForEach(linkedPairs, id: \.ebook.stableId) { pair in
                HStack(spacing: 10) {
                    CoverTile(book: pair.ebook, width: 34)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.hearthUI(10, weight: .bold))
                        .foregroundStyle(hearth.ember)
                    CoverTile(book: pair.audiobook, width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pair.ebook.title)
                            .font(.hearthBody.weight(.medium))
                            .foregroundStyle(hearth.text)
                            .lineLimit(1)
                        Text(bookSyncProgressLine(pair))
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    GlyphButton(systemImage: "xmark", size: 36, glyphSize: 12, label: "Unlink \(pair.ebook.title)") {
                        unlinkTarget = pair.ebook
                    }
                }
            }
        }
    }

    private var unlinkedCard: some View {
        SourcesCard {
            Overline("Still on their own")
            ForEach(unlinkedEbooks.prefix(10), id: \.stableId) { ebook in
                Button {
                    matchTarget = ebook
                } label: {
                    HStack(spacing: 10) {
                        CoverTile(book: ebook, width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ebook.title)
                                .font(.hearthBody.weight(.medium))
                                .foregroundStyle(hearth.text)
                                .lineLimit(1)
                            if let author = ebook.author {
                                Text(author)
                                    .font(.hearthCaption)
                                    .foregroundStyle(hearth.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text("Link")
                            .font(.hearthCaption.weight(.medium))
                            .foregroundStyle(hearth.ember)
                        Image(systemName: "chevron.right")
                            .font(.hearthUI(11, weight: .semibold))
                            .foregroundStyle(hearth.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
            if unlinkedEbooks.count > 10 {
                Text("and \(unlinkedEbooks.count - 10) more…")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
            }
        }
    }

    private var howItWorksCard: some View {
        SourcesCard {
            Overline("How it works")
            Text(
                "Link an ebook to its audiobook from the book page or from this list. Chapters align across the two, and the Listen and Read buttons jump between formats at the matching place."
            )
            .font(.hearthCaption)
            .foregroundStyle(hearth.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bookSyncProgressLine(_ pair: (ebook: Book, audiobook: Book)) -> String {
        var parts: [String] = []
        if let progress = pair.ebook.ebookProgress, progress > 0 {
            parts.append("read \(Int(progress * 100))%")
        }
        if pair.audiobook.progressPercentage > 0 {
            parts.append("heard \(Int(pair.audiobook.progressPercentage * 100))%")
        }
        return parts.isEmpty ? "Linked" : parts.joined(separator: " · ")
    }

    private func unlink(_ ebook: Book) {
        let updatedEbook = engine.library.unlinkAudiobook(from: ebook)
        allEbooks = allEbooks.map { book in
            guard book.uniqueId == ebook.uniqueId else { return book }
            return updatedEbook
        }
        unlinkTarget = nil
        PlatformHaptics.notification(.success)
    }
}
