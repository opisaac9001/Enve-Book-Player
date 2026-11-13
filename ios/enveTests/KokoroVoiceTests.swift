import Foundation
import Testing

@testable import enve

nonisolated struct KokoroVoiceTests {
    @Test func profileRowsUseNumericOrderAndIgnoreEmbedding() throws {
        var rows = Dictionary(uniqueKeysWithValues: (1...510).map { index in
            (String(index), [Float](repeating: Float(index), count: 256))
        })
        rows["embedding"] = [Float](repeating: -1, count: 256)
        let data = try JSONEncoder().encode(rows)
        let binary = try KokoroTTSVoiceAssets.binaryData(fromJSON: data)
        var values = [Float](repeating: 0, count: 510 * 256)
        _ = values.withUnsafeMutableBytes { binary.copyBytes(to: $0) }

        #expect(binary.count == 522_240)
        #expect(values[0] == 1)
        #expect(values[255] == 1)
        #expect(values[256] == 2)
        #expect(values[9 * 256] == 10)
        #expect(values.last == 510)
    }

    @Test(arguments: ["{}", "{\"1\":[0]}"])
    func incompleteProfileIsRejected(json: String) {
        let data = Data(json.utf8)
        #expect(throws: (any Error).self) {
            try KokoroTTSVoiceAssets.binaryData(fromJSON: data)
        }
    }

    @Test @MainActor func selectedVoicePersistsWithinItsProfile() throws {
        let firstName = "KokoroVoiceTests.\(UUID().uuidString)"
        let secondName = "KokoroVoiceTests.\(UUID().uuidString)"
        let first = try #require(UserDefaults(suiteName: firstName))
        let second = try #require(UserDefaults(suiteName: secondName))
        defer {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }
        let service = EbookTTSService(userDefaults: first)
        service.setKokoroVoice(.michael)

        #expect(EbookTTSService(userDefaults: first).kokoroVoice == .michael)
        #expect(EbookTTSService(userDefaults: second).kokoroVoice == .heart)
        #expect(service.engineChoice == .apple)

        first.set("unknown_voice", forKey: "ebookTTS.kokoroVoice")
        #expect(EbookTTSService(userDefaults: first).kokoroVoice == .heart)
    }

    #if !targetEnvironment(macCatalyst)
    @Test(arguments: [
        (17, 7, false), (26, 3, false), (26, 4, true), (26, 5, true), (26, 6, true), (27, 0, true), (27, 2, true),
    ])
    func affectedSystemsUseTheCPUBackend(major: Int, minor: Int, supported: Bool) {
        let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
        #expect(KokoroTTSRuntime.usesONNX(on: version) == supported)
    }
    #endif

    @Test(.enabled(if: !KokoroTTSRuntime.isSupportedOnCurrentOS)) @MainActor
    func aBlockedSystemKeepsTheStoredKokoroChoiceAndNeverPreparesIt() throws {
        let name = "KokoroVoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("kokoro", forKey: "ebookTTS.engine")
        defaults.set(KokoroTTSVoice.michael.rawValue, forKey: "ebookTTS.kokoroVoice")
        defaults.set(true, forKey: "ebookTTS.kokoroModelReady")

        let service = EbookTTSService(userDefaults: defaults)
        #expect(service.engineChoice == .apple)
        #expect(service.kokoroVoice == .michael)
        #expect(defaults.string(forKey: "ebookTTS.engine") == "kokoro")

        let unavailable = NeuralTTSError.unsupportedOS.localizedDescription
        for attempt in [{ service.setEngineChoice(.kokoro) }, { service.downloadModel(for: .kokoro) }] {
            attempt()
            #expect(service.engineChoice == .apple)
            if service.downloadState(for: .kokoro) == .ready {
                #expect(service.speechError == unavailable)
            } else {
                #expect(service.downloadState(for: .kokoro) == .failed(unavailable))
            }
        }
        #expect(defaults.string(forKey: "ebookTTS.engine") == "kokoro")
        #expect(defaults.bool(forKey: "ebookTTS.kokoroModelReady"))
        #expect(EbookTTSService(userDefaults: defaults).kokoroVoice == .michael)

        service.setEngineChoice(.apple)
        #expect(defaults.string(forKey: "ebookTTS.engine") == "apple")
        #expect(EbookTTSService(userDefaults: defaults).engineChoice == .apple)
    }
}
