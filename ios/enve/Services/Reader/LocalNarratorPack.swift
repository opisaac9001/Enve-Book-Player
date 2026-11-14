#if os(iOS) && !targetEnvironment(macCatalyst)
import Foundation
import FluidAudio

nonisolated enum LocalNarratorPack {
    case supertonic, pocket

    private struct Manifest: Decodable {
        let revision: String
        let files: [NeuralTTSModelFile]

        init(resource: String) throws {
            guard let url = Bundle.main.url(forResource: resource, withExtension: "json") else {
                throw NeuralTTSError.invalidModel
            }
            self = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
    }

    private static let supertonicManifest = Result { try Manifest(resource: "SupertonicManifest") }
    private static let pocketManifest = Result { try Manifest(resource: "PocketTTSManifest") }

    private var manifest: Result<Manifest, Error> {
        switch self {
        case .supertonic: Self.supertonicManifest
        case .pocket: Self.pocketManifest
        }
    }

    var revision: String { get throws { try manifest.get().revision } }

    var root: URL {
        get throws {
            let name = self == .supertonic ? "EnveSupertonic3" : "EnvePocketTTS"
            return try TtsCacheDirectory.ensure().appendingPathComponent("Models/\(name)")
        }
    }

    /// Everything removal deletes, including the folder used before packs were pinned.
    var storageDirectories: [URL] {
        get throws {
            let root = try root
            guard self == .supertonic else { return [root] }
            let legacy = try TtsCacheDirectory.ensure().appendingPathComponent("Models/\(Repo.supertonic3.folderName)")
            return [root, legacy]
        }
    }

    var isInstalled: Bool {
        guard let pack = try? manifest.get(), let root = try? root else { return false }
        return pack.files.allSatisfy { $0.hasExpectedSize(at: destination(for: $0, in: root)) }
    }

    var byteCount: Int {
        (try? manifest.get().files.reduce(0) { $0 + $1.size }) ?? 0
    }

    /// Bytes still to fetch; `install` verifies and keeps complete files saved by an earlier attempt.
    var missingByteCount: Int {
        guard let pack = try? manifest.get(), let root = try? root else { return byteCount }
        return pack.files
            .filter { !$0.hasExpectedSize(at: destination(for: $0, in: root)) }
            .reduce(0) { $0 + $1.size }
    }

    private func destination(for file: NeuralTTSModelFile, in root: URL) -> URL {
        switch self {
        case .supertonic:
            // The pinned FluidAudio loader uses the original bundle names for these compatible v2 exports.
            return root.appendingPathComponent(Repo.supertonic3.folderName)
                .appendingPathComponent(file.path.replacingOccurrences(of: "_v2", with: ""))
        case .pocket:
            return root.appendingPathComponent(PocketTtsConstants.defaultModelsSubdirectory)
                .appendingPathComponent(Repo.pocketTts.folderName).appendingPathComponent(file.path)
        }
    }

    func install(progress: (@Sendable (Double) -> Void)?) async throws -> URL {
        let pack = try manifest.get()
        let root = try root
        let total = Double(pack.files.reduce(0) { $0 + $1.size })
        let repo = self == .supertonic ? Repo.supertonic3 : .pocketTts
        let source = URL(string: "https://huggingface.co/\(repo.remotePath)/resolve/\(pack.revision)")!
        var completed = 0
        for file in pack.files {
            let before = Double(completed)
            try await file.install(from: source.appendingPathComponent(file.path), at: destination(for: file, in: root)) { fraction in
                progress?((before + fraction * Double(file.size)) / total)
            }
            completed += file.size
            progress?(Double(completed) / total)
        }
        return root
    }
}
#endif
