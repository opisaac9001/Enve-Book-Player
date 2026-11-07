import Foundation
import Testing

@testable import enve

@MainActor
struct EbookTTSEngineChoiceTests {
    @Test(arguments: ["ming", "unknown-engine"])
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

    @Test func kokoroWithoutAnInstalledModelUsesApple() throws {
        let name = "EbookTTSEngineChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("kokoro", forKey: "ebookTTS.engine")
        defaults.set(false, forKey: "ebookTTS.kokoroModelReady")

        let service = EbookTTSService(userDefaults: defaults)

        #expect(service.engineChoice == .apple)
        #expect(service.kokoroDownloadState == .notDownloaded)
        #expect(defaults.string(forKey: "ebookTTS.engine") == "kokoro")
        #expect(!defaults.bool(forKey: "ebookTTS.kokoroModelReady"))
    }

    @Test func supertonicIsOfferedBesideAppleAndKokoro() {
        #if targetEnvironment(macCatalyst)
        #expect(EbookTTSEngineChoice.allCases == [.apple])
        #else
        #expect(EbookTTSEngineChoice.allCases == [.apple, .kokoro, .supertonic3, .pocket])
        #endif
        #expect(EnhancedTTSVoice.allCases.map(\.rawValue) == ["F1", "F2", "F3", "F4", "F5", "M1", "M2", "M3", "M4", "M5"])
        #expect(EnhancedTTSVoice.supportedLanguageCodes.contains("en"))
    }

    @Test func supertonicWithoutAnInstalledModelUsesAppleAndKeepsItsVoice() throws {
        let name = "EbookTTSEngineChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("supertonic3", forKey: "ebookTTS.engine")
        defaults.set(false, forKey: "ebookTTS.enhancedModelReady")
        defaults.set("F3", forKey: "ebookTTS.enhancedVoice")
        defaults.set(true, forKey: "ebookTTS.kokoroModelReady")

        let service = EbookTTSService(userDefaults: defaults)

        #expect(service.engineChoice == .apple)
        #expect(service.supertonicDownloadState == .notDownloaded)
        #expect(service.downloadState(for: .supertonic3) == .notDownloaded)
        #expect(service.enhancedVoice == .f3)
        #expect(defaults.string(forKey: "ebookTTS.engine") == "apple")
        #expect(defaults.bool(forKey: "ebookTTS.kokoroModelReady"))
    }

    @Test func choosingSupertonicVoiceWhileOnAnotherEngineOnlyPersistsTheVoice() throws {
        let name = "EbookTTSEngineChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("not-a-voice", forKey: "ebookTTS.enhancedVoice")

        let service = EbookTTSService(userDefaults: defaults)
        #expect(service.enhancedVoice == .m1)

        service.setEnhancedVoice(.f5)

        #expect(service.engineChoice == .apple)
        #expect(defaults.string(forKey: "ebookTTS.enhancedVoice") == "F5")
        #expect(EbookTTSService(userDefaults: defaults).enhancedVoice == .f5)
    }
}
