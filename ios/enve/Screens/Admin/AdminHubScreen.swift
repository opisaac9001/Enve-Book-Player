import SwiftUI

struct AdminHubScreen: View {
    let connection: ServerConnection

    @Environment(\.hearth) private var hearth
    @Environment(\.mantelInset) private var mantelInset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch connection.type {
        case .audiobookshelf:
            AdminABSScreen(connection: connection)
        case .plex:
            AdminPlexScreen(connection: connection)
        case .jellyfin, .emby:
            AdminJellyfinScreen(connection: connection)
        case .komga:
            AdminKomgaScreen(connection: connection)
        case .booklore:
            AdminGrimmoryScreen(connection: connection)
        case .silo:
            AdminSiloScreen(connection: connection)
        case .kavita:
            AdminKavitaScreen(connection: connection)
        case .bookOrbit:
            AdminBookOrbitScreen(connection: connection)
        case .storyteller:
            AdminStorytellerScreen(connection: connection)
        default:
            adminUnsupported
        }
    }

    private var adminUnsupported: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    GlyphButton(systemImage: "chevron.left", size: 40, glyphSize: 15, label: "Back") { dismiss() }
                    VStack(alignment: .leading, spacing: 4) {
                        Overline("Server hub")
                        Text(connection.name)
                            .font(.hearthDisplay(26))
                            .foregroundStyle(hearth.text)
                            .lineLimit(2)
                    }
                }
                Text("This source manages itself. There are no server tools to offer here.")
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, mantelInset + 16)
        }
        .scrollIndicators(.hidden)
        .background(HearthBackground())
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct AdminHubHeader: View {
    let connection: ServerConnection

    @Environment(\.hearth) private var hearth

    var body: some View {
        HStack(spacing: 14) {
            SourcesProviderLogo(
                assetName: connection.iconAssetName,
                systemName: connection.iconSystemName,
                size: 52
            )
            VStack(alignment: .leading, spacing: 4) {
                Overline("Server hub")
                Text(connection.name)
                    .font(.hearthDisplay(26))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                Text(URL(string: connection.url)?.host ?? connection.url)
                    .font(.hearthCaption)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
    }
}
