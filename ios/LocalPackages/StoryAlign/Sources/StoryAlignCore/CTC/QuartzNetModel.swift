import Foundation
import CryptoKit
#if canImport(OnnxRuntimeBindings) && !targetEnvironment(macCatalyst)
import OnnxRuntimeBindings
#endif

public enum QuartzNetModelPackage {
    public static let identifier = "quartznet15x5-en-3023100"
    public static var isSupported: Bool {
        #if canImport(OnnxRuntimeBindings) && !targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
    public struct File: Sendable {
        public let name: String
        public let size: Int64
        public let sha256: String
        public var url: URL {
            URL(string: "https://gitlab.com/api/v4/projects/67994333/packages/ml_models/3023100/files/\(name)")!
        }
    }
    public static let files: [File] = [
        File(name: "config.json", size: 2856, sha256: "63817123d5a0c6821df1bc88e059c8f771e64972fb31639c2dc9594488e85418"),
        File(name: "vocab.txt", size: 141, sha256: "030853bf8c7ccc1e0673cd8359ccc7c91ea507d2adab6be7c7789e24013a86aa"),
        File(name: "model.onnx", size: 76_711_679, sha256: "3a4cf199c53475ae752694bb65989c05755bf6920d8ac8aaf51581a1021bdf2c"),
    ]

    public static func verify(directory: URL) throws {
        for file in files {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(file.name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.int64Value == file.size,
                  try digest(url) == file.sha256 else {
                throw StoryAlignError("The QuartzNet model package is incomplete or damaged. Download it again.")
            }
        }
    }

    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class QuartzNetModel {
    let vocabulary: [Character: Int]
    let blank: Int
    let space: Int
    let secondsPerFrame: Double
    private(set) var executionProvider: QuartzNetExecutionProvider
    #if canImport(OnnxRuntimeBindings) && !targetEnvironment(macCatalyst)
    private let environment: ORTEnv
    private var session: ORTSession
    private var cpuFallback: (() throws -> ORTSession)?
    private let outputName: String
    #endif

    init(directory: URL, provider: QuartzNetExecutionProvider? = nil, threads: Int = 1) throws {
        guard QuartzNetModelPackage.isSupported else {
            throw StoryAlignError("QuartzNet alignment is unavailable on this platform.")
        }
        try QuartzNetModelPackage.verify(directory: directory)
        struct Configuration: Decodable {
            let architecture: String
            let sampleRate: Int
            let samplesPerFrame: Int
            let blank: Int
            let classes: Int
        }
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
        guard config.architecture == "quartznet15x5", config.sampleRate == 16_000,
              config.samplesPerFrame == 320, config.blank == 28, config.classes == 29 else {
            throw StoryAlignError("Unsupported QuartzNet model configuration.")
        }
        var vocabulary: [Character: Int] = [:]
        for line in try String(contentsOf: directory.appendingPathComponent("vocab.txt"), encoding: .utf8).split(separator: "\n") {
            guard let separator = line.lastIndex(of: " "), let index = Int(line[line.index(after: separator)...]) else {
                throw StoryAlignError("Invalid QuartzNet vocabulary.")
            }
            let token = String(line[..<separator])
            if token.count == 1, token != "▁", let character = token.first { vocabulary[character] = index }
        }
        self.vocabulary = vocabulary
        self.blank = config.blank
        self.space = 0
        self.secondsPerFrame = Double(config.samplesPerFrame) / Double(config.sampleRate)
        #if canImport(OnnxRuntimeBindings) && !targetEnvironment(macCatalyst)
        let environment = try ORTEnv(loggingLevel: .error)
        self.environment = environment
        func makeSession(_ selected: QuartzNetExecutionProvider) throws -> ORTSession {
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(Int32(threads))
            try options.setGraphOptimizationLevel(.all)
            switch selected {
            case .cpu:
                break
            case .xnnpack:
                let providerOptions = ORTXnnpackExecutionProviderOptions()
                providerOptions.intra_op_num_threads = Int32(threads)
                try options.appendXnnpackExecutionProvider(with: providerOptions)
            case .coreMLAll, .coreMLNeuralEngine:
                guard ORTIsCoreMLExecutionProviderAvailable() else {
                    throw StoryAlignError("The CoreML execution provider is unavailable on this device.")
                }
                try options.appendCoreMLExecutionProvider(withOptionsV2: [
                    "MLComputeUnits": selected == .coreMLAll ? "ALL" : "CPUAndNeuralEngine",
                    "ModelFormat": "NeuralNetwork",
                    "RequireStaticInputShapes": "0",
                    "EnableOnSubgraphs": "0",
                ])
            }
            return try ORTSession(env: environment, modelPath: directory.appendingPathComponent("model.onnx").path, sessionOptions: options)
        }
        if let provider {
            session = try makeSession(provider)
            executionProvider = provider
        } else {
            do {
                session = try makeSession(.coreMLNeuralEngine)
                executionProvider = .coreMLNeuralEngine
            } catch {
                try Task.checkCancellation()
                session = try makeSession(.cpu)
                executionProvider = .cpu
            }
        }
        if provider == nil, executionProvider == .coreMLNeuralEngine {
            cpuFallback = { try makeSession(.cpu) }
        }
        guard try session.inputNames() == ["signal"], let output = try session.outputNames().first else {
            throw StoryAlignError("The QuartzNet graph does not accept the expected audio signal.")
        }
        outputName = output
        #else
        throw StoryAlignError("QuartzNet alignment is available on iPhone, iPad and Mac.")
        #endif
    }

    func emissions(samples: [Float]) throws -> CTCEmissions {
        try Task.checkCancellation()
        guard samples.count > 512 else { throw StoryAlignError("Not enough audio samples for QuartzNet.") }
        #if canImport(OnnxRuntimeBindings) && !targetEnvironment(macCatalyst)
        let signal = Self.prepareSignal(samples)
        let data = signal.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        let input = try ORTValue(tensorData: data, elementType: .float, shape: [1, 1, NSNumber(value: signal.count)])
        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(withInputs: ["signal": input], outputNames: [outputName], runOptions: nil)
        } catch {
            try Task.checkCancellation()
            guard let retry = cpuFallback else { throw error }
            cpuFallback = nil
            let cpuSession = try retry()
            try Task.checkCancellation()
            session = cpuSession
            executionProvider = .cpu
            outputs = try session.run(withInputs: ["signal": input], outputNames: [outputName], runOptions: nil)
        }
        try Task.checkCancellation()
        guard let output = outputs[outputName] else { throw StoryAlignError("QuartzNet returned no probabilities.") }
        let info = try output.tensorTypeAndShapeInfo()
        let shape = info.shape.map(\.intValue)
        guard info.elementType == .float, shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] == 29 else {
            throw StoryAlignError("QuartzNet returned invalid probability dimensions.")
        }
        let raw = try output.tensorData()
        guard raw.length == shape[1] * shape[2] * MemoryLayout<Float>.size else {
            throw StoryAlignError("QuartzNet returned an incomplete probability tensor.")
        }
        var values = Array(UnsafeBufferPointer(start: raw.bytes.assumingMemoryBound(to: Float.self), count: raw.length / MemoryLayout<Float>.size))
        guard values.allSatisfy({ $0.isFinite }) else { throw StoryAlignError("QuartzNet returned invalid probabilities.") }
        for frame in 0..<shape[1] {
            let row = frame * shape[2]
            let a = values[row + blank]
            let b = values[row + space]
            values[row + blank] = max(a, b) + log1p(exp(-abs(a - b)))
            values[row + space] = -30
        }
        return CTCEmissions(values: values, frames: shape[1], classes: shape[2], secondsPerFrame: secondsPerFrame)
        #else
        throw StoryAlignError("QuartzNet alignment is unavailable on this platform.")
        #endif
    }

    static func prepareSignal(_ samples: [Float]) -> [Float] {
        let pad = 256
        var signal = [Float](repeating: 0, count: samples.count + 2 * pad)
        signal[pad] = samples[0]
        for index in 1..<samples.count { signal[pad + index] = samples[index] - 0.97 * samples[index - 1] }
        for offset in 1...pad {
            signal[pad - offset] = signal[pad + offset]
            signal[pad + samples.count - 1 + offset] = signal[pad + samples.count - 1 - offset]
        }
        return signal
    }
}
