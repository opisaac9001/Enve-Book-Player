import Foundation
import CryptoKit

public enum QuartzNetExecutionProvider: String, Codable, Sendable {
    case cpu
    case xnnpack
    case coreMLAll
    case coreMLNeuralEngine
}

public struct QuartzNetBenchmarkVariant: Codable, Sendable {
    public let provider: QuartzNetExecutionProvider
    public let threads: Int

    public init(provider: QuartzNetExecutionProvider, threads: Int = 1) {
        self.provider = provider
        self.threads = threads
    }

    public static let standard: [Self] = [
        .init(provider: .cpu), .init(provider: .cpu, threads: 2),
        .init(provider: .xnnpack), .init(provider: .xnnpack, threads: 2),
        .init(provider: .coreMLAll), .init(provider: .coreMLNeuralEngine),
    ]
}

public struct QuartzNetBenchmarkMeasurement: Codable, Sendable {
    public let variant: QuartzNetBenchmarkVariant
    public let creationSeconds: Double?
    public let warmupSeconds: Double?
    public let inferenceSeconds: [Double]
    public let thermalStateBefore: Int
    public let thermalStateAfter: Int
    public let frameCount: Int?
    public let greedyText: String?
    public let greedyExactlyMatchesCPU: Bool?
    public let greedyEditDistanceFromCPU: Int?
    public let maximumAbsoluteDifferenceFromCPU: Float?
    public let rootMeanSquareDifferenceFromCPU: Double?
    public let fractionWithinOneThousandthFromCPU: Double?
    public let error: String?
}

public struct QuartzNetBenchmarkReport: Codable, Sendable {
    public let modelIdentifier: String
    public let pcmSHA256: String
    public let audioSeconds: Double
    public let operatingSystem: String
    public let measurements: [QuartzNetBenchmarkMeasurement]
}

