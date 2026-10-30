import Combine
import Foundation
@preconcurrency import ReadiumNavigator
@preconcurrency import ReadiumShared
import Testing

@testable import enve

@Suite(.serialized) @MainActor
struct EbookTTSServicePlaybackTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_KOKORO_READER_VERIFY"] == "1"))
    func kokoroResumesWithANewVoiceAfterPausing() async throws {
        try #require(KokoroTTSRuntime.hasDownloadedVoices)
        let (service, defaults, suiteName) = try makeService()
        defer {
            service.tearDown()
            defaults.removePersistentDomain(forName: suiteName)
        }
        service.setEngineChoice(.kokoro)
        try await waitUntil(timeout: .seconds(30)) { service.engineChoice == .kokoro }
        var spokenRanges = 0
        let subscription = service.$highlightLocator.compactMap { $0 }.sink { _ in spokenRanges += 1 }
        defer { subscription.cancel() }
        service.configure(with: makePublication())
        service.startSpeaking()
        try await waitUntil(timeout: .seconds(30)) { spokenRanges > 0 }

        service.pause()
        service.setKokoroVoice(.michael)

        #expect(service.isPaused)
        #expect(!service.isPlaying)
        #expect(service.synthesizer?.state == .stopped)
        let previousRanges = spokenRanges
        service.resume()
        try await waitUntil(timeout: .seconds(30)) { spokenRanges > previousRanges }
        #expect(service.isPlaying)
        #expect(service.currentVoiceDisplayName == "Kokoro · Michael")
    }

    @Test func changingLanguageWhilePausedKeepsNarrationPaused() async throws {
        let (service, defaults, suiteName) = try makeService()
        defer {
            service.tearDown()
            defaults.removePersistentDomain(forName: suiteName)
        }
        service.configure(with: makePublication())
        service.startSpeaking()
        try await waitUntil { !service.currentUtteranceText.isEmpty }
        service.pause()

        service.setPreferredLanguage("en")

        #expect(service.isPaused)
        #expect(!service.isPlaying)
        #expect(service.synthesizer?.state == .stopped)
        service.resume()
        try await waitUntil { service.highlightLocator != nil }
        #expect(service.isPlaying)
    }

    @Test func callbacksFromAReplacedSynthesizerDoNotChangePlayback() async throws {
        let (service, defaults, suiteName) = try makeService()
        defer {
            service.tearDown()
            defaults.removePersistentDomain(forName: suiteName)
        }
        let publication = makePublication()
        service.configure(with: publication)
        let previous = try #require(service.synthesizer)
        service.configure(with: publication)
        service.isPaused = true

        service.publicationSpeechSynthesizer(previous, stateDidChange: .stopped)
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.isPaused)
        #expect(!service.isPlaying)
    }

    @Test func changingLanguageBeforeFirstAudioPreservesTheRequestedPosition() async throws {
        let (service, defaults, suiteName) = try makeService()
        defer {
            service.tearDown()
            defaults.removePersistentDomain(forName: suiteName)
        }
        service.configure(with: makePublication())
        var interrupted = false
        let subscription = service.$currentUtteranceText.sink { text in
            guard !text.isEmpty, !interrupted else { return }
            interrupted = true
            service.pause()
            service.setPreferredLanguage("en")
        }
        defer { subscription.cancel() }
        let sentence = "The narrator resumes from the requested sentence."
        service.startSpeaking(from: Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            text: .init(highlight: sentence)
        ))
        try await waitUntil { interrupted && service.isPaused }

        service.resume()

        try await waitUntil { service.highlightLocator != nil }
        #expect(service.highlightLocator?.text.highlight == sentence)
    }

    @Test(arguments: [false, true])
    func pausingDuringContentLoadingCanResumeAtTheRequestedPosition(changeLanguage: Bool) async throws {
        let (service, defaults, suiteName) = try makeService()
        let gate = ContentGate()
        defer {
            service.tearDown()
            defaults.removePersistentDomain(forName: suiteName)
        }
        service.configure(with: makePublication(resource: DataResource(makeData: { @Sendable in
            await gate.read()
            return .success(Data(Self.html.utf8))
        })))
        let locator = Locator(
            href: AnyURL(string: "chapter.xhtml")!,
            mediaType: .xhtml,
            text: .init(highlight: "The narrator resumes from the requested sentence.")
        )
        service.startSpeaking(from: locator)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await gate.hasRequestedContent), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let requested = await gate.hasRequestedContent
        service.pause()
        if changeLanguage { service.setPreferredLanguage("en") }
        await gate.release()
        try #require(requested)
        try await Task.sleep(for: .milliseconds(100))

        #expect(service.isPaused)
        #expect(!service.isPlaying)
        service.resume()
        try await waitUntil { service.highlightLocator != nil }
        #expect(service.isPlaying)
        #expect(service.currentUtteranceText.contains("The narrator resumes"))
        #expect(service.highlightLocator?.text.highlight == "The narrator resumes from the requested sentence.")
    }

    private nonisolated static let html = """
        <html xmlns="http://www.w3.org/1999/xhtml" lang="en"><body>
        <p>Skip this opening sentence. The narrator resumes from the requested sentence.
        The rest of the paragraph keeps playing while the reader follows the words.</p>
        </body></html>
        """

    private func makeService() throws -> (EbookTTSService, UserDefaults, String) {
        let name = "EbookTTSServicePlaybackTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (EbookTTSService(userDefaults: defaults), defaults, name)
    }

    private func makePublication(resource: (any Resource)? = nil) -> Publication {
        let href = AnyURL(string: "chapter.xhtml")!
        var services = PublicationServicesBuilder()
        services.setContentServiceFactory(DefaultContentService.makeFactory(
            resourceContentIteratorFactories: [HTMLResourceContentIterator.Factory()]
        ))
        return Publication(
            manifest: Manifest(
                metadata: Metadata(title: "Narration regression", languages: ["en"]),
                readingOrder: [Link(href: href.string, mediaType: .xhtml)]
            ),
            container: SingleResourceContainer(resource: resource ?? DataResource(string: Self.html), at: href),
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

private actor ContentGate {
    private(set) var hasRequestedContent = false
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func read() async {
        hasRequestedContent = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
