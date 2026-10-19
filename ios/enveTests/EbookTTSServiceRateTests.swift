import Foundation
import Testing

@testable import enve

@Suite(.serialized) @MainActor
struct EbookTTSServiceRateTests {
    private static let rateKey = "ebookTTS.rate"

    private static func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "EbookTTSServiceRateTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suiteName)), suiteName)
    }

    @Test func rapidRateUpdatesSettleOnTheFinalValue() throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tts = EbookTTSService(userDefaults: defaults)

        for step in stride(from: Float(0.5), through: 3, by: 0.25) {
            tts.rate = step
        }
        tts.rate = 1.75
        #expect(defaults.object(forKey: Self.rateKey) == nil)

        tts.commitRate()
        #expect(tts.rate == 1.75)
        #expect(defaults.double(forKey: Self.rateKey) == 1.75)
    }

    @Test func uncommittedRateIsPersistedAfterTheDebounce() async throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tts = EbookTTSService(userDefaults: defaults)

        tts.rate = 2.25
        try await Task.sleep(for: .milliseconds(600))

        #expect(defaults.double(forKey: Self.rateKey) == 2.25)
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func nonFiniteRateIsRejectedAndTheStoredValueRetained(value: Float) throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tts = EbookTTSService(userDefaults: defaults)
        tts.rate = 1.5
        tts.commitRate()

        tts.rate = value
        tts.commitRate()

        #expect(tts.rate == 1.5)
        #expect(defaults.double(forKey: Self.rateKey) == 1.5)
    }

    @Test func outOfRangeRatesAreClamped() throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tts = EbookTTSService(userDefaults: defaults)

        tts.rate = 9
        #expect(tts.rate == EbookTTSService.rateRange.upperBound)
        tts.rate = 0.1
        #expect(tts.rate == EbookTTSService.rateRange.lowerBound)
    }

    @Test(arguments: [(Double.nan, Float(1)), (7, 3), (2.5, 2.5)])
    func persistedRateIsValidatedOnLaunch(stored: Double, expected: Float) throws {
        let (defaults, suiteName) = try Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(stored, forKey: Self.rateKey)

        let tts = EbookTTSService(userDefaults: defaults)

        #expect(tts.rate == expected)
    }
}
