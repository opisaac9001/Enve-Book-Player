import Foundation
import Testing

@testable import enve

@MainActor
struct EbookTTSEngineChoiceTests {
    @Test(arguments: ["ming", "supertonic3", "unknown-engine"])
    func retiredEngineSelectionReturnsToAppleWithoutResettingReaderPreferences(engine: String) throws {
        let name = "EbookTTSEngineChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(engine, forKey: "ebookTTS.engine")
        defaults.set(true, forKey: "ebookTTS.mingModelReady")
        defaults.set(true, forKey: "ebookTTS.enhancedModelReady")
        defaults.set("am_michael", forKey: "ebookTTS.kokoroVoice")
        defaults.set(1.5, forKey: "ebookTTS.rate")
        defaults.set("en", forKey: "ebookTTS.languageIdentifier")

        let service = EbookTTSService(userDefaults: defaults)

        #expect(service.engineChoice == .apple)
        #expect(defaults.string(forKey: "ebookTTS.engine") == "apple")
        #expect(service.kokoroVoice == .michael)
        #expect(service.rate == 1.5)
        #expect(service.preferredLanguageIdentifier == "en")
        #expect(EbookTTSService(userDefaults: defaults).engineChoice == .apple)
    }

    @Test func kokoroWithoutAnInstalledModelReturnsToApple() throws {
        let name = "EbookTTSEngineChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("kokoro", forKey: "ebookTTS.engine")
        defaults.set(false, forKey: "ebookTTS.kokoroModelReady")

        let service = EbookTTSService(userDefaults: defaults)

        #expect(service.engineChoice == .apple)
        #expect(service.kokoroDownloadState == .notDownloaded)
        #expect(defaults.string(forKey: "ebookTTS.engine") == "apple")
    }
}
