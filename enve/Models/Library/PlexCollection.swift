import Foundation

struct PlexCollection: Identifiable, Codable, Equatable {
    let id: String
    let ratingKey: String
    let title: String
    let summary: String?
    let thumb: String?
    let itemCount: Int?
    let sectionKey: String?
    let serverUrl: String?
    let token: String?

    var coverURL: URL? {
        guard let thumb else { return nil }

        if let url = URL(string: thumb), url.scheme != nil {
            return url
        }

        guard let serverUrl, let token else { return nil }

        let baseUrl = serverUrl.hasSuffix("/") ? String(serverUrl.dropLast()) : serverUrl
        let path = thumb.hasPrefix("/") ? thumb : "/\(thumb)"
        let urlString = "\(baseUrl)\(path)?X-Plex-Token=\(token)"
        return URL(string: urlString)
    }
}
