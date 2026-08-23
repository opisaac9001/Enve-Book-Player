import Foundation

enum TVAuthMethod: String, CaseIterable, Identifiable {
    case usernamePassword
    case token
    case quickConnect

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .usernamePassword: return "Username & Password"
        case .token: return "Token / API Key"
        case .quickConnect: return "Quick Connect"
        }
    }
}

struct TVServerCapability {
    let providerType: ProviderType
    let displayName: String
    let iconSystemName: String

    let authMethods: [TVAuthMethod]

    let credentialsOptional: Bool

    let requiresIPhoneForFullSetup: Bool

    let serverURLPlaceholder: String
    let usernameLabel: String
    let passwordLabel: String
    let tokenLabel: String

    let webDAVPresets: [TVWebDAVPreset]

    static func forBackend(_ backend: AddServerView_tvOS.Backend) -> TVServerCapability {
        switch backend {
        case .audiobookshelf:
            return TVServerCapability(
                providerType: .audiobookshelf,
                displayName: "Audiobookshelf",
                iconSystemName: "books.vertical.fill",
                authMethods: [.usernamePassword, .token],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "https://abs.example.com",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: []
            )
        case .plex:

            return TVServerCapability(
                providerType: .plex,
                displayName: "Plex",
                iconSystemName: "play.tv.fill",
                authMethods: [.token],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "https://plex.example.com",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "Plex Token",
                webDAVPresets: []
            )
        case .jellyfin:
            return TVServerCapability(
                providerType: .jellyfin,
                displayName: "Jellyfin",
                iconSystemName: "play.rectangle.fill",
                authMethods: [.usernamePassword, .quickConnect],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "http://192.168.1.100:8096",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: []
            )
        case .emby:
            return TVServerCapability(
                providerType: .emby,
                displayName: "Emby",
                iconSystemName: "play.rectangle.fill",
                authMethods: [.usernamePassword],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "http://192.168.1.100:8096",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: []
            )
        case .komga:
            return TVServerCapability(
                providerType: .komga,
                displayName: "Komga",
                iconSystemName: "book.fill",
                authMethods: [.usernamePassword, .token],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "https://komga.example.com",
                usernameLabel: "Email",
                passwordLabel: "Password",
                tokenLabel: "API Key",
                webDAVPresets: []
            )
        case .kavita:
            return TVServerCapability(
                providerType: .kavita,
                displayName: "Kavita",
                iconSystemName: "book.fill",
                authMethods: [.usernamePassword, .token],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "https://kavita.example.com",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Key",
                webDAVPresets: []
            )
        case .booklore:
            return TVServerCapability(
                providerType: .booklore,
                displayName: "Grimmory",
                iconSystemName: "text.book.closed.fill",
                authMethods: [.usernamePassword, .token],
                credentialsOptional: false,

                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "https://grimmory.example.com",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: []
            )
        case .storyteller:
            return TVServerCapability(
                providerType: .storyteller,
                displayName: "Storyteller",
                iconSystemName: "headphones",
                authMethods: [.usernamePassword],
                credentialsOptional: false,

                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "http://192.168.1.10:8001",
                usernameLabel: "Username or Email",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: []
            )
        case .opds:
            return TVServerCapability(
                providerType: .opds,
                displayName: "OPDS",
                iconSystemName: "globe",
                authMethods: [.usernamePassword, .token],
                credentialsOptional: true,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "https://opds.example.com/feed",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: []
            )
        case .webdav:
            return TVServerCapability(
                providerType: .webdav,
                displayName: "WebDAV",
                iconSystemName: "folder.fill.badge.gearshape",
                authMethods: [.usernamePassword, .token],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: "https://webdav.example.com",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: TVWebDAVPreset.allCases
            )
        case .premiumize:
            return TVServerCapability(
                providerType: .webdav,
                displayName: "Premiumize",
                iconSystemName: "icloud.and.arrow.down.fill",
                authMethods: [.usernamePassword],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: TVWebDAVPreset.premiumize.resolvedURL ?? "",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: [.premiumize]
            )
        case .realdebrid:
            return TVServerCapability(
                providerType: .webdav,
                displayName: "Real-Debrid",
                iconSystemName: "icloud.and.arrow.down.fill",
                authMethods: [.usernamePassword],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: TVWebDAVPreset.realDebrid.resolvedURL ?? "",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: [.realDebrid]
            )
        case .torbox:
            return TVServerCapability(
                providerType: .webdav,
                displayName: "TorBox",
                iconSystemName: "icloud.and.arrow.down.fill",
                authMethods: [.usernamePassword],
                credentialsOptional: false,
                requiresIPhoneForFullSetup: false,
                serverURLPlaceholder: TVWebDAVPreset.torbox.resolvedURL ?? "",
                usernameLabel: "Username",
                passwordLabel: "Password",
                tokenLabel: "API Token",
                webDAVPresets: [.torbox]
            )
        }
    }
}

enum TVWebDAVPreset: String, CaseIterable, Identifiable {
    case generic
    case premiumize
    case realDebrid
    case torbox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generic: return "Generic WebDAV"
        case .premiumize: return "Premiumize"
        case .realDebrid: return "Real-Debrid"
        case .torbox: return "TorBox"
        }
    }

    var resolvedURL: String? {
        switch self {
        case .generic: return nil
        case .premiumize: return "https://webdav.premiumize.me"
        case .realDebrid: return "https://api.real-debrid.com/rest/1.0"
        case .torbox: return "https://webdav.torbox.app"
        }
    }
}
