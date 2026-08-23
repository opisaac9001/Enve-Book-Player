import Foundation
import SwiftData

@Model
final class LibrarySyncCursor {

    var providerId: String = ""
    var libraryId: String = ""

    var lastSyncedAt: Date = Date.distantPast

    var lastFullReconciledAt: Date = Date.distantPast

    init() {}

    init(providerId: String, libraryId: String, lastSyncedAt: Date, lastFullReconciledAt: Date) {
        self.providerId = providerId
        self.libraryId = libraryId
        self.lastSyncedAt = lastSyncedAt
        self.lastFullReconciledAt = lastFullReconciledAt
    }
}

struct LibrarySyncCursorSnapshot: Sendable {
    let providerId: String
    let libraryId: String
    let lastSyncedAt: Date
    let lastFullReconciledAt: Date
}
