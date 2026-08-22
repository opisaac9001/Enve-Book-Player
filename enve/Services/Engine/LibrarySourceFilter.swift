import Foundation

enum LibrarySourceFilter: Hashable {
    case all
    case device
    case connection(UUID)
    case library(providerId: UUID, libraryId: String)

    var rawValue: String {
        switch self {
        case .all:
            return "all"
        case .device:
            return "device"
        case .connection(let id):
            return id.uuidString
        case .library(let providerId, let libraryId):
            let escaped = libraryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? libraryId
            return "library:\(providerId.uuidString):\(escaped)"
        }
    }

    init(rawValue: String) {
        if rawValue.hasPrefix("library:") {
            let parts = rawValue.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3, let providerId = UUID(uuidString: parts[1]) {
                let libraryId = parts[2].removingPercentEncoding ?? parts[2]
                self = .library(providerId: providerId, libraryId: libraryId)
                return
            }
        }
        if rawValue == "all" || rawValue.isEmpty {
            self = .all
        } else if rawValue == "device" {
            self = .device
        } else if let id = UUID(uuidString: rawValue) {
            self = .connection(id)
        } else {
            self = .all
        }
    }

    var providerId: UUID? {
        switch self {
        case .connection(let id), .library(let id, _): id
        case .all, .device: nil
        }
    }

    var libraryId: String? {
        if case .library(_, let libraryId) = self { libraryId } else { nil }
    }
}
