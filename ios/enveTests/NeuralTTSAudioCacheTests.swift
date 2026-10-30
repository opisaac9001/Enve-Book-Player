import Foundation
import Testing

@testable import enve

nonisolated struct NeuralTTSAudioCacheTests {
    private static let validSamples: [Float] = [0, 0.25, -0.5, 1.25, -1.5]
    private static let invalidSamples: [[Float]] = [
        [], [0, 0, 0], [0.1, .nan], [0.1, .infinity], [0.1, -.infinity],
        [14_883_539_124_224, -115_553_897_283_584],
    ]

    @Test func validSpeechRoundTripsWithHeadroomIntact() throws {
        let cache = NeuralTTSAudioCache(namespace: "NeuralTTSAudioCacheTests.\(UUID().uuidString)")
        defer { try? cache.removeAll() }
        let key = cache.key("speech")

        try cache.store(Self.validSamples, key: key)

        #expect(try cache.load(key: key) == Self.validSamples)
    }

    @Test(arguments: invalidSamples)
    func invalidGeneratedAudioIsNotCached(samples: [Float]) throws {
        let cache = NeuralTTSAudioCache(namespace: "NeuralTTSAudioCacheTests.\(UUID().uuidString)")
        defer { try? cache.removeAll() }
        let key = cache.key("speech")

        #expect(throws: (any Error).self) { try cache.store(samples, key: key) }
        #expect(try cache.load(key: key) == nil)
    }

    @Test(arguments: invalidSamples)
    func corruptCachedAudioIsDiscardedAndCanBeReplaced(samples: [Float]) throws {
        let namespace = "NeuralTTSAudioCacheTests.\(UUID().uuidString)"
        let cache = NeuralTTSAudioCache(namespace: namespace)
        defer { try? cache.removeAll() }
        let key = cache.key("speech")
        try cache.store(Self.validSamples, key: key)
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("EnhancedTTS/\(namespace)/\(key).pcm")
        let corrupt = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try corrupt.write(to: url, options: .atomic)

        #expect(try cache.load(key: key) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try cache.store(Self.validSamples, key: key)
        #expect(try cache.load(key: key) == Self.validSamples)
    }
}
