import Observation
import SwiftUI

@MainActor
@Observable
final class VocabStudySession {
    @ObservationIgnored private let vocabulary: VocabularyEngine

    private(set) var queue: [VocabEntry] = []
    private(set) var currentIndex = 0
    var isRevealed = false
    private(set) var reviewed: [(entry: VocabEntry, action: LeitnerScheduler.Action)] = []

    init(vocabulary: VocabularyEngine = EnveEngine.shared.vocabulary) {
        self.vocabulary = vocabulary
    }

    var currentEntry: VocabEntry? {
        guard currentIndex < queue.count else { return nil }
        return queue[currentIndex]
    }

    var isFinished: Bool { !queue.isEmpty && currentIndex >= queue.count }
    var isEmpty: Bool { queue.isEmpty }
    var totalCards: Int { queue.count }
    var cardsAnswered: Int { min(currentIndex, queue.count) }

    func buildQueue(from allEntries: [VocabEntry], dailyNewLimit: Int, shuffle: Bool) {
        let now = Date()
        let due = allEntries.filter { entry in
            !entry.isMastered && !entry.isNew && (entry.nextReviewAt.map { $0 <= now } ?? false)
        }
        let newCards = Array(allEntries.filter(\.isNew).prefix(max(0, dailyNewLimit)))

        var combined: [VocabEntry] = []
        combined.append(contentsOf: shuffle ? due.shuffled() : due)
        combined.append(contentsOf: shuffle ? newCards.shuffled() : newCards)

        if combined.isEmpty {
            let anything = allEntries.filter { !$0.isMastered }
            combined = shuffle ? anything.shuffled() : anything
        }

        queue = combined
        currentIndex = 0
        isRevealed = false
        reviewed = []
    }

    func updateDefinition(for entryID: String, _ definition: String?) async {
        guard let idx = queue.firstIndex(where: { $0.id == entryID }) else { return }
        let trimmed = definition?.trimmingCharacters(in: .whitespacesAndNewlines)
        queue[idx].definitionSnapshot = (trimmed?.isEmpty ?? true) ? nil : trimmed
        await vocabulary.save(queue[idx])
    }

    func answer(_ action: LeitnerScheduler.Action) async {
        guard var entry = currentEntry else { return }
        let result = LeitnerScheduler.apply(
            action: action,
            currentBox: entry.studyBox,
            currentStreak: entry.reviewStreak
        )
        entry.studyBox = result.newBox
        entry.nextReviewAt = result.nextReviewAt
        entry.lastReviewedAt = Date()
        entry.reviewStreak = result.reviewStreak
        await vocabulary.save(entry)

        reviewed.append((entry: entry, action: action))
        currentIndex += 1
        isRevealed = false
    }
}

struct VocabStudyScreen: View {
    let entries: [VocabEntry]
    let booksById: [String: Book]

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var session = VocabStudySession()
    @State private var started = false

