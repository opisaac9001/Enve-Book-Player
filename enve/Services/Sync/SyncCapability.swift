import Foundation

struct SyncCapability: OptionSet, Sendable {
    let rawValue: UInt

    static let pullProgress = SyncCapability(rawValue: 1 << 0)
    static let pushProgress = SyncCapability(rawValue: 1 << 1)
    static let pullAnnotations = SyncCapability(rawValue: 1 << 2)
    static let pushAnnotations = SyncCapability(rawValue: 1 << 3)
    static let markFinished = SyncCapability(rawValue: 1 << 4)

    static let none: SyncCapability = []
    static let readWrite: SyncCapability = [.pullProgress, .pushProgress]
    static let full: SyncCapability = [.pullProgress, .pushProgress, .pullAnnotations, .pushAnnotations, .markFinished]
}

extension LibraryProvider {
    var syncCapability: SyncCapability {
        switch connection.type {
        case .audiobookshelf, .jellyfin, .emby, .bookOrbit:
            return [.pullProgress, .pushProgress, .markFinished]
        case .silo:
            return [.pullProgress, .pushProgress, .pullAnnotations, .pushAnnotations, .markFinished]
        case .plex:
            return [.pullProgress, .pushProgress, .markFinished]
        case .booklore:
            return [.pullProgress, .pushProgress, .pullAnnotations, .pushAnnotations, .markFinished]
        case .komga, .kavita:
            return [.pullProgress, .pushProgress]
        case .storyteller:
            return [.pullProgress, .pushProgress]
        case .opds, .webdav, .premiumize, .realdebrid, .local, .torbox:
            return .none
        }
    }
}
