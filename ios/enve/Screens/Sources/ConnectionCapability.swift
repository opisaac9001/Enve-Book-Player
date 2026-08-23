import Foundation

enum UnifiedWebDAVPreset: String, CaseIterable, Identifiable {
    case generic = "Generic"
    case torbox = "TorBox"
    case premiumize = "Premiumize"
    case realdebrid = "Real-Debrid"

    var id: String { rawValue }

    var resolvedURL: String? {
        switch self {
        case .generic: return nil
        case .torbox: return "https://webdav.torbox.app"
        case .premiumize: return "https://webdav.premiumize.me"
        case .realdebrid: return "https://api.real-debrid.com/rest/1.0"
        }
    }

    var assetIconName: String? {
        switch self {
        case .generic: return "WebDAVLogo"
        case .torbox: return "TorBoxLogo"
        case .premiumize: return "PremiumizeLogo"
        case .realdebrid: return "RealDebridLogo"
        }
    }

    var systemIconName: String {
        switch self {
        case .generic: return "externaldrive.connected.to.line.below.fill"
        case .torbox: return "shippingbox"
        case .premiumize: return "cloud.fill"
        case .realdebrid: return "link.circle.fill"
        }
    }

    var suggestedName: String? {
        switch self {
        case .generic: return nil
        case .torbox: return "TorBox"
        case .premiumize: return "Premiumize"
        case .realdebrid: return "Real-Debrid"
        }
    }

    var usernameLabel: String {
        switch self {
        case .premiumize: return "Customer ID"
        case .torbox: return "Email or torbox"
        default: return "Username"
        }
    }

    var passwordLabel: String {
        switch self {
        case .premiumize: return "API Key / PIN"
        case .torbox: return "Password or API Key"
        default: return "Password"
        }
    }

    var tokenLabel: String {
        switch self {
        case .realdebrid: return "API Token"
        default: return "API Token"
        }
    }

    var preferredAuthMethod: UnifiedAuthMethod {
        switch self {
        case .realdebrid: return .token
        case .torbox: return .token
        case .generic, .premiumize: return .usernamePassword
        }
    }

    var allowedAuthMethods: [UnifiedAuthMethod]? {
        switch self {
        case .generic: return nil
        case .realdebrid: return [.token]
        case .torbox: return [.token]
        case .premiumize: return [.usernamePassword]
        }
    }
}

struct ConnectionCapability {
    let providerType: ProviderType
    let displayName: String
    let iconSystemName: String
    let iconColor: String

    var assetIconName: String? { providerType.assetIconName }

    let supportsUsernamePassword: Bool
    let supportsToken: Bool
    let supportsOIDC: Bool
    let supportsQuickConnect: Bool
    let supportsWebLogin: Bool

    var credentialsOptional: Bool = false

    let supportsBrowserSignIn: Bool
    let supportsCustomHeaders: Bool
    let supportsServiceTokens: Bool
    let supportsMTLS: Bool
    let supportsLibrarySelection: Bool
    let supportsWebDAVPresets: Bool

    let serverURLPlaceholder: String
    let credentialLabels: CredentialLabels

    struct CredentialLabels {
        var usernamePlaceholder: String = "Username"
        var passwordPlaceholder: String = "Password"
        var tokenPlaceholder: String = "API Token"
    }
}

extension ConnectionCapability {

    static let emby = ConnectionCapability(
        providerType: .emby,
        displayName: "Emby",
        iconSystemName: "play.rectangle.fill",
        iconColor: "green",
        supportsUsernamePassword: true,
        supportsToken: false,
        supportsOIDC: false,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: true,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "http://192.168.1.100:8096",
        credentialLabels: .init()
    )

    static let jellyfin = ConnectionCapability(
        providerType: .jellyfin,
        displayName: "Jellyfin",
        iconSystemName: "play.rectangle.fill",
        iconColor: "indigo",
        supportsUsernamePassword: true,
        supportsToken: false,
        supportsOIDC: false,
        supportsQuickConnect: true,
        supportsWebLogin: false,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: true,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "http://192.168.1.100:8096",
        credentialLabels: .init()
    )

    static let audiobookshelf = ConnectionCapability(
        providerType: .audiobookshelf,
        displayName: "Audiobookshelf",
        iconSystemName: "books.vertical.fill",
        iconColor: "blue",
        supportsUsernamePassword: true,
        supportsToken: false,
        supportsOIDC: true,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "https://abs.example.com",
        credentialLabels: .init()
    )