    var body: some View {
        ZStack {
            hearth.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    GlyphButton(systemImage: "xmark", label: "Close") { dismiss() }
                    Spacer()
                    Overline("Study")
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                if !started {
                    Spacer()
                    ProgressView()
                        .tint(hearth.ember)
                    Spacer()
                } else if session.isEmpty {
                    emptyView
                } else if session.isFinished {
                    finishedView
                } else if let entry = session.currentEntry {
                    VStack(spacing: 16) {
                        progressHeader
                            .padding(.horizontal, 24)
                            .padding(.top, 14)

                        Spacer(minLength: 0)

                        VocabStudyCard(
                            entry: entry,
                            bookTitle: booksById[entry.bookStableId]?.title ?? "",
                            showSentenceFirst: LibraryDisplayPreferencesStore.shared.loadPreferences().studyShowSentenceFirst,
                            isRevealed: session.isRevealed,
                            onTap: {
                                guard !session.isRevealed else { return }
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                                    session.isRevealed = true
                                }
                                PlatformHaptics.impact(.light)
                            },
                            onDefinitionChange: { entryID, newValue in
                                await session.updateDefinition(for: entryID, newValue)
                            }
                        )
                        .padding(.horizontal, 24)

                        Spacer(minLength: 0)

                        if session.isRevealed {
                            actionButtons
                                .padding(.horizontal, 24)
                                .padding(.bottom, 28)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            Text("Tap the card to turn it over.")
                                .font(.hearthCaption)
                                .foregroundStyle(hearth.textSecondary)
                                .padding(.bottom, 36)
                        }
                    }
                    .animation(.smooth(duration: 0.3), value: session.isRevealed)
                }
            }
        }
        .onAppear {
            guard !started else { return }
            let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
            session.buildQueue(
                from: entries,
                dailyNewLimit: prefs.studyDailyNewLimit,
                shuffle: prefs.studyShuffleQueue
            )
            started = true
        }
    }

    private var progressHeader: some View {
        let total = session.totalCards
        let fraction = total > 0 ? Double(session.cardsAnswered) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(session.cardsAnswered) of \(total)")
                    .font(.hearthUI(12, weight: .medium).monospacedDigit())
                    .foregroundStyle(hearth.textSecondary)
                Spacer()
                if let entry = session.currentEntry {
                    vocabBoxBadge(entry.studyBox)
                }
            }
            Ribbon(progress: fraction, tint: hearth.ember)
        }
    }

    private func vocabBoxBadge(_ box: Int) -> some View {
        let label: String
        let color: Color
        switch box {
        case 0: label = "New"; color = hearth.ember
        case 1: label = "Learning"; color = hearth.statusWarn
        case 2, 3: label = "Reviewing"; color = hearth.statusWarn
        case 4: label = "Nearly there"; color = hearth.statusOK
        default: label = "Mastered"; color = hearth.statusOK
        }
        return Text(label)
            .font(.hearthUI(11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            vocabActionButton(title: "Again", icon: "arrow.counterclockwise", color: hearth.statusError, action: .again)
            vocabActionButton(title: "Got it", icon: "checkmark", color: hearth.ember, action: .gotIt)
            vocabActionButton(title: "Mastered", icon: "star.fill", color: hearth.statusOK, action: .mastered)
        }
    }

    private func vocabActionButton(title: String, icon: String, color: Color, action: LeitnerScheduler.Action) -> some View {
        Button {
            PlatformHaptics.impact(.light)
            Task { await session.answer(action) }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.hearthUI(17, weight: .semibold))
                Text(title)
                    .font(.hearthUI(14, weight: .semibold))
                Text(vocabIntervalCaption(for: action))
                    .font(.hearthUI(11))
                    .opacity(0.8)
            }
            .foregroundStyle(hearth.onEmber)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }

    private func vocabIntervalCaption(for action: LeitnerScheduler.Action) -> String {
        guard let entry = session.currentEntry else { return "" }
        switch action {
        case .again:
            return "1d"
        case .gotIt:

            if entry.reviewStreak >= 3 && entry.studyBox >= 4 { return "Done" }
            switch min(entry.studyBox + 1, 4) {
            case 1: return "1d"
            case 2: return "3d"
            case 3: return "1w"
            case 4: return "2w"
            default: return "Done"
            }
        case .mastered:
            return "Done"
        }
    }

    private var finishedView: some View {
        let totals = vocabSessionTotals()
        return VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.hearthUI(48))
                .foregroundStyle(hearth.statusOK)
            Text("The session is done.")
                .font(.hearthDisplay(24, weight: .semibold))
                .foregroundStyle(hearth.text)
            VStack(spacing: 10) {
                vocabSummaryRow(label: "Got it", value: totals.gotIt, color: hearth.ember)
                vocabSummaryRow(label: "Again", value: totals.again, color: hearth.statusError)
                vocabSummaryRow(label: "Mastered", value: totals.mastered, color: hearth.statusOK)
            }
            .padding(18)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
            }
            .padding(.horizontal, 40)
            EmberButton(title: "Close the deck") { dismiss() }
                .padding(.top, 6)
            Spacer()
        }
    }

    private func vocabSummaryRow(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label)
                .font(.hearthUI(15, weight: .medium))
                .foregroundStyle(hearth.text)
            Spacer()
            Text("\(value)")
                .font(.hearthUI(15, weight: .semibold).monospacedDigit())
                .foregroundStyle(hearth.text)
        }
    }

    private func vocabSessionTotals() -> (gotIt: Int, again: Int, mastered: Int) {
        var gotIt = 0
        var again = 0
        var mastered = 0
        for review in session.reviewed {
            switch review.action {
            case .gotIt: gotIt += 1
            case .again: again += 1
            case .mastered: mastered += 1
            }
        }
        return (gotIt, again, mastered)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray")
                .font(.hearthUI(40))
                .foregroundStyle(hearth.textSecondary)
            Text("Nothing to study tonight.")
                .font(.hearthDisplay(20, weight: .semibold))
                .foregroundStyle(hearth.text)
            Text("Keep more words while reading, or come back tomorrow.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            QuietButton(title: "Close") { dismiss() }
                .padding(.top, 8)
            Spacer()
        }
    }
}

private struct VocabStudyCard: View {
    let entry: VocabEntry
    let bookTitle: String
    let showSentenceFirst: Bool
    let isRevealed: Bool
    let onTap: () -> Void
    let onDefinitionChange: (_ entryID: String, _ definition: String?) async -> Void

    @Environment(\.hearth) private var hearth
    @State private var isFetchingDefinition = false
    @State private var isEditingDefinition = false
    @State private var lookupAttemptedFor: String?

