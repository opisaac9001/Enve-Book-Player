import Foundation

struct EPUB3Features: Codable, Sendable {

    var hasMediaOverlay: Bool = false

    var hasFixedLayout: Bool = false

    var smilFileCount: Int = 0

    var estimatedAudioDuration: TimeInterval?
}

extension EPUB3Features: Equatable {
    nonisolated static func == (lhs: EPUB3Features, rhs: EPUB3Features) -> Bool {
        lhs.hasMediaOverlay == rhs.hasMediaOverlay && lhs.hasFixedLayout == rhs.hasFixedLayout && lhs.smilFileCount == rhs.smilFileCount
            && lhs.estimatedAudioDuration == rhs.estimatedAudioDuration
    }
}
