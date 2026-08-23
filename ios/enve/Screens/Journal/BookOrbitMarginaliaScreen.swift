import SwiftUI
import UIKit

struct BookOrbitMarginaliaScreen: View {
    let connectionId: UUID?

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var model = BookOrbitMarginaliaModel()
    @State private var exportFile: BookOrbitExportFile?
    @State private var exporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if model.state != .unavailable {
                    searchField
                    scopeChips
                }

                switch model.state {
                case .loading:
                    JournalLoadingNote(text: "Gathering the margins…")
                case .unavailable:
                    BookOrbitUnavailableCard(
                        line: "This BookOrbit server doesn't publish an account-wide highlight hub. Update the server to see it here."
                    )
                case .failed(let message):
                    BookOrbitErrorCard(message: message) {
                        Task { await model.reload() }
                    }
                case .ready:
                    if !model.facets.isEmpty {
                        bookChips
                    }
                    summaryLine
                    if model.items.isEmpty {
                        JournalQuietNote(text: model.trashed ? "The trash is empty." : "Nothing in the margins yet.")
                    } else {
                        entries
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(HearthBackground())
        .hearthBackBar()
        .toolbarBackground(.hidden, for: .navigationBar)
        .refreshable { await model.reload() }
        .task(id: model.search) {
            model.bind(connectionId: connectionId)
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.reload()
        }
        .sheet(item: $exportFile) { file in
            BookOrbitShareSheet(items: [file.url])
        }
        .alert(
            "BookOrbit highlights",
            isPresented: Binding(
                get: { model.actionMessage != nil },
                set: { if !$0 { model.actionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionMessage ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            JournalScreenHeader(overline: "Kept by your server", title: "Highlights")
            Spacer()
            exportMenu
        }
    }

    private var exportMenu: some View {
        Menu {
            ForEach(["md", "csv", "json"], id: \.self) { format in
                Button(format.uppercased()) { export(format: format) }
            }
        } label: {
            Image(systemName: exporting ? "ellipsis" : "square.and.arrow.up")
                .font(.hearthUI(16, weight: .medium))
                .foregroundStyle(hearth.text)
                .frame(width: 44, height: 44)
                .background {
                    Circle()
                        .fill(hearth.bgElevated)
                        .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                }
        }
        .disabled(exporting || model.state != .ready)
        .accessibilityLabel("Export highlights")
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(14))
                .foregroundStyle(hearth.textTertiary)
            TextField("Search highlights and notes", text: $model.search)
                .font(.hearthUI(15))
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
            if !model.search.isEmpty {
                Button {
                    model.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hearthUI(14))
                        .foregroundStyle(hearth.textTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: Hearth.radiusInner, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                )
        }
    }

    private var scopeChips: some View {
        HStack(spacing: 8) {
            HearthChip(title: "Kept", isSelected: !model.trashed) { model.select(trashed: false) }
            HearthChip(title: "Trash", isSelected: model.trashed) { model.select(trashed: true) }
        }
    }

    private var bookChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                HearthChip(title: "All books", isSelected: model.bookId == nil) { model.select(bookId: nil) }
                ForEach(model.facets) { facet in
                    HearthChip(
                        title: "\(facet.bookTitle ?? "Untitled") (\(facet.count))",
                        isSelected: facet.bookId == model.bookId
                    ) {
                        model.select(bookId: facet.bookId)
                    }
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private var summaryLine: some View {
        Text(summaryText)
            .font(.hearthCaption)
            .foregroundStyle(hearth.textTertiary)
    }

    private var summaryText: String {
        var parts = ["\(model.total) \(model.total == 1 ? "highlight" : "highlights")"]
        if model.bookCount > 0 { parts.append("\(model.bookCount) \(model.bookCount == 1 ? "book" : "books")") }
        if model.withNotes > 0 { parts.append("\(model.withNotes) with notes") }
        return parts.joined(separator: " · ")
    }

    private var entries: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(model.items) { item in
                entry(item)
                    .onAppear {
                        guard item.id == model.items.last?.id else { return }
                        Task { await model.loadMore() }
                    }
                if item.id != model.items.last?.id {
                    Rectangle()
                        .fill(hearth.hairline)
                        .frame(height: 1)
                }
            }
            if model.isLoadingMore {
                JournalLoadingNote(text: "Turning the page…")
            }
        }
    }

    private func entry(_ item: BookOrbitProvider.AnnotationHubItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            JournalQuoteView(text: item.text, attribution: item.chapterTitle ?? item.bookTitle ?? "BookOrbit")
            if let note = item.note, !note.isEmpty {
                Text(note)
                    .font(.hearthUI(14))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(BookOrbitMarginaliaFormat.caption(item))
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let book = model.books[item.bookId] {
                    NavigationLink {
                        BookDetailScreen(book: book)
                    } label: {
                        Text("Open book")
                            .font(.hearthUI(13, weight: .medium))
                            .foregroundStyle(hearth.ember)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = item.text
            } label: {
                Label("Copy text", systemImage: "doc.on.doc")
            }
            if model.trashed {
                Button {
                    Task { await model.restore(item) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    Task { await model.purge(item) }
                } label: {
                    Label("Delete forever", systemImage: "trash")
                }
            } else {
                Button(role: .destructive) {
                    Task { await model.trash(item) }
                } label: {
                    Label("Move to trash", systemImage: "trash")
                }
            }
        }
    }

    private func export(format: String) {
        guard !exporting else { return }
        exporting = true
        Task {
            if let url = await model.export(format: format) {
                exportFile = BookOrbitExportFile(url: url)
            }
            exporting = false
        }
    }
}

struct BookOrbitExportFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

enum BookOrbitMarginaliaFormat {
    static func caption(_ item: BookOrbitProvider.AnnotationHubItem) -> String {
        var parts: [String] = []
        if let title = item.bookTitle, !title.isEmpty { parts.append(title) }
        if let author = item.author, !author.isEmpty { parts.append(author) }
        parts.append(origin(item.origin))
        parts.append(item.createdAt.formatted(.dateTime.month(.abbreviated).day().year()))
        return parts.joined(separator: " · ")
    }

    static func origin(_ raw: String) -> String {
        switch raw {
        case "web": "BookOrbit"
        case "koreader": "KOReader"
        case "kobo": "Kobo"
        default: raw.capitalized
        }
    }
}

private struct BookOrbitShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
