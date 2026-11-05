import Foundation

enum LinkedBookPassageError: LocalizedError, Equatable {
    case downloadRequired
    case unavailable(PassageUnavailableReason)
    case noMatch

    var errorDescription: String? {
        switch self {
        case .downloadRequired:
            return "Download the audiobook and linked ebook before finding a passage."
        case .unavailable(let reason):
            return reason.message
        case .noMatch:
            return "No confident, unique match was found. Your position has not changed. Try a nearby passage with more spoken words."
        }
    }
}

/// Listening→reading handoff through the shared passage mappings: a prepared passage resolves immediately,
/// otherwise the passage around the live playhead is prepared within the on-demand budget.
@MainActor
enum LinkedBookPassageService {
    static func find(ebook: Book, audiobook: Book, profileSession: ProfileSession, playhead: @escaping @MainActor () -> TimeInterval) async throws -> PassageMapping {
        let passages = profileSession.passageAlignment
        let resolution = await passages.findReadingPosition(ebook: ebook, audiobook: audiobook, playhead: playhead)
        try Task.checkCancellation()
        if let mapping = resolution.handoffMapping { return mapping }
        switch passages.capability(ebook: ebook, audiobook: audiobook) {
        case .failure(.missingMedia):
            throw LinkedBookPassageError.downloadRequired
        case .failure(let reason) where resolution == .unprepared:
            throw LinkedBookPassageError.unavailable(reason)
        default:
            throw LinkedBookPassageError.noMatch
        }
    }
}
