import Testing

@testable import enve

@MainActor
struct ReaderEnginePolicyTests {
    @Test func grimmoryAndSiloPreferFoliateForOrdinaryEPUBs() {
        for source in [Book.BookSource.booklore, .silo] {
            let selection = ReaderEnginePolicy.selection(
                for: .init(
                    source: source,
                    isReflowableEPUB: true,
                    isReadAloud: false,
                    hasMediaOverlay: false,
                    isFixedLayout: false
                ),
                foliateAvailable: true
            )

            #expect(selection.preferred == .foliate)
            #expect(selection.active == .foliate)
            #expect(selection.fallbackReason == nil)
        }
    }

    @Test func unavailableFoliateFallsBackToReadiumWithoutChangingPreference() {
        let selection = ReaderEnginePolicy.selection(
            for: .init(
                source: .booklore,
                isReflowableEPUB: true,
                isReadAloud: false,
                hasMediaOverlay: false,
                isFixedLayout: false
            ),
            foliateAvailable: false
        )

        #expect(selection.preferred == .foliate)
        #expect(selection.active == .readium)
        #expect(selection.fallbackReason == .foliateUnavailable)
    }

    @Test func readAloudAndMediaOverlayAlwaysUseReadium() {
        for context in [
            ReaderEnginePolicy.Context(
                source: .booklore,
                isReflowableEPUB: true,
                isReadAloud: true,
                hasMediaOverlay: false,
                isFixedLayout: false
            ),
            ReaderEnginePolicy.Context(
                source: .silo,
                isReflowableEPUB: true,
                isReadAloud: false,
                hasMediaOverlay: true,
                isFixedLayout: false
            ),
            ReaderEnginePolicy.Context(
                source: .storyteller,
                isReflowableEPUB: true,
                isReadAloud: false,
                hasMediaOverlay: false,
                isFixedLayout: false
            ),
        ] {
            let selection = ReaderEnginePolicy.selection(
                for: context,
                override: .foliate,
                foliateAvailable: true
            )
            #expect(selection.preferred == .readium)
            #expect(selection.active == .readium)
            #expect(selection.fallbackReason == .readiumRequired)
        }
    }

    @Test func overrideCanSelectFoliateForAnotherOrdinaryEPUBSource() {
        let selection = ReaderEnginePolicy.selection(
            for: .init(
                source: .local,
                isReflowableEPUB: true,
                isReadAloud: false,
                hasMediaOverlay: false,
                isFixedLayout: false
            ),
            override: .foliate,
            foliateAvailable: true
        )

        #expect(selection.active == .foliate)
    }
}
