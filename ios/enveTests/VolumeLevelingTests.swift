import Foundation
import Testing

@testable import enve

struct VolumeLevelingTests {
    @Test func strongerLevelingReducesDynamicRangeFurther() {
        let lowRatio = outputRatio(for: .low)
        let mediumRatio = outputRatio(for: .medium)
        let highRatio = outputRatio(for: .high)

        #expect(lowRatio < 25)
        #expect(mediumRatio < lowRatio)
        #expect(highRatio < mediumRatio)
    }

    @Test func presetsMatchTheReferenceStrengths() {
        #expect(VolumeLevelingStrength.off.parameters == nil)
        #expect(VolumeLevelingStrength.low.parameters?.thresholdDB == -18)
        #expect(VolumeLevelingStrength.medium.parameters?.thresholdDB == -24)
        #expect(VolumeLevelingStrength.high.parameters?.thresholdDB == -30)
    }

    private func outputRatio(for strength: VolumeLevelingStrength) -> Float {
        let quiet = steadyOutput(input: 0.02, strength: strength)
        let loud = steadyOutput(input: 0.8, strength: strength)
        return loud / quiet
    }

    private func steadyOutput(input: Float, strength: VolumeLevelingStrength) -> Float {
        let sampleRate = 44_100
        let processor = VolumeLeveler(
            parameters: strength.parameters!,
            sampleRate: Double(sampleRate),
            channels: 1
        )
        var samples = [Float](repeating: input, count: sampleRate)
        samples.withUnsafeMutableBufferPointer { buffer in
            processor.process(buffer: buffer.baseAddress!, count: buffer.count, channel: 0)
        }
        let tail = samples.suffix(sampleRate / 10)
        return tail.reduce(0) { $0 + abs($1) } / Float(tail.count)
    }
}
