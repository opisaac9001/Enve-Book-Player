#if os(iOS) && !targetEnvironment(macCatalyst)
import FluidAudio
import Foundation
import OnnxRuntimeBindings

nonisolated enum KokoroONNXAssets {
    static let revision = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"

    typealias File = NeuralTTSModelFile

    static let files: [File] = [
        File(path: "onnx/model_quantized.onnx", size: 92_361_116, sha256: "fbae9257e1e05ffc727e951ef9b9c98418e6d79f1c9b6b13bd59f5c9028a1478"),
        File(path: "tokenizer.json", size: 3_497, sha256: "77a02c8e164413299b4b4c403b14f8e0e1c1b727db4d46a09d6327b861060a34"),
        File(path: "voices/af_heart.bin", size: 522_240, sha256: "d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b"),
        File(path: "voices/af_bella.bin", size: 522_240, sha256: "f69d836209b78eb8c66e75e3cda491e26ea838a3674257e9d4e5703cbaf55c8b"),
        File(path: "voices/am_michael.bin", size: 522_240, sha256: "1d1f21dd8da39c30705cd4c75d039d265e9bc4a2a93ed09bc9e1b1225eb95ba1"),
        File(path: "voices/am_puck.bin", size: 522_240, sha256: "fcf73c989033e9233e0b98713eca600c8c74dcc1614b37009d5450ff4a2274a0"),
    ]

    static var directory: URL {
        get throws {
            try TtsCacheDirectory.ensure().appendingPathComponent("Models/KokoroONNX-\(revision)", isDirectory: true)
        }
    }

    static var areDownloaded: Bool {
        guard let directory = try? directory, let root = try? TtsCacheDirectory.ensure() else { return false }
        let frontend = root.appendingPathComponent("Models/\(Repo.kokoro.folderName)", isDirectory: true)
        return files.allSatisfy {
            (try? directory.appendingPathComponent($0.name).resourceValues(forKeys: [.fileSizeKey]).fileSize) == $0.size
        } && ModelNames.G2P.requiredModels.allSatisfy {
            FileManager.default.fileExists(atPath: frontend.appendingPathComponent($0).path)
        } && FileManager.default.fileExists(atPath: frontend.appendingPathComponent("us_lexicon_cache.json").path)
    }

    static func ensure(progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let directory = try directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let total = Double(files.reduce(0) { $0 + $1.size })
        var completed = 0
        for file in files {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(file.name)
            let before = Double(completed)
            let url = URL(string: "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/\(revision)/\(file.path)")!
            try await file.install(from: url, at: destination) { fraction in
                progress?((before + fraction * Double(file.size)) / total * 0.75)
            }
            completed += file.size
            progress?(Double(completed) / total * 0.75)
        }
        try await KokoroAneResourceDownloader.ensureG2PAssets(progressHandler: { update in
            progress?(0.75 + update.fractionCompleted * 0.2)
        })
        guard await KokoroAneResourceDownloader.ensureEnglishLexicon() != nil else { throw NeuralTTSError.notReady }
        try Task.checkCancellation()
        return directory
    }

    static func valid(_ file: File, at url: URL) -> Bool {
        file.isValid(at: url)
    }
}

