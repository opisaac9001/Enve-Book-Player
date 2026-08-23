import SwiftUI

struct MetadataKeysScreen: View {
    @Environment(\.hearth) private var hearth
    @Environment(\.dismiss) private var dismiss

    @State private var googleBooksKey = ""
    @State private var comicVineKey = ""
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                SourcesCard {
                    SourcesField(
                        label: "Google Books API key",
                        text: $googleBooksKey,
                        placeholder: "Used for Google Books metadata",
                        secure: true
                    )
                    Text("Google Books uses this key from Keychain and sends it in the x-goog-api-key header.")
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SourcesCard {
                    SourcesField(
                        label: "ComicVine API key",
                        text: $comicVineKey,
                        placeholder: "Used for comic metadata",
                        secure: true
                    )
                }

                HStack(spacing: 10) {
                    EmberButton(title: saved ? "Saved" : "Save keys", systemImage: saved ? "checkmark" : "key.fill") {
                        SettingsManager.shared.googleBooksApiKey = googleBooksKey
                        SettingsManager.shared.comicVineApiKey = comicVineKey
                        saved = true
                        PlatformHaptics.impact(.light)
                    }
                    QuietButton(title: "Clear", systemImage: "xmark") {
                        googleBooksKey = ""
                        comicVineKey = ""
                        SettingsManager.shared.googleBooksApiKey = nil
                        SettingsManager.shared.comicVineApiKey = nil
                        saved = false
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            googleBooksKey = SettingsManager.shared.googleBooksApiKey ?? ""
            comicVineKey = SettingsManager.shared.comicVineApiKey ?? ""
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
            VStack(alignment: .leading, spacing: 6) {
                Overline("Metadata")
                Text("API keys")
                    .font(.hearthScreenTitle)
                    .foregroundStyle(hearth.text)
            }
            Spacer(minLength: 0)
        }
    }
}
