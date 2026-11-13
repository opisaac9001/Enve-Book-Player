import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import Testing

@testable import enve

@Suite(.serialized, .enabled(if: !EbookTTSEngineChoice.downloadableCases.isEmpty)) @MainActor
struct NarratorVoicePreviewTests {
    @Test func rapidTapsOnlySynthesizeTheLastSampleAndStopCancelsIt() async throws {
        let (store, _, cleanup) = try makeStore(installed: [.kokoro])
        defer { cleanup() }
        let speaker = FakePreviewSpeaker()
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)

        preview.play(.apple(voiceIdentifier: nil, language: "en"), rate: 1)
        preview.play(.kokoro(.heart), rate: 1)
        preview.play(.kokoro(.bella), rate: 1)

        try await waitUntil { preview.phase == .playing(.kokoro(.bella)) }
        #expect(speaker.spoken == [.kokoro(.bella)])
        preview.stop()
        #expect(preview.phase == .idle)
        try await waitUntil { speaker.cancelled == [.kokoro(.bella)] }
    }

    @Test func replacingAPlayingSampleCancelsItWithoutRestoringItsState() async throws {
        let (store, _, cleanup) = try makeStore(installed: [.kokoro])
        defer { cleanup() }
        let speaker = FakePreviewSpeaker()
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)
        preview.play(.kokoro(.heart), rate: 1)
        try await waitUntil { preview.phase == .playing(.kokoro(.heart)) }

        preview.play(.kokoro(.michael), rate: 1.5)

        #expect(preview.phase == .preparing(.kokoro(.michael)))
        try await waitUntil { preview.phase == .playing(.kokoro(.michael)) }
        #expect(speaker.cancelled == [.kokoro(.heart)])
        #expect(speaker.rates.last == 1.5)
    }

    @Test func aSampleOfAMissingModelFailsWithoutDownloading() async throws {
        let (store, runtime, cleanup) = try makeStore()
        defer { cleanup() }
        let speaker = FakePreviewSpeaker()
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)

        preview.play(.supertonic(.f1, language: "en"), rate: 1)

        #expect(preview.phase == .failed(.supertonic(.f1, language: "en"), "Download Supertonic 3 to hear a sample."))
        try await Task.sleep(for: .milliseconds(250))
        #expect(speaker.spoken.isEmpty)
        #expect(store.state(for: .supertonic3) == .notDownloaded)
        #expect(!runtime.events.contains { $0.hasPrefix("prepare") })
    }

    @Test func aSampleWhoseModelFilesWerePurgedFailsInsteadOfRefetchingThem() async throws {
        let (store, runtime, cleanup) = try makeStore(installed: [.kokoro])
        defer { cleanup() }
        runtime.installed.remove(.kokoro)
        let speaker = FakePreviewSpeaker()
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)

        preview.play(.kokoro(.heart), rate: 1)

        #expect(preview.phase == .failed(.kokoro(.heart), "Download Kokoro to hear a sample."))
        try await Task.sleep(for: .milliseconds(250))
        #expect(speaker.spoken.isEmpty)
        #expect(!runtime.events.contains { $0.hasPrefix("prepare") })
    }

    @Test func aNeuralEngineFailureIsReportedInsteadOfPlayingAnAppleVoice() async throws {
        let (store, _, cleanup) = try makeStore(installed: [.pocket])
        defer { cleanup() }
        let speaker = FakePreviewSpeaker()
        speaker.failure = NeuralTTSError.invalidAudio
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)

        preview.play(.pocket, rate: 1)

        try await waitUntil { preview.phase == .failed(.pocket, NeuralTTSError.invalidAudio.localizedDescription) }
        #expect(speaker.spoken == [.pocket])
    }

    @Test func removingTheSampledModelStopsThePreview() async throws {
        let (store, _, cleanup) = try makeStore(installed: [.kokoro])
        defer { cleanup() }
        let speaker = FakePreviewSpeaker()
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)
        preview.play(.kokoro(.puck), rate: 1)
        try await waitUntil { preview.phase == .playing(.kokoro(.puck)) }

        store.remove(.kokoro)

        #expect(preview.phase == .idle)
        try await waitUntil { speaker.cancelled == [.kokoro(.puck)] }
    }

    @Test func removingAnotherModelKeepsTheSamplePlayingAndResident() async throws {
        let (store, runtime, cleanup) = try makeStore(installed: [.kokoro, .pocket])
        defer { cleanup() }
        let speaker = FakePreviewSpeaker()
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)
        defer { preview.invalidate() }
        preview.play(.kokoro(.heart), rate: 1)
        try await waitUntil { preview.phase == .playing(.kokoro(.heart)) }
        runtime.events.removeAll()

        store.remove(.pocket)
        try await waitUntil { store.state(for: .pocket) == .notDownloaded }
        try await Task.sleep(for: .milliseconds(50))

        #expect(preview.phase == .playing(.kokoro(.heart)))
        #expect(!runtime.events.contains("unload kokoro"))
        #expect(speaker.cancelled.isEmpty)
    }

    @Test func aCompletedSampleReleasesItsRuntimeWithoutClosingThePicker() async throws {
        let (store, runtime, cleanup) = try makeStore(installed: [.kokoro])
        defer { cleanup() }
        let speaker = FakePreviewSpeaker()
        speaker.holds = false
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)

        preview.play(.kokoro(.heart), rate: 1)

        try await waitUntil { speaker.spoken.count == 1 && preview.phase == .idle }
        try await waitUntil { runtime.events.contains("unload kokoro") }
    }

    @Test func dismissingThePreviewReleasesAModelLoadedOnlyForSamples() async throws {
        let (store, runtime, cleanup) = try makeStore(installed: [.supertonic3])
        defer { cleanup() }
        let speaker = FakePreviewSpeaker()
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)
        preview.play(.supertonic(.m2, language: "es"), rate: 1)
        try await waitUntil { preview.phase == .playing(.supertonic(.m2, language: "es")) }
        #expect(!runtime.events.contains("unload supertonic3"))

        preview.invalidate()

        try await waitUntil { runtime.events.contains("unload supertonic3") }
        #expect(preview.phase == .idle)
    }

    @Test func aSamplePausesNarrationAndLeavesTheBookUntouched() async throws {
        let (store, _, cleanup) = try makeStore()
        defer { cleanup() }
        let name = "NarratorVoicePreviewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = EbookTTSService(userDefaults: defaults, models: store)
        defer { service.tearDown() }
        service.configure(with: makePublication())
        service.startSpeaking()
        try await waitUntil { service.highlightLocator != nil }
        let synthesizer = try #require(service.synthesizer)
        let speaker = FakePreviewSpeaker()
        speaker.holds = false
        let preview = NarratorVoicePreview(models: store, runtime: speaker.runtime)

        preview.play(.apple(voiceIdentifier: nil, language: "en"), rate: service.rate, pausing: service)

        #expect(service.isPaused)
        #expect(!service.isPlaying)
        try await Task.sleep(for: .milliseconds(100))
        let highlight = service.highlightLocator
        try await waitUntil { speaker.spoken.count == 1 && preview.phase == .idle }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.isPaused)
        #expect(!service.isPlaying)
        #expect(service.synthesizer === synthesizer)
        #expect(service.highlightLocator == highlight)
        #expect(service.engineChoice == .apple)
        #expect(service.selectedVoiceIdentifier == nil)
        #expect(defaults.string(forKey: "ebookTTS.voiceIdentifier") == nil)
    }

    private func makeStore(installed: Set<EbookTTSEngineChoice> = []) throws -> (NarratorModelStore, FakeNarratorRuntime, () -> Void) {
        let name = "NarratorVoicePreviewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        for (engine, key) in [(EbookTTSEngineChoice.kokoro, "ebookTTS.kokoroModelReady"), (.supertonic3, "ebookTTS.enhancedModelReady"), (.pocket, "ebookTTS.pocketModelReady")] {
            defaults.set(installed.contains(engine), forKey: key)
        }
        let runtime = FakeNarratorRuntime(installed: installed)
        return (NarratorModelStore(defaults: defaults, runtime: runtime.runtime), runtime, { defaults.removePersistentDomain(forName: name) })
    }

    private func makePublication() -> Publication {
        let href = AnyURL(string: "chapter.xhtml")!
        var services = PublicationServicesBuilder()
        services.setContentServiceFactory(DefaultContentService.makeFactory(
            resourceContentIteratorFactories: [HTMLResourceContentIterator.Factory()]
        ))
        let html = """
            <html xmlns="http://www.w3.org/1999/xhtml" lang="en"><body>
            <p>The narrator keeps its place while a voice sample plays. Nothing else in the book moves.</p>
            </body></html>
            """
        return Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Preview isolation", languages: ["en"]),
                readingOrder: [Link(href: href.string, mediaType: .xhtml)]
            ),
            container: SingleResourceContainer(resource: DataResource(string: html), at: href),
            servicesBuilder: services
        )
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

@MainActor
private final class FakePreviewSpeaker {
    var holds = true
    var failure: Error?
    private(set) var spoken: [NarratorVoiceSample] = []
    private(set) var rates: [Float] = []
    private(set) var cancelled: [NarratorVoiceSample] = []

    var runtime: NarratorVoicePreview.Runtime {
        NarratorVoicePreview.Runtime(speak: { sample, rate, didStart in
            self.spoken.append(sample)
            self.rates.append(rate)
            if let failure = self.failure { throw failure }
            didStart()
            guard self.holds else { return }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                self.cancelled.append(sample)
                throw error
            }
        })
    }
}