    static let storyteller = ConnectionCapability(
        providerType: .storyteller,
        displayName: "Storyteller",
        iconSystemName: "text.book.closed.fill",
        iconColor: "orange",
        supportsUsernamePassword: true,
        supportsToken: false,
        supportsOIDC: false,
        supportsQuickConnect: false,
        supportsWebLogin: true,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "http://192.168.1.10:8001",
        credentialLabels: .init(usernamePlaceholder: "Username or Email")
    )

    static let webdav = ConnectionCapability(
        providerType: .webdav,
        displayName: "WebDAV",
        iconSystemName: "externaldrive.connected.to.line.below.fill",
        iconColor: "gray",
        supportsUsernamePassword: true,
        supportsToken: true,
        supportsOIDC: false,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: true,
        serverURLPlaceholder: "https://webdav.example.com",
        credentialLabels: .init(tokenPlaceholder: "API Token")
    )

    static let torbox = ConnectionCapability(
        providerType: .torbox,
        displayName: "TorBox",
        iconSystemName: "shippingbox",
        iconColor: "cyan",
        supportsUsernamePassword: false,
        supportsToken: true,
        supportsOIDC: false,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        supportsBrowserSignIn: false,
        supportsCustomHeaders: false,
        supportsServiceTokens: false,
        supportsMTLS: false,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "https://api.torbox.app/v1/api",
        credentialLabels: .init(tokenPlaceholder: "API Token")
    )

    static let booklore = ConnectionCapability(
        providerType: .booklore,
        displayName: "Grimmory",
        iconSystemName: "book.closed.fill",
        iconColor: "purple",
        supportsUsernamePassword: true,
        supportsToken: true,
        supportsOIDC: true,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "https://grimmory.example.com",
        credentialLabels: .init()
    )

    static let komga = ConnectionCapability(
        providerType: .komga,
        displayName: "Komga",
        iconSystemName: "book.fill",
        iconColor: "teal",
        supportsUsernamePassword: true,
        supportsToken: true,
        supportsOIDC: true,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        credentialsOptional: true,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "https://komga.example.com",
        credentialLabels: .init()
    )

    static let kavita = ConnectionCapability(
        providerType: .kavita,
        displayName: "Kavita",
        iconSystemName: "book.fill",
        iconColor: "mint",
        supportsUsernamePassword: true,
        supportsToken: true,
        supportsOIDC: false,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "https://kavita.example.com",
        credentialLabels: .init()
    )

    static let opds = ConnectionCapability(
        providerType: .opds,
        displayName: "OPDS",
        iconSystemName: "globe",
        iconColor: "brown",
        supportsUsernamePassword: true,
        supportsToken: true,
        supportsOIDC: false,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        credentialsOptional: true,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "https://opds.example.com/feed",
        credentialLabels: .init()
    )

    static let bookOrbit = ConnectionCapability(
        providerType: .bookOrbit,
        displayName: "BookOrbit",
        iconSystemName: "circle.hexagongrid.fill",
        iconColor: "blue",
        supportsUsernamePassword: true,
        supportsToken: false,
        supportsOIDC: true,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: false,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "https://bookorbit.example.com",
        credentialLabels: .init(usernamePlaceholder: "Username or Email")
    )

    static let silo = ConnectionCapability(
        providerType: .silo,
        displayName: "Silo",
        iconSystemName: "server.rack",
        iconColor: "orange",
        supportsUsernamePassword: true,
        supportsToken: true,
        supportsOIDC: false,
        supportsQuickConnect: false,
        supportsWebLogin: false,
        supportsBrowserSignIn: true,
        supportsCustomHeaders: true,
        supportsServiceTokens: true,
        supportsMTLS: true,
        supportsLibrarySelection: true,
        supportsWebDAVPresets: false,
        serverURLPlaceholder: "https://silo.example.com",
        credentialLabels: .init(usernamePlaceholder: "Username or Email", tokenPlaceholder: "Access Token or API Key")
    )

    static func capability(for type: ProviderType) -> ConnectionCapability? {
        switch type {
        case .emby: return .emby
        case .jellyfin: return .jellyfin
        case .audiobookshelf: return .audiobookshelf
        case .storyteller: return .storyteller
        case .webdav: return .webdav
        case .torbox: return .torbox
        case .booklore: return .booklore
        case .komga: return .komga
        case .kavita: return .kavita
        case .opds: return .opds
        case .bookOrbit: return .bookOrbit
        case .silo: return .silo
        case .plex, .premiumize, .realdebrid, .local:
            return nil
        }
    }
}
