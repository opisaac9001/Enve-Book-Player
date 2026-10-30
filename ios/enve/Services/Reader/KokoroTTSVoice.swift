import Foundation

#if !targetEnvironment(macCatalyst)
import FluidAudio
#endif

enum KokoroTTSVoice: String, CaseIterable, Identifiable, Sendable {
    case heart = "af_heart"
    case bella = "af_bella"
    case michael = "am_michael"
    case puck = "am_puck"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .heart: "Heart"
        case .bella: "Bella"
        case .michael: "Michael"
        case .puck: "Puck"
        }
    }

    var detail: String {
        switch self {
        case .heart, .bella: "American English · feminine"
        case .michael, .puck: "American English · masculine"
        }
    }
}

#if !targetEnvironment(macCatalyst)
nonisolated enum KokoroTTSVoiceAssets {
    private static let byteCount =
        KokoroAneConstants.voicePackRows * KokoroAneConstants.voicePackCols * MemoryLayout<Float>.size

    static var areDownloaded: Bool {
        guard let root = try? TtsCacheDirectory.ensure() else { return false }
        let directory = root.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.kokoroAne.folderName, isDirectory: true)
        return KokoroTTSVoice.allCases.allSatisfy { voice in
            let url = directory.appendingPathComponent("\(voice.rawValue).bin")
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == byteCount
        }
    }

    static func ensureDownloaded(in directory: URL) async throws {
        for voice in KokoroTTSVoice.allCases {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent("\(voice.rawValue).bin")
            if (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) == byteCount {
                continue
            }
            let url = try ModelRegistry.resolveModel(
                Repo.kokoroAne.remotePath, "voices/\(voice.rawValue).json"
            )
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let response = response as? HTTPURLResponse,
                (200..<300).contains(response.statusCode)
            else { throw URLError(.badServerResponse) }
            let binary = try binaryData(fromJSON: data)
            try Task.checkCancellation()
            try binary.write(to: destination, options: .atomic)
        }
    }

    static func binaryData(fromJSON data: Data) throws -> Data {
        let rows = try JSONDecoder().decode([String: [Float]].self, from: data)
        var values: [Float] = []
        values.reserveCapacity(KokoroAneConstants.voicePackRows * KokoroAneConstants.voicePackCols)
        // Binary row zero corresponds to JSON key "1", not the separate "embedding" vector.
        for index in 1...KokoroAneConstants.voicePackRows {
            guard let row = rows[String(index)],
                row.count == KokoroAneConstants.voicePackCols,
                row.allSatisfy(\.isFinite)
            else { throw KokoroAneError.invalidVoicePack("Invalid voice profile row \(index).") }
            values.append(contentsOf: row)
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
#endif
