import Combine
import SwiftUI

struct VocabularyHubScreen: View {
    @Environment(EnveEngine.self) private var engine
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var entries: [VocabEntry] = []
    @State private var booksById: [String: Book] = [:]
    @State private var query = ""
    @State private var studySession: VocabStudyLaunch?
    @State private var loaded = false

    private var filteredEntries: [VocabEntry] {
        guard !query.isEmpty else { return entries }
        let q = query.lowercased()
        return entries.filter {
            $0.word.lowercased().contains(q)
                || $0.sentence.lowercased().contains(q)
                || ($0.userNote?.lowercased().contains(q) ?? false)
        }
    }

    private var grouped: [(book: Book?, entries: [VocabEntry])] {
        var byBook: [String: [VocabEntry]] = [:]
        for entry in filteredEntries {
            byBook[entry.bookStableId, default: []].append(entry)
        }
        return
            byBook
            .map { (book: booksById[$0.key], entries: $0.value.sorted { $0.lookedUpAt > $1.lookedUpAt }) }
            .sorted { lhs, rhs in
                (lhs.entries.first?.lookedUpAt ?? .distantPast) > (rhs.entries.first?.lookedUpAt ?? .distantPast)
            }
    }

    private var dueCount: Int { entries.filter { $0.isDue && !$0.isNew }.count }
    private var newCount: Int { entries.filter { $0.isNew }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header

                if !loaded {
                    HStack {
                        Spacer()
                        ProgressView()
                            .tint(hearth.ember)
                        Spacer()
                    }
                    .padding(.top, 60)
                } else if entries.isEmpty {
                    emptyState
                } else {
                    statsAndStudy
                    searchField

                    if filteredEntries.isEmpty {
                        Text("No word answers to “\(query)”.")
                            .font(.hearthDisplay(16, weight: .regular))
                            .foregroundStyle(hearth.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 30)
                    } else {
                        ForEach(grouped, id: \.book?.stableId) { group in
                            bookSection(book: group.book, entries: group.entries)
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .task { await vocabReload() }
        .fullScreenCover(
            item: $studySession,
            onDismiss: {
                Task { await vocabReload() }
            }
        ) { launch in
            VocabStudyScreen(entries: launch.entries, booksById: booksById)
                .enveEnvironment()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VocabBackGlyph()
            VStack(alignment: .leading, spacing: 6) {
                Overline("Words you kept")
                Text("Vocabulary")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
            }
            Spacer(minLength: 0)
            NavigationLink {
                VocabSettingsScreen()
            } label: {
                Image(systemName: "gearshape")
                    .font(.hearthUI(15, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(hearth.bgElevated)
                            .overlay(Circle().strokeBorder(hearth.hairline, lineWidth: 1))
                    }
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Vocabulary settings")
        }
        .padding(.horizontal, 24)
    }

    private var statsAndStudy: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 28) {
                vocabStat(value: entries.count, label: "Words")
                vocabStat(value: dueCount, label: "Due", emphasized: dueCount > 0)
                vocabStat(value: newCount, label: "New")
                Spacer()
            }
            EmberButton(title: studyTitle, systemImage: "rectangle.on.rectangle.angled") {
                studySession = VocabStudyLaunch(entries: entries)
            }
        }
        .padding(.horizontal, 24)
    }

    private var studyTitle: String {
        let limit = LibraryDisplayPreferencesStore.shared.loadPreferences().studyDailyNewLimit
        let tonight = dueCount + min(newCount, limit)
        return tonight > 0 ? "Study \(tonight) tonight" : "Study any word"
    }

    private func vocabStat(value: Int, label: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.hearthDisplay(28))
                .foregroundStyle(emphasized ? hearth.ember : hearth.text)
            Overline(label)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.textSecondary)
            TextField("", text: $query, prompt: Text("Find a word…").font(.hearthDisplay(16, weight: .regular)))
                .font(.hearthUI(16))
                .foregroundStyle(hearth.text)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.hearthUI(15))
                        .foregroundStyle(hearth.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, query.isEmpty ? 16 : 0)
        .frame(height: 48)
        .background {
            Capsule()
                .fill(hearth.bgElevated)
                .overlay(Capsule().strokeBorder(hearth.hairline, lineWidth: 1))
        }
        .padding(.horizontal, 24)
    }

    private func bookSection(book: Book?, entries: [VocabEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(book?.title ?? "An unknown book")
                    .font(.hearthDisplay(17, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                Spacer()
                Text("\(entries.count)")
                    .font(.hearthUI(12, weight: .semibold))
                    .foregroundStyle(hearth.ember)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(hearth.emberSoft, in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            ForEach(entries) { entry in
                Rectangle()
                    .fill(hearth.hairline)
                    .frame(height: 1)
                    .padding(.horizontal, 16)
                vocabRow(entry)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .fill(hearth.bgElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                        .strokeBorder(hearth.hairline, lineWidth: 1)
                }
        }
        .padding(.horizontal, 24)
    }

    private func vocabRow(_ entry: VocabEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.word)
                    .font(.hearthDisplay(18, weight: .semibold))
                    .foregroundStyle(hearth.text)
                Spacer()
                if entry.isMastered {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.hearthUI(12))
                        .foregroundStyle(hearth.statusOK)
                        .accessibilityLabel("Mastered")
                }
                Text(entry.lookedUpAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.hearthUI(11))
                    .foregroundStyle(hearth.textTertiary)
            }
            if !entry.sentence.isEmpty {
                Text(entry.sentence)
                    .font(.hearthDisplay(14, weight: .regular))
                    .italic()
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(3)
            }
            if let definition = entry.definitionSnapshot, !definition.isEmpty {
                Text(definition)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(2)
            }
            if let note = entry.userNote, !note.isEmpty {
                Text(note)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                studySession = VocabStudyLaunch(entries: [entry])
            } label: {
                Label("Study this word", systemImage: "rectangle.on.rectangle.angled")
            }
            Button(role: .destructive) {
                Task { await vocabDelete(entry) }
            } label: {
                Label("Let it go", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        HearthEmpty(
            glyph: "character.book.closed",
            title: "No words kept yet.",
            line: "Choose Define on a word while reading and it will wait for you here."
        )
    }

    private func vocabReload() async {
        let snapshot = await engine.vocabulary.snapshot()
        entries = snapshot.entries
        booksById = snapshot.booksById
        loaded = true
    }

    private func vocabDelete(_ entry: VocabEntry) async {
        await engine.vocabulary.delete(entry)
        await vocabReload()
    }
}

struct VocabStudyLaunch: Identifiable {
    let id = UUID()
    let entries: [VocabEntry]
}

struct VocabBackGlyph: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
    }
}
