import Foundation
import Testing

@testable import enve

struct LinkedBookAudioFingerprintTests {
    @Test func matchingSequenceScoresBetterThanDifferentSequence() {
        let reference = signal(frequencies: [180, 310, 240, 460, 350, 520])
        let levelShifted = reference.map { $0 * 0.35 }
        let different = signal(frequencies: [520, 350, 460, 240, 310, 180])

        let referenceFeatures = LinkedBookAudioFingerprint.features(from: reference)
        let matchingFeatures = LinkedBookAudioFingerprint.features(from: levelShifted)
        let differentFeatures = LinkedBookAudioFingerprint.features(from: different)

        let matchingDistance = LinkedBookAudioFingerprint.dtwDistance(
            referenceFeatures,
            matchingFeatures
        )
        let differentDistance = LinkedBookAudioFingerprint.dtwDistance(
            referenceFeatures,
            differentFeatures
        )

        #expect(referenceFeatures.count > 50)
        #expect(matchingDistance < differentDistance)
    }

    @Test func resamplingPreservesDuration() {
        let input = signal(frequencies: [220, 330, 440])
        let output = LinkedBookAudioFingerprint.resample(
            input,
            from: 16_000,
            to: 8_000
        )

        #expect(abs(output.count - input.count / 2) <= 1)
    }

    private func signal(frequencies: [Double]) -> [Float] {
        let sampleRate = 16_000.0
        let samplesPerTone = 4_000
        return frequencies.flatMap { frequency in
            (0..<samplesPerTone).map { index in
                let time = Double(index) / sampleRate
                let envelope = sin(.pi * Double(index) / Double(samplesPerTone))
                return Float(
                    envelope
                        * (sin(2 * .pi * frequency * time)
                            + 0.35 * sin(2 * .pi * frequency * 2.1 * time))
                )
            }
        }
    }
}
