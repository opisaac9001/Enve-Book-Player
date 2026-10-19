import AVFoundation
import Foundation
import Testing

@testable import enve

@Suite(.serialized) @MainActor
struct AnchoredAVTTSEngineTests {
    // The long pre-utterance delay keeps the synthesizer from finishing on its own during the test.
    private static let slice = SpokenTextSlice(original: "The narrator keeps reading this sentence.")
    private static let delay: TimeInterval = 30

    private final class Completion {
        var isFinished = false
    }

    @Test func staleCallbacksAfterCancelDoNotFinishTheNextUtterance() async throws {
        let engine = AnchoredAVTTSEngine(rate: 1, anchor: EbookTTSStartAnchor())
        let first = Task { await engine.speak(Self.slice, voice: nil, delay: Self.delay) { _ in } }
        try await Task.sleep(for: .milliseconds(100))
        first.cancel()
        _ = await first.value

        let completion = Completion()
        let second = Task {
            let result = await engine.speak(Self.slice, voice: nil, delay: Self.delay) { _ in }
            completion.isFinished = true
            return result
        }
        try await Task.sleep(for: .milliseconds(100))

        await Task.detached {
            let stale = AVSpeechUtterance(string: "stale")
            let synthesizer = AVSpeechSynthesizer()
            engine.speechSynthesizer(synthesizer, willSpeakRangeOfSpeechString: NSRange(location: 0, length: 3), utterance: stale)
            engine.speechSynthesizer(synthesizer, didCancel: stale)
            engine.speechSynthesizer(synthesizer, didFinish: stale)
        }.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(!completion.isFinished)

        second.cancel()
        _ = await second.value
        #expect(completion.isFinished)
    }

    @Test func speakingAgainResolvesTheSupersededUtterance() async throws {
        let engine = AnchoredAVTTSEngine(rate: 1, anchor: EbookTTSStartAnchor())
        let first = Task { await engine.speak(Self.slice, voice: nil, delay: Self.delay) { _ in } }
        try await Task.sleep(for: .milliseconds(100))

        let completion = Completion()
        let second = Task {
            let result = await engine.speak(Self.slice, voice: nil, delay: Self.delay) { _ in }
            completion.isFinished = true
            return result
        }
        _ = await first.value
        #expect(!completion.isFinished)

        second.cancel()
        _ = await second.value
        #expect(completion.isFinished)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity, 0, 0.5, 1, 3, 10])
    func appleSpeechRateStaysWithinTheSynthesizerRange(rate: Float) {
        let mapped = AnchoredAVTTSEngine.appleSpeechRate(for: rate)
        #expect(mapped >= AVSpeechUtteranceMinimumSpeechRate)
        #expect(mapped <= AVSpeechUtteranceMaximumSpeechRate)
    }
}
