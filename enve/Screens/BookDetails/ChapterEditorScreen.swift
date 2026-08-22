import SwiftUI

struct ChapterEditorScreen: View {
    let book: Book

    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    struct EditableChapter: Identifiable {
        let id = UUID()
        var title: String
        var startText: String
    }

    @State private var rows: [EditableChapter] = []
    @State private var isSaving = false
    @State private var isLookingUp = false
    @State private var errorMessage: String?
    @State private var showASINPrompt = false
    @State private var asin = ""
    @State private var region = "us"
    @State private var originalLastEnd: TimeInterval?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.statusError)
                    .listRowBackground(Color.clear)
            }

            ForEach($rows) { $row in
                HStack(spacing: 10) {
                    TextField("0:00:00", text: $row.startText)
                        .font(.hearthUI(13, weight: .medium).monospacedDigit())
                        .foregroundStyle(hearth.ember)
                        .frame(width: 76)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Chapter title", text: $row.title)
                        .font(.hearthUI(15, weight: .regular))
                }
                .listRowBackground(hearth.bgElevated)
            }
            .onDelete { rows.remove(atOffsets: $0) }

            Button {
                addChapter()
            } label: {
                Label("Add chapter", systemImage: "plus")
                    .font(.hearthUI(15, weight: .medium))
                    .foregroundStyle(hearth.ember)
            }
            .listRowBackground(hearth.bgElevated)
        }
        .scrollContentBackground(.hidden)
        .background(HearthBackground())
        .navigationTitle("Edit Chapters")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        asin = book.asin ?? ""
                        showASINPrompt = true
                    } label: {
                        Label("Fetch from Audible (ASIN)", systemImage: "text.magnifyingglass")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    Task { await save() }
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                    }
                }
                .disabled(isSaving || rows.isEmpty)
            }
        }
        .alert("Audible chapter lookup", isPresented: $showASINPrompt) {
            TextField("ASIN", text: $asin)
            TextField("Region (us, uk, de…)", text: $region)
            Button("Fetch") { Task { await lookupAudnexus() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Replaces the list below with chapters from the Audnexus database.")
        }
        .onAppear {
            guard rows.isEmpty else { return }

            var chapters = book.chapters ?? []
            if chapters.isEmpty {
                chapters =
                    ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.stableId)
                    ?? ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.id)
                    ?? []
            }
            chapters.sort { $0.start < $1.start }
            originalLastEnd = chapters.last?.end
            rows = chapters.map {
                EditableChapter(title: $0.title, startText: Self.format($0.start))
            }
        }
        .disabled(isLookingUp)
        .overlay {
            if isLookingUp {
                ProgressView().tint(hearth.ember)
            }
        }
    }

    private func addChapter() {
        let startText: String
        if let lastStart = rows.last.flatMap({ Self.parse($0.startText) }) {
            startText = Self.format(lastStart + 60)
        } else {
            startText = Self.format(0)
        }
        rows.append(EditableChapter(title: "Chapter \(rows.count + 1)", startText: startText))
    }

    private func save() async {
        errorMessage = nil

        var parsed: [(title: String, start: TimeInterval)] = []
        for row in rows {
            guard let start = Self.parse(row.startText) else {
                errorMessage = "\"\(row.startText)\" isn't a valid time. Use h:mm:ss."
                return
            }
            parsed.append((row.title.trimmingCharacters(in: .whitespaces), start))
        }
        parsed.sort { $0.start < $1.start }

        let lastStart = parsed.last?.start ?? 0
        var finalEnd = book.duration ?? 0
        if finalEnd <= lastStart {
            finalEnd = (originalLastEnd ?? 0) > lastStart ? originalLastEnd! : lastStart + 60
        }
        let chapters = parsed.enumerated().map { index, entry in
            Chapter(
                id: String(index),
                start: entry.start,
                end: index + 1 < parsed.count ? parsed[index + 1].start : finalEnd,
                title: entry.title.isEmpty ? "Chapter \(index + 1)" : entry.title,
                index: index
            )
        }

        guard let provider = AppState.shared.getProvider(book.providerId) as? AudiobookshelfProvider else {
            errorMessage = "This book's Audiobookshelf connection is unavailable."
            return
        }

        isSaving = true
        defer { isSaving = false }
        do {
            try await provider.updateChapters(itemId: book.id, chapters: chapters)
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.stableId, chapters: chapters)
            if book.id != book.stableId {
                ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: chapters)
            }
            AppState.shared.mutateBook(uniqueId: book.uniqueId) { $0.chapters = chapters }
            if ActivePlayback.controller.snapshot.currentBook?.uniqueId == book.uniqueId {
                ActivePlayback.composition.bookMetadataUpdater.updateChapters(chapters, for: book)
                AppState.shared.currentBook?.chapters = chapters
                ActivePlayback.composition.nowPlayingUpdater.refreshNowPlayingInfo()
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func lookupAudnexus() async {
        let trimmed = asin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return }
        let regionCode = region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let url = URL(string: "https://api.audnex.us/books/\(trimmed)/chapters?region=\(regionCode.isEmpty ? "us" : regionCode)")
        else { return }

        struct AudnexusChapters: Decodable {
            struct Entry: Decodable {
                let title: String
                let startOffsetMs: Double
            }
            let chapters: [Entry]
        }

        isLookingUp = true
        defer { isLookingUp = false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(AudnexusChapters.self, from: data)
            guard !decoded.chapters.isEmpty else {
                errorMessage = "Audnexus has no chapters for \(trimmed)."
                return
            }
            let duration = book.duration ?? 0
            rows = decoded.chapters
                .filter { duration <= 0 || $0.startOffsetMs / 1000 < duration }
                .map { EditableChapter(title: $0.title, startText: Self.format($0.startOffsetMs / 1000)) }
            errorMessage = nil
        } catch {
            errorMessage = "Audnexus lookup failed. Check the ASIN."
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    static func parse(_ text: String) -> TimeInterval? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        var values: [Double] = []
        for (offset, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            if parts.count > 1, offset > 0, value >= 60 { return nil }
            values.append(value)
        }
        return values.reversed().enumerated().reduce(0) { total, item in
            total + item.element * pow(60, Double(item.offset))
        }
    }
}
