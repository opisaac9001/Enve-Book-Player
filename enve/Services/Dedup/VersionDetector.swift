import Foundation

struct VersionDetector {
    private nonisolated static let productionPatterns: [(pattern: String, type: ProductionType)] = [
        ("graphic audio", .graphicAudio),
        ("graphicaudio", .graphicAudio),

        ("full cast", .multiCast),
        ("full-cast", .multiCast),
        ("multi-voice", .multiCast),
        ("multivoice", .multiCast),

        ("dramatized", .dramatized),
        ("dramatised", .dramatized),
        ("audio drama", .audioDrama),
        ("radio adaptation", .radioDrama),
        ("radio play", .radioDrama),
        ("bbc radio", .radioDrama),
    ]

    nonisolated static func detectProductionType(from book: Book) -> ProductionType {
        let fields: [String?] = [
            book.title,
            book.narrator,
            book.publisher,
            book.description,
        ]

        for field in fields {
            guard let text = field?.lowercased() else { continue }
            for (pattern, type) in productionPatterns {
                if text.contains(pattern) {
                    return type
                }
            }
        }

        return .standard
    }

    nonisolated static func detectAbridgedState(from book: Book) -> AbridgedState {
        let fields: [String?] = [
            book.title,
            book.description,
            book.publisher,
        ]

        for field in fields {
            guard let text = field?.lowercased() else { continue }
            if text.contains("unabridged") { return .unabridged }
            if text.contains("abridged") { return .abridged }
        }

        return .unknown
    }
}
