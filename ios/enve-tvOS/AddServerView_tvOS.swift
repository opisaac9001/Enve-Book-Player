import SwiftUI

struct AddServerView_tvOS: View {
    @Environment(\.dismiss) private var dismiss

    enum Backend: String, CaseIterable, Identifiable {
        case audiobookshelf
        case plex
        case jellyfin
        case emby
        case komga
        case kavita
        case booklore
        case storyteller
        case opds
        case webdav
        case premiumize
        case realdebrid
        case torbox

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .audiobookshelf: return "Audiobookshelf"
            case .plex: return "Plex"
            case .jellyfin: return "Jellyfin"
            case .emby: return "Emby"
            case .komga: return "Komga"
            case .kavita: return "Kavita"
            case .booklore: return "Booklore"
            case .storyteller: return "Storyteller"
            case .opds: return "OPDS"
            case .webdav: return "WebDAV"
            case .premiumize: return "Premiumize"
            case .realdebrid: return "Real-Debrid"
            case .torbox: return "TorBox"
            }
        }

        var icon: String {
            switch self {
            case .audiobookshelf: return "books.vertical.fill"
            case .plex: return "play.tv.fill"
            case .jellyfin, .emby: return "server.rack"
            case .komga, .kavita: return "book.closed.fill"
            case .booklore: return "text.book.closed.fill"
            case .storyteller: return "headphones"
            case .opds: return "globe"
            case .webdav: return "folder.fill.badge.gearshape"
            case .premiumize, .realdebrid, .torbox: return "icloud.and.arrow.down.fill"
            }
        }

        var providerType: ProviderType {
            switch self {
            case .audiobookshelf: return .audiobookshelf
            case .plex: return .plex
            case .jellyfin: return .jellyfin
            case .emby: return .emby
            case .komga: return .komga
            case .kavita: return .kavita
            case .booklore: return .booklore
            case .storyteller: return .storyteller
            case .opds: return .opds
            case .webdav, .premiumize, .realdebrid, .torbox: return .webdav
            }
        }

        var authStyle: AuthStyle {
            switch self {
            case .plex:
                return .plexPIN
            case .audiobookshelf, .storyteller:
                return .usernamePassword
            case .jellyfin, .emby:
                return .usernamePassword
            case .komga, .kavita, .booklore, .webdav, .premiumize, .realdebrid, .torbox:
                return .usernamePassword
            case .opds:
                return .usernamePasswordOptional
            }
        }
    }

    enum AuthStyle {
        case plexPIN
        case usernamePassword
        case usernamePasswordOptional
    }

    var body: some View {
        NavigationStack {
            ZStack {

                Color(white: 0.10).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {

                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Add Server")
                                .font(.system(size: 56, weight: .bold))
                            Text("Choose your media server. You can connect more than one.")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, 90)
                    .padding(.top, 70)
                    .padding(.bottom, 40)

                    ScrollView {
                        VStack(spacing: 20) {
                            ForEach(Backend.allCases) { backend in
                                NavigationLink {
                                    destination(for: backend)
                                } label: {
                                    backendRow(backend)
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .padding(.horizontal, 90)
                        .padding(.bottom, 60)
                    }
                }
            }
        }
    }

    private func backendRow(_ backend: Backend) -> some View {
        HStack(spacing: 24) {
            Image(systemName: backend.icon)
                .font(.system(size: 34))
                .foregroundStyle(.tint)
                .frame(width: 56)
            Text(backend.displayName)
                .font(.title2)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func destination(for backend: Backend) -> some View {
        switch backend.authStyle {
        case .plexPIN:
            PlexLoginView_tvOS()
        case .usernamePassword, .usernamePasswordOptional:
            ServerLoginForm_tvOS(backend: backend)
        }
    }
}
