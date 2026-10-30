import Foundation

struct LibraryRefreshFailure: Equatable {
    let providerId: UUID
    let libraryId: String?
    let statusCode: Int?

    init(providerId: UUID, libraryId: String?, error: any Error) {
        self.providerId = providerId
        self.libraryId = libraryId
        if let error = error as? JellyfinResponseError {
            statusCode = (100...599).contains(error.statusCode) ? error.statusCode : nil
        } else if case ProviderError.unauthorized = error {
            statusCode = 401
        } else {
            statusCode = nil
        }
    }

    var message: String {
        let status = statusCode.map { " (HTTP \($0))" } ?? ""
        return "Couldn't refresh this Jellyfin library\(status). Please try again."
    }

    func matches(_ source: LibrarySourceFilter) -> Bool {
        switch source {
        case .all: true
        case .device: false
        case let .connection(id): providerId == id
        case let .library(id, selectedLibraryId):
            providerId == id && (libraryId == nil || libraryId == selectedLibraryId)
        }
    }
}
