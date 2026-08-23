import Foundation
import Logging

struct PlexServer: Codable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let local: Bool
    let httpsRequired: Bool
    let owned: Bool
    let synced: Bool
    let accessToken: String
    let connections: [PlexConnection]

    @available(
        *,
        deprecated,
        message: "Use PlexService.findBestConnection() for network requests. This property does not verify reachability."
    )
    var preferredURL: URL? {

        if let localHttps = connections.first(where: { $0.local && $0.uri.starts(with: "https://") }) {
            AppLogger.network.info("Using local HTTPS connection")
            return URL(string: localHttps.uri)
        }

        if let localHttp = connections.first(where: { $0.local && $0.uri.starts(with: "http://") }) {
            AppLogger.network.info("Using local HTTP connection")
            return URL(string: localHttp.uri)
        }

        if let plexDirect = connections.first(where: {
            $0.uri.contains("plex.direct") && $0.uri.starts(with: "https://")
        }) {
            AppLogger.network.info("Using remote plex.direct connection")
            return URL(string: plexDirect.uri)
        }

        if let anyHttps = connections.first(where: { $0.uri.starts(with: "https://") }) {
            AppLogger.network.info("Using HTTPS connection")
            return URL(string: anyHttps.uri)
        }

        if let firstConnection = connections.first {
            AppLogger.network.warning("Using fallback connection")
            return URL(string: firstConnection.uri)
        }

        return URL(string: uri)
    }

    @available(
        *,
        deprecated,
        message: "Use PlexService.findBestConnection() for network requests. This property does not verify reachability."
    )
    var localURL: URL? {
        if let local = connections.first(where: { $0.local }) {
            return URL(string: local.uri)
        }
        return nil
    }

    @available(
        *,
        deprecated,
        message: "Use PlexService.findBestConnection() for network requests. This property does not verify reachability."
    )
    var plexDirectURL: URL? {
        if let plexDirect = connections.first(where: { $0.isPlexDirect }) {
            return URL(string: plexDirect.uri)
        }
        return nil
    }

    @available(
        *,
        deprecated,
        message: "Use PlexService.findBestConnection() for network requests. This property does not verify reachability."
    )
    var preferredURLString: String? {
        return preferredURL?.absoluteString
    }
}

struct PlexConnection: Codable {
    let uri: String
    let local: Bool
    let `protocol`: String?
    let address: String?
    let port: Int?
    let relay: Bool?

    var isSecure: Bool {
        return uri.starts(with: "https://") || `protocol` == "https"
    }

    var isPlexDirect: Bool {
        return uri.contains("plex.direct")
    }

    var isRelay: Bool {
        return relay == true
    }
}