public enum QuartzNetBenchmark {
    public static func run(pcmURL: URL, modelDirectory: URL, outputDirectory: URL, variants: [QuartzNetBenchmarkVariant] = QuartzNetBenchmarkVariant.standard) async throws -> QuartzNetBenchmarkReport {
        let attributes = try FileManager.default.attributesOfItem(atPath: pcmURL.path)
        guard let size = (attributes[.size] as? NSNumber)?.intValue, (64_000...2_432_000).contains(size) else {
            throw StoryAlignError("Benchmark PCM must contain between 1 and 38 seconds of 16 kHz Float32 mono audio.")
        }
        let data = try Data(contentsOf: pcmURL)
        guard data.count.isMultiple(of: 4), (16_000...608_000).contains(data.count / 4),
              !variants.isEmpty, variants.allSatisfy({ (1...2).contains($0.threads) }),
              variants.first?.provider == .cpu, variants.first?.threads == 1 else {
            throw StoryAlignError("A benchmark needs 1–38 seconds of Float32 little-endian 16 kHz mono PCM and a CPU/1 baseline as its first variant.")
        }
        let samples = data.withUnsafeBytes { bytes in
            stride(from: 0, to: data.count, by: 4).map { index in
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index, as: UInt32.self)))
            }
        }
        guard samples.allSatisfy(\.isFinite) else { throw StoryAlignError("Benchmark PCM contains non-finite samples.") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var baseline: CTCEmissions?
        var baselineLabels: [Int]?
        var measurements: [QuartzNetBenchmarkMeasurement] = []
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        for variant in variants {
            try Task.checkCancellation()
            let measurement = try measure(variant, samples: samples, modelDirectory: modelDirectory, baseline: &baseline, baselineLabels: &baselineLabels)
            measurements.append(measurement)
            let partial = QuartzNetBenchmarkReport(modelIdentifier: QuartzNetModelPackage.identifier, pcmSHA256: digest, audioSeconds: Double(samples.count) / 16_000, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, measurements: measurements)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(partial).write(to: outputDirectory.appendingPathComponent("benchmark.json"), options: .atomic)
        }
        return QuartzNetBenchmarkReport(modelIdentifier: QuartzNetModelPackage.identifier, pcmSHA256: digest, audioSeconds: Double(samples.count) / 16_000, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, measurements: measurements)
    }

    private static func measure(_ variant: QuartzNetBenchmarkVariant, samples: [Float], modelDirectory: URL, baseline: inout CTCEmissions?, baselineLabels: inout [Int]?) throws -> QuartzNetBenchmarkMeasurement {
        let thermalBefore = ProcessInfo.processInfo.thermalState.rawValue
        var creation: Double?
        var warmup: Double?
        var times: [Double] = []
        do {
            let creationBegan = ProcessInfo.processInfo.systemUptime
            let model = try QuartzNetModel(directory: modelDirectory, provider: variant.provider, threads: variant.threads)
            creation = ProcessInfo.processInfo.systemUptime - creationBegan
            let warmupBegan = ProcessInfo.processInfo.systemUptime
            var emissions = try model.emissions(samples: samples)
            warmup = ProcessInfo.processInfo.systemUptime - warmupBegan
            for _ in 0..<3 {
                try Task.checkCancellation()
                let began = ProcessInfo.processInfo.systemUptime
                emissions = try model.emissions(samples: samples)
                times.append(ProcessInfo.processInfo.systemUptime - began)
            }
            let decoded = CTCTextIndex.decode(emissions, blank: model.blank, space: model.space)
            let reverse = Dictionary(uniqueKeysWithValues: model.vocabulary.map { ($0.value, $0.key) })
            let text = String(decoded.labels.compactMap { reverse[$0] })
            if baseline == nil, variant.provider == .cpu, variant.threads == 1 {
                baseline = emissions
                baselineLabels = decoded.labels
            }
            var maximum: Float?
            var rms: Double?
            var fraction: Double?
            if let baseline, baseline.frames == emissions.frames, baseline.classes == emissions.classes {
                var maxDifference: Float = 0
                var squared: Double = 0
                var within = 0
                for index in emissions.values.indices {
                    let difference = abs(emissions.values[index] - baseline.values[index])
                    maxDifference = max(maxDifference, difference)
                    squared += Double(difference) * Double(difference)
                    if difference <= 0.001 { within += 1 }
                }
                maximum = maxDifference
                rms = sqrt(squared / Double(emissions.values.count))
                fraction = Double(within) / Double(emissions.values.count)
            }
            return QuartzNetBenchmarkMeasurement(variant: variant, creationSeconds: creation, warmupSeconds: warmup, inferenceSeconds: times, thermalStateBefore: thermalBefore, thermalStateAfter: ProcessInfo.processInfo.thermalState.rawValue, frameCount: emissions.frames, greedyText: text, greedyExactlyMatchesCPU: baselineLabels.map { $0 == decoded.labels }, greedyEditDistanceFromCPU: baselineLabels.map { editDistance($0, decoded.labels) }, maximumAbsoluteDifferenceFromCPU: maximum, rootMeanSquareDifferenceFromCPU: rms, fractionWithinOneThousandthFromCPU: fraction, error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return QuartzNetBenchmarkMeasurement(variant: variant, creationSeconds: creation, warmupSeconds: warmup, inferenceSeconds: times, thermalStateBefore: thermalBefore, thermalStateAfter: ProcessInfo.processInfo.thermalState.rawValue, frameCount: nil, greedyText: nil, greedyExactlyMatchesCPU: nil, greedyEditDistanceFromCPU: nil, maximumAbsoluteDifferenceFromCPU: nil, rootMeanSquareDifferenceFromCPU: nil, fractionWithinOneThousandthFromCPU: nil, error: error.localizedDescription)
        }
    }

    private static func editDistance(_ lhs: [Int], _ rhs: [Int]) -> Int {
        var previous = Array(0...rhs.count)
        for (index, label) in lhs.enumerated() {
            var current = [index + 1] + [Int](repeating: 0, count: rhs.count)
            for (otherIndex, otherLabel) in rhs.enumerated() {
                current[otherIndex + 1] = min(previous[otherIndex] + (label == otherLabel ? 0 : 1), previous[otherIndex + 1] + 1, current[otherIndex] + 1)
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
