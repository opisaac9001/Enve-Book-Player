import Foundation

enum ReaderEngineKind: String, Codable, Sendable {
    case readium
    case foliate
}

struct ReaderEngineSelection: Equatable, Sendable {
    enum FallbackReason: Equatable, Sendable {
        case foliateUnavailable
        case readiumRequired
    }

    let preferred: ReaderEngineKind
    let active: ReaderEngineKind
    let fallbackReason: FallbackReason?
}

enum ReaderEnginePolicy {
    struct Context: Equatable, Sendable {
        let source: Book.BookSource
        let isReflowableEPUB: Bool
        let isReadAloud: Bool
        let hasMediaOverlay: Bool
        let isFixedLayout: Bool
    }

    static func selection(
        for context: Context,
        override: ReaderEngineKind? = nil,
        foliateAvailable: Bool
    ) -> ReaderEngineSelection {
        guard context.isReflowableEPUB,
            !context.isReadAloud,
            !context.hasMediaOverlay,
            !context.isFixedLayout,
            context.source != .storyteller
        else {
            return ReaderEngineSelection(
                preferred: .readium,
                active: .readium,
                fallbackReason: override == .foliate ? .readiumRequired : nil
            )
        }

        let preferred = override ?? automaticEngine(for: context.source)
        guard preferred == .foliate else {
            return ReaderEngineSelection(preferred: .readium, active: .readium, fallbackReason: nil)
        }
        guard foliateAvailable else {
            return ReaderEngineSelection(
                preferred: .foliate,
                active: .readium,
                fallbackReason: .foliateUnavailable
            )
        }
        return ReaderEngineSelection(preferred: .foliate, active: .foliate, fallbackReason: nil)
    }

    private static func automaticEngine(for source: Book.BookSource) -> ReaderEngineKind {
        switch source {
        case .booklore, .silo:
            return .foliate
        default:
            return .readium
        }
    }
}