actor KokoroONNXModel {
    private let inference: KokoroCPUInference
    private let vocabulary: [String: Int64]
    private let voices: [KokoroTTSVoice: [Float]]
    private let phonemizer: StyleTTS2Phonemizer

    private init(directory: URL, vocabulary: [String: Int64], phonemizer: StyleTTS2Phonemizer) throws {
        self.vocabulary = vocabulary
        var voices: [KokoroTTSVoice: [Float]] = [:]
        for voice in KokoroTTSVoice.allCases {
            voices[voice] = try KokoroAneVoicePack.load(from: directory.appendingPathComponent("\(voice.rawValue).bin")).storage
        }
        self.voices = voices
        self.phonemizer = phonemizer
        inference = try KokoroCPUInference(directory: directory)
    }

    static func prepare(progress: (@Sendable (Double) -> Void)?) async throws -> KokoroONNXModel {
        let directory = try await KokoroONNXAssets.ensure(progress: progress)
        struct Tokenizer: Decodable {
            struct Model: Decodable { let vocab: [String: Int64] }
            let model: Model
        }
        let vocabulary = try JSONDecoder().decode(Tokenizer.self, from: Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))).model.vocab
        let lexicon = LexiconAssetCache()
        let root = try TtsCacheDirectory.ensure().appendingPathComponent("Models/\(Repo.kokoro.folderName)")
        try await lexicon.ensureLoaded(kokoroDirectory: root, allowedTokens: Set(vocabulary.keys))
        let maps = await lexicon.lexicons()
        let phonemizer = StyleTTS2Phonemizer(wordToPhonemes: maps.word, caseSensitiveWordToPhonemes: maps.caseSensitive)
        try Task.checkCancellation()
        return try KokoroONNXModel(directory: directory, vocabulary: vocabulary, phonemizer: phonemizer)
    }

    func synthesize(text: String, voice: KokoroTTSVoice, speed: Float) async throws -> [Float] {
        let ipa = try await phonemizer.phonemize(text)
        var samples: [Float] = []
        for tokens in try Self.tokenChunks(ipa: ipa, vocabulary: vocabulary) {
            try Task.checkCancellation()
            let style = Self.style(voice: voices[voice]!, phonemeCount: tokens.count - 2)
            let generated = try await inference.run(tokens: tokens, style: style, speed: speed)
            try Task.checkCancellation()
            if !samples.isEmpty { samples.append(contentsOf: repeatElement(0, count: 2_880)) }
            samples.append(contentsOf: generated)
        }
        return samples
    }

    nonisolated static func tokenChunks(ipa: String, vocabulary: [String: Int64]) throws -> [[Int64]] {
        // StyleTTS2's public frontend expands these diphthongs; Kokoro uses the original Misaki symbols.
        let phonemes = [("eɪ", "A"), ("oʊ", "O"), ("aɪ", "I"), ("ɔɪ", "Y"), ("aʊ", "W")].reduce(ipa) {
            $0.replacingOccurrences(of: $1.0, with: $1.1)
        }
        let encoded = phonemes.compactMap { vocabulary[String($0)] }
        guard !encoded.isEmpty else { throw NeuralTTSError.emptyAudio }
        var chunks: [[Int64]] = []
        var start = 0
        while start < encoded.count {
            let limit = min(start + 510, encoded.count)
            let space = vocabulary[" "]
            var end = limit
            if limit < encoded.count, let space,
                let boundary = encoded[start..<limit].lastIndex(of: space), boundary > start
            {
                end = boundary
            }
            chunks.append([0] + encoded[start..<end] + [0])
            start = end
            while start < encoded.count, encoded[start] == space { start += 1 }
        }
        return chunks
    }

    nonisolated static func style(voice: [Float], phonemeCount: Int) -> [Float] {
        let start = (phonemeCount - 1) * 256
        return Array(voice[start..<(start + 256)])
    }
}

private nonisolated final class KokoroCPUInference: @unchecked Sendable {
    private let environment: ORTEnv
    private let session: ORTSession
    private let queue = DispatchQueue(label: "com.enve.kokoro.onnx", qos: .userInitiated)

    init(directory: URL) throws {
        environment = try ORTEnv(loggingLevel: .error)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        // CPU only: Core ML and XNNPACK must not execute the Kokoro graph on affected iOS releases.
        session = try ORTSession(env: environment, modelPath: directory.appendingPathComponent("model_quantized.onnx").path, sessionOptions: options)
        guard Set(try session.inputNames()) == ["input_ids", "style", "speed"], try session.outputNames().contains("waveform") else {
            throw NeuralTTSError.invalidModel
        }
    }

    func run(tokens: [Int64], style: [Float], speed: Float) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let tokenData = tokens.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
                    let styleData = style.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
                    var speed = speed
                    let speedData = NSMutableData(bytes: &speed, length: MemoryLayout<Float>.size)
                    let inputs = [
                        "input_ids": try ORTValue(tensorData: tokenData, elementType: .int64, shape: [1, NSNumber(value: tokens.count)]),
                        "style": try ORTValue(tensorData: styleData, elementType: .float, shape: [1, 256]),
                        "speed": try ORTValue(tensorData: speedData, elementType: .float, shape: [1]),
                    ]
                    let outputs = try self.session.run(withInputs: inputs, outputNames: ["waveform"], runOptions: nil)
                    guard let output = outputs["waveform"] else { throw NeuralTTSError.invalidAudio }
                    let data = try output.tensorData() as Data
                    guard !data.isEmpty, data.count.isMultiple(of: MemoryLayout<Float>.size) else { throw NeuralTTSError.emptyAudio }
                    var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
                    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
                    guard samples.allSatisfy({ $0.isFinite && abs($0) <= 4 }), samples.contains(where: { abs($0) > 0.00001 }) else { throw NeuralTTSError.invalidAudio }
                    continuation.resume(returning: samples)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
#endif
