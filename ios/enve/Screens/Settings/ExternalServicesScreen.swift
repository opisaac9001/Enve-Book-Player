#if os(iOS)
import SwiftUI

struct ExternalServicesScreen: View {
    @Environment(\.hearth) private var hearth

    @State private var store: ExternalServicesStore

    init(store: ExternalServicesStore = .shared) {
        _store = State(initialValue: store)
    }

    var body: some View {
        SettingsScaffold(
            overline: "Privacy",
            title: "External services",
            subtitle: "Public catalogs Enve can ask for book details and discovery. These switches apply to this device and every profile on it."
        ) {
            ForEach(ExternalService.allCases) { service in
                SourcesCard {
                    SourcesToggleRow(
                        title: service.displayName,
                        subtitle: service.usedFor,
                        isOn: Binding(
                            get: { store.isEnabled(service) },
                            set: { store.setEnabled($0, for: service) }
                        )
                    )
                    .accessibilityHint(service.usedFor)
                    .accessibilityIdentifier("external-service-\(service.rawValue)")

                    Text(service.whenOff)
                        .font(.hearthCaption)
                        .foregroundStyle(hearth.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Overline("What stays the same")
                    .accessibilityAddTraits(.isHeader)
                Text(
                    "Turning a service off stops new searches, lookups, and charts from it, including retries already waiting. Details and covers already in your library stay, and covers saved from a catalog can still load from its image server."
                )
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Your own servers, sign-in, sync with Hardcover and Obsidian, podcast feeds you follow, and narrator voice downloads aren't affected."
                )
                .font(.hearthCaption)
                .foregroundStyle(hearth.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("external-services-screen")
    }
}

private extension ExternalService {
    var usedFor: String {
        switch self {
        case .audible: "Discover shelves, Enve Search matching, and ASIN lookups."
        case .appleCatalog: "iTunes audiobook matching, plus podcast directory search and top charts."
        case .googleBooks: "Ebook metadata matching."
        case .openLibrary: "Ebook metadata matching and book descriptions."
        case .comicVine: "Comic and manga metadata matching with your API key."
        }
    }

    var whenOff: String {
        switch self {
        case .audible: "When off, Discover and Enve Search stop contacting Audible. Matches you've already applied stay."
        case .appleCatalog: "When off, iTunes matching and podcast directory browsing stop. Podcasts you follow keep updating from their own feeds."
        case .googleBooks: "When off, Google Books searches stop. Your saved API key is kept."
        case .openLibrary: "When off, Open Library searches and description lookups stop."
        case .comicVine: "When off, ComicVine searches stop. Your saved API key is kept."
        }
    }
}
#endif
