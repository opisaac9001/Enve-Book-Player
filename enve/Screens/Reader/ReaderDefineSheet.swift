import SwiftUI
import UIKit

struct ReaderDefineSheet: View {
    let term: String
    let vocabEntry: VocabEntry?
    let initiallySaved: Bool
    let onSaveWord: (VocabEntry) -> Void

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var phase: ReaderDefinePhase = .loading
    @State private var savedWord = false

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .loading:
                Spacer()
                ProgressView()
                    .tint(hearth.ember)
                Spacer()
            case .definition(let text):
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(term)
                            .font(.hearthDisplay(26, weight: .semibold))
                            .foregroundStyle(hearth.text)
                        Text(text)
                            .font(.hearthDisplay(16, weight: .regular))
                            .foregroundStyle(hearth.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 26)
                    .padding(.bottom, 20)
                }
                .scrollIndicators(.hidden)
            case .systemDictionary:
                ReaderSystemDictionaryView(term: term)
                    .ignoresSafeArea(edges: .bottom)
            case .unavailable:
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "character.book.closed")
                        .font(.hearthUI(30))
                        .foregroundStyle(hearth.textSecondary)
                    Text("No definition to be found for “\(term)”.")
                        .font(.hearthDisplay(16, weight: .regular))
                        .foregroundStyle(hearth.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
                Spacer()
            }

            if let vocabEntry, phase != .loading {
                HStack {
                    if savedWord {
                        Text("Kept in your vocabulary.")
                            .font(.hearthCaption)
                            .foregroundStyle(hearth.textSecondary)
                    } else {
                        QuietButton(title: "Save word", systemImage: "text.book.closed") {
                            onSaveWord(vocabEntry)
                            savedWord = true
                            PlatformHaptics.impact(.light)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(hearth.bg)
        .hearthPresentationBackground()
        .onAppear { savedWord = initiallySaved }
        .task(id: term) { await resolve() }
    }

    private func resolve() async {
        phase = .loading
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .unavailable
            return
        }

        if UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: trimmed) {
            phase = .systemDictionary
            return
        }
        if let definition = await DefinitionLookupService.shared.definition(for: trimmed) {
            phase = .definition(definition)
            return
        }
        phase = .unavailable
    }
}

private enum ReaderDefinePhase: Equatable {
    case loading
    case definition(String)
    case systemDictionary
    case unavailable
}

private struct ReaderSystemDictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ uiViewController: UIReferenceLibraryViewController, context: Context) {}
}
