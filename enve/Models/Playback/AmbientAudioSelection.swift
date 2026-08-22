import Foundation

struct AmbientAudioSelection: Codable, Equatable, Sendable {
    let bookId: String
    let displayName: String
    let bookmarkData: Data?
    let presetId: String?
    var volume: Double
    let createdAt: Date

    init(
        bookId: String,
        displayName: String,
        bookmarkData: Data? = nil,
        presetId: String? = nil,
        volume: Double = 0.35,
        createdAt: Date = Date()
    ) {
        self.bookId = bookId
        self.displayName = displayName
        self.bookmarkData = bookmarkData
        self.presetId = presetId
        self.volume = volume
        self.createdAt = createdAt
    }
}
