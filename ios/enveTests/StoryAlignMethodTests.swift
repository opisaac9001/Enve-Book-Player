import Foundation
import Testing
import StoryAlignCore

@testable import enve

@MainActor
struct StoryAlignMethodTests {
    @Test func manualPauseRetainsThePairAndCheckpointUntilDiscarded() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let service = StoryAlignService(libraryCache: fixture.session.appState.libraryCache,
                                        bookRepository: fixture.session.bookStore, profileSession: fixture.session)
        let checkpoint = fixture.root.appendingPathComponent("saved-analysis.plist")
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        try Data("completed window".utf8).write(to: checkpoint)
        service.activeConversion = .init(ebookStableId: "ebook", audiobookStableId: "audio", method: .quartzNet,
                                         stage: "Aligning Narration", progress: 0.5, detailText: nil, startedAt: Date())
        service.pauseConversion()
        #expect(service.activeConversion == nil)
        #expect(service.pausedConversion?.ebookStableId == "ebook")
        #expect(service.pausedConversion?.audiobookStableId == "audio")
        #expect(service.pausedConversion?.method == .quartzNet)
        #expect(service.pausedConversion?.reason == "Paused by you.")
        #expect(try Data(contentsOf: checkpoint) == Data("completed window".utf8))
        service.loadPausedConversion()
        #expect(service.pausedConversion?.ebookStableId == "ebook")
        service.cancelConversion()
        service.loadPausedConversion()
        #expect(service.pausedConversion == nil)
        await service.retire()
        await fixture.close()
    }

    @Test func legacyPausedConversionKeepsAppleEngine() throws {
        let data = Data(#"{"ebookStableId":"ebook","audiobookStableId":"audio"}"#.utf8)
        let paused = try JSONDecoder().decode(StoryAlignService.PausedConversion.self, from: data)
        #expect(paused.method == .appleSpeech)
        #expect(paused.ebookStableId == "ebook")
        #expect(paused.audiobookStableId == "audio")
    }

    @Test func checkpointRetainsEngineAndPauseReason() throws {
        let saved = StoryAlignService.PausedConversion(
            ebookStableId: "ebook", audiobookStableId: "audio", method: .quartzNet,
            reason: "Device needs to cool down."
        )
        let data = try JSONEncoder().encode(saved)
        let restored = try JSONDecoder().decode(StoryAlignService.PausedConversion.self, from: data)
        #expect(restored.method == .quartzNet)
        #expect(restored.reason == saved.reason)
    }

    @Test func unknownCheckpointEngineIsNotReinterpreted() {
        let data = Data(#"{"ebookStableId":"ebook","audiobookStableId":"audio","method":"future-engine"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StoryAlignService.PausedConversion.self, from: data)
        }
    }

    @Test func englishMetadataVariantsAreAccepted() {
        for language in ["en", "en-US", "en_GB", "ENG", "English", "und"] {
            #expect(StoryAlignMethod.quartzNet.supports(language: language))
        }
        #expect(StoryAlignMethod.quartzNet.supports(language: nil))
        #expect(!StoryAlignMethod.quartzNet.supports(language: "fr-FR"))
        #expect(!StoryAlignMethod.quartzNet.supports(language: "de"))
        #expect(StoryAlignMethod.appleSpeech.supports(language: "fr-FR"))
    }
    @Test func lowerCoverageCannotReplaceAnAcceptedBook() throws {
        let incumbent = try quality(accepted: 95, eligible: 100, audio: 0.90)
        #expect(!StoryAlignService.canReplace(candidate: try quality(accepted: 80, eligible: 100, audio: 0.90), incumbent: incumbent))
        #expect(!StoryAlignService.canReplace(candidate: try quality(accepted: 95, eligible: 100, audio: 0.60), incumbent: incumbent))
        #expect(StoryAlignService.canReplace(candidate: try quality(accepted: 98, eligible: 100, audio: 0.92), incumbent: incumbent))
    }

    private func quality(accepted: Int, eligible: Int, audio: Double) throws -> CTCAlignmentQuality {
        let data = Data("{\"acceptedSentenceCount\":\(accepted),\"eligibleSentenceCount\":\(eligible),\"audioCoverage\":\(audio)}".utf8)
        return try JSONDecoder().decode(CTCAlignmentQuality.self, from: data)
    }

}
