import Combine
import SwiftUI

struct VocabSettingsScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset

    @State private var prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: 14) {
                    VocabBackGlyph()
                    VStack(alignment: .leading, spacing: 6) {
                        Overline("Vocabulary")
                        Text("Behavior")
                            .font(.hearthScreenTitle)
                            .foregroundStyle(hearth.text)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)

                vocabCard {
                    Overline("Lookups")
                    Toggle(
                        isOn: Binding(
                            get: { prefs.vocabAutoLogLookups },
                            set: {
                                prefs.vocabAutoLogLookups = $0; vocabPersist()
                            }
                        )
                    ) {
                        Text("Keep every lookup")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                    }
                    .tint(hearth.ember)
                    Text("When on, every word you Define while reading is kept here on its own. When off, you choose each time.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }

                vocabCard {
                    Overline("The review deck")

                    HStack(spacing: 12) {
                        Text("New cards per session")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                        Spacer()
                        Text("\(prefs.studyDailyNewLimit)")
                            .font(.hearthUI(15, weight: .semibold).monospacedDigit())
                            .foregroundStyle(hearth.textSecondary)
                        GlyphButton(systemImage: "minus", size: 36, glyphSize: 13, label: "Fewer new cards") {
                            prefs.studyDailyNewLimit = max(0, prefs.studyDailyNewLimit - 5)
                            vocabPersist()
                        }
                        GlyphButton(systemImage: "plus", size: 36, glyphSize: 13, label: "More new cards") {
                            prefs.studyDailyNewLimit = min(100, prefs.studyDailyNewLimit + 5)
                            vocabPersist()
                        }
                    }

                    Toggle(
                        isOn: Binding(
                            get: { prefs.studyShowSentenceFirst },
                            set: {
                                prefs.studyShowSentenceFirst = $0; vocabPersist()
                            }
                        )
                    ) {
                        Text("Show the sentence first")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                    }
                    .tint(hearth.ember)

                    Toggle(
                        isOn: Binding(
                            get: { prefs.studyShuffleQueue },
                            set: {
                                prefs.studyShuffleQueue = $0; vocabPersist()
                            }
                        )
                    ) {
                        Text("Shuffle the deck")
                            .font(.hearthBody)
                            .foregroundStyle(hearth.text)
                    }
                    .tint(hearth.ember)

                    Text("Showing the sentence first hides the word behind a blank, which is better for recalling it in context.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func vocabCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func vocabPersist() {
        LibraryDisplayPreferencesStore.shared.savePreferences(prefs)
    }
}
