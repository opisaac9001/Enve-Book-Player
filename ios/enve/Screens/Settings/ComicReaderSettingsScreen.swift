import SwiftUI

struct ComicReaderSettingsScreen: View {
    @Environment(\.hearth) private var hearth
    @State private var loadingMode = ClassicReaderAppearance.load().comicPageLoadingMode

    var body: some View {
        SettingsScaffold(
            overline: "Playback & experience",
            title: "Comic reader",
            subtitle: "Choose how Enve loads comics from servers that support page streaming."
        ) {
            SourcesCard {
                Overline("Page loading")
                SettingsChoiceRow(
                    title: "Stream",
                    caption: ComicPageLoadingMode.onDemand.description,
                    systemImage: "network",
                    isSelected: loadingMode == .onDemand
                ) {
                    select(.onDemand)
                }
                SettingsChoiceRow(
                    title: "Preload",
                    caption: ComicPageLoadingMode.sessionCache.description,
                    systemImage: "arrow.down.circle",
                    isSelected: loadingMode == .sessionCache
                ) {
                    select(.sessionCache)
                }
            }

            SourcesCard {
                Text(
                    "This setting applies to every stream-capable comic source. Local files and comics saved with Download always open from the device."
                )
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            loadingMode = ClassicReaderAppearance.load().comicPageLoadingMode
        }
    }

    private func select(_ mode: ComicPageLoadingMode) {
        guard loadingMode != mode else { return }
        loadingMode = mode
        var appearance = ClassicReaderAppearance.load()
        appearance.comicPageLoadingMode = mode
        appearance.persist()
        PlatformHaptics.selection()
    }
}