    var body: some View {
        ZStack {
            cardFace { backContent }
                .opacity(isRevealed ? 1 : 0)
                .rotation3DEffect(.degrees(isRevealed ? 0 : -180), axis: (x: 0, y: 1, z: 0))
            cardFace { frontContent }
                .opacity(isRevealed ? 0 : 1)
                .rotation3DEffect(.degrees(isRevealed ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        }
        .frame(maxWidth: .infinity, minHeight: 320)
        .onTapGesture { onTap() }
        .task(id: entry.id) { await vocabBackfillIfNeeded() }
        .sheet(isPresented: $isEditingDefinition) {
            VocabDefinitionEditor(
                word: entry.word,
                initialDefinition: entry.definitionSnapshot ?? ""
            ) { newValue in
                await onDefinitionChange(entry.id, newValue)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .enveEnvironment()
        }
    }

    private func vocabBackfillIfNeeded() async {
        guard entry.definitionSnapshot?.isEmpty ?? true else { return }
        guard lookupAttemptedFor != entry.id else { return }
        lookupAttemptedFor = entry.id
        isFetchingDefinition = true
        defer { isFetchingDefinition = false }
        if let definition = await DefinitionLookupService.shared.definition(
            for: entry.word,
            language: entry.sourceLanguage
        ) {
            await onDefinitionChange(entry.id, definition)
        }
    }

    private func cardFace<C: View>(@ViewBuilder content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 320)
            .padding(24)
            .background {
                RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                    .fill(hearth.bgElevated)
                    .overlay {
                        RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                            .strokeBorder(hearth.hairline, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(hearth.isInk ? 0.4 : 0.14), radius: 14, y: 6)
            }
    }

    private var frontContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showSentenceFirst, !entry.sentence.isEmpty {
                Spacer()
                Text(vocabMaskedSentence)
                    .font(.hearthDisplay(19, weight: .regular))
                    .foregroundStyle(hearth.text)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Spacer()
                Text("Which word is missing?")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .frame(maxWidth: .infinity)
            } else {
                Spacer()
                Text(entry.word)
                    .font(.hearthDisplay(36))
                    .foregroundStyle(hearth.text)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
                HStack {
                    if !bookTitle.isEmpty {
                        Text("from \(bookTitle)")
                            .font(.hearthUI(11))
                            .foregroundStyle(hearth.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Overline("Tap to reveal")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var backContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.word)
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
                Spacer()
                Button {
                    isEditingDefinition = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.hearthUI(15, weight: .medium))
                        .foregroundStyle(hearth.textSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Edit definition")
            }

            if let definition = entry.definitionSnapshot, !definition.isEmpty {
                Text(definition)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.text)
            } else if isFetchingDefinition {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(hearth.ember)
                    Text("Looking it up…")
                        .font(.hearthBody)
                        .foregroundStyle(hearth.textSecondary)
                }
            } else {
                Button {
                    isEditingDefinition = true
                } label: {
                    Text("No definition kept. Tap to write one.")
                        .font(.hearthBody)
                        .italic()
                        .foregroundStyle(hearth.textSecondary)
                }
            }

            if let note = entry.userNote, !note.isEmpty {
                Text(note)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(hearth.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer()

            if !entry.sentence.isEmpty {
                Text(vocabHighlightedSentence)
                    .font(.hearthDisplay(14, weight: .regular))
                    .italic()
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var vocabMaskedSentence: String {
        entry.sentence.replacingOccurrences(
            of: entry.word,
            with: String(repeating: "_", count: max(3, entry.word.count))
        )
    }

    private var vocabHighlightedSentence: AttributedString {
        var attributed = AttributedString(entry.sentence)
        if let range = attributed.range(of: entry.word) {
            attributed[range].font = .hearthUI(14, weight: .bold)
            attributed[range].foregroundColor = hearth.ember
        }
        return attributed
    }
}

private struct VocabDefinitionEditor: View {
    let word: String
    let initialDefinition: String
    let onSave: (String?) async -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(word)
                .font(.hearthDisplay(24, weight: .semibold))
                .foregroundStyle(hearth.text)

            TextEditor(text: $text)
                .font(.hearthBody)
                .foregroundStyle(hearth.text)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 140)
                .background {
                    RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                        .fill(hearth.bg)
                        .overlay {
                            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                .strokeBorder(hearth.hairline, lineWidth: 1)
                        }
                }

            Text("Leave it empty to clear the kept definition.")
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)

            HStack(spacing: 10) {
                QuietButton(title: "Never mind") { dismiss() }
                EmberButton(title: "Keep it") {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        await onSave(trimmed.isEmpty ? nil : trimmed)
                        dismiss()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(hearth.bgElevated)
        .hearthPresentationBackground()
        .onAppear { text = initialDefinition }
    }
}
