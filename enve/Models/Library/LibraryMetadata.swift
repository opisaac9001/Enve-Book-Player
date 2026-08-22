import Foundation

struct LibraryMetadata: Identifiable, Codable, Sendable, Equatable {
    let id: String
    let name: String
    let type: LibraryType
    let itemCount: Int
    let audioBookCount: Int
    let collectionType: String?

    var hasAudiobooks: Bool {
        audioBookCount > 0
    }
}

enum LibraryType: String, Codable, Sendable {
    case audiobooks = "audiobooks"
    case movies = "movies"
    case tvshows = "tvshows"
    case music = "music"
    case mixed = "mixed"
    case books = "books"
    case unknown = "unknown"

    var icon: String {
        switch self {
        case .audiobooks, .books:
            return "book.fill"
        case .movies:
            return "film.fill"
        case .tvshows:
            return "tv.fill"
        case .music:
            return "music.note"
        case .mixed:
            return "square.stack.3d.up.fill"
        case .unknown:
            return "folder.fill"
        }
    }

    var displayName: String {
        switch self {
        case .audiobooks:
            return "Audiobooks"
        case .movies:
            return "Movies"
        case .tvshows:
            return "TV Shows"
        case .music:
            return "Music"
        case .mixed:
            return "Mixed Media"
        case .books:
            return "Books"
        case .unknown:
            return "Unknown"
        }
    }
}

func determineLibraryType(from collectionType: String?) -> LibraryType {
    guard let collectionType = collectionType?.lowercased() else {
        return .unknown
    }

    if collectionType == "audiobooks" {
        return .audiobooks
    } else if collectionType == "books" {
        return .books
    } else if collectionType == "movies" {
        return .movies
    } else if collectionType == "tvshows" {
        return .tvshows
    } else if collectionType == "music" {
        return .music
    } else if collectionType == "mixed" {
        return .mixed
    }

    return .unknown
}
