#if os(iOS)
import SafariServices
import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct ReaderWikipediaRequest: Identifiable {
    let id = UUID()
    let query: ReaderLookup.WikipediaQuery
}

struct ReaderWikipediaSheet: View {
    let query: ReaderLookup.WikipediaQuery

    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var searchURL: URL?
    @FocusState private var fieldFocused: Bool
    private let languageCode = ReaderLookup.wikipediaLanguageCode()

    var body: some View {
        Group {
            if let searchURL {
                ReaderSafariView(url: searchURL, tint: hearth.ember) { dismiss() }
                    .ignoresSafeArea()
            } else {
                composer
            }
        }
        .presentationDetents(searchURL == nil ? [.medium, .large] : [.large])
        .onAppear {
            term = query.term
            if query.wasShortened {
                fieldFocused = true
            } else {
                search()
            }
        }
    }

    private var composer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Overline("Look up on Wikipedia")

                Text("Your selection is long, so the search starts with its opening words. Edit it to the phrase you want.")
                    .font(.hearthUI(15))
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("", text: $term, prompt: Text("Search term").font(.hearthDisplay(16, weight: .regular)), axis: .vertical)
                    .font(.hearthUI(16))
                    .foregroundStyle(hearth.text)
                    .focused($fieldFocused)
                    .lineLimit(1...4)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(search)
                    .padding(14)
                    .background {
                        RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                            .fill(hearth.bgElevated)
                            .overlay {
                                RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                    .strokeBorder(hearth.hairline, lineWidth: 1)
                            }
                    }
                    .accessibilityLabel("Wikipedia search term")

                Text("Searches \(languageName) Wikipedia. Only this search term is sent.")
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()
                    EmberButton(title: "Search Wikipedia", systemImage: "magnifyingglass", action: search)
                        .disabled(pendingURL == nil)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(hearth.bg)
        .hearthPresentationBackground()
    }

    private var languageName: String {
        Locale.current.localizedString(forLanguageCode: languageCode) ?? languageCode
    }

    private var pendingURL: URL? {
        ReaderLookup.wikipediaSearchURL(term: term, languageCode: languageCode)
    }

    private func search() {
        guard let url = pendingURL else { return }
        fieldFocused = false
        searchURL = url
    }
}

private struct ReaderSafariView: UIViewControllerRepresentable {
    let url: URL
    let tint: Color
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(tint)
        controller.dismissButtonStyle = .done
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onFinish() }
    }
}

struct ReaderTranslationPresenter: ViewModifier {
    @Binding var text: String?

    func body(content: Content) -> some View {
        #if canImport(Translation) && !targetEnvironment(macCatalyst)
        if #available(iOS 17.4, *) {
            content.translationPresentation(isPresented: isPresented, text: text ?? "")
        } else {
            unavailable(content)
        }
        #else
        unavailable(content)
        #endif
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { text != nil }, set: { if !$0 { text = nil } })
    }

    private func unavailable(_ content: Content) -> some View {
        content.alert("Translation Unavailable", isPresented: isPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Translate needs a supported iPhone or iPad running iOS 17.4 or later.")
        }
    }
}
#endif
