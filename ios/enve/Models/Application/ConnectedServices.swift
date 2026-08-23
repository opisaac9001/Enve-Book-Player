import Foundation

struct ConnectedServices: Codable {
    var plex: Bool = false
    var audiobookshelf: Bool = false
    var jellyfin: Bool = false
    var localFolderAccess: Bool = false

    private enum CodingKeys: String, CodingKey {
        case plex
        case audiobookshelf
        case jellyfin
        case localFolderAccess
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        plex = try container.decodeIfPresent(Bool.self, forKey: .plex) ?? false
        audiobookshelf = try container.decodeIfPresent(Bool.self, forKey: .audiobookshelf) ?? false
        jellyfin = try container.decodeIfPresent(Bool.self, forKey: .jellyfin) ?? false
        localFolderAccess = try container.decodeIfPresent(Bool.self, forKey: .localFolderAccess) ?? false
    }

    var hasAnyConnection: Bool {
        return plex || audiobookshelf || jellyfin || localFolderAccess
    }

    var connectionCount: Int {
        var count = 0
        if plex { count += 1 }
        if audiobookshelf { count += 1 }
        if jellyfin { count += 1 }
        if localFolderAccess { count += 1 }
        return count
    }
}
