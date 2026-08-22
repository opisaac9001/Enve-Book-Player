import Foundation

struct OfflineBookMetadata: Codable {
    let id: String
    let stableId: String
    let title: String
    let author: String?
    let narrator: String?
    let duration: TimeInterval?
    let chapters: [Chapter]?
    let audioTracks: [AudioTrack]?
    let coverURLString: String?
    let source: Book.BookSource

    var coverURL: URL? {
        guard let s = coverURLString else { return nil }
        return URL(string: s)
    }
}
