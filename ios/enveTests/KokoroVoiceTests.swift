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
}
