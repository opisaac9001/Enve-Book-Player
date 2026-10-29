#if os(iOS)
import CryptoKit
import Foundation
import StoryAlignCore

@MainActor
final class StoryAlignModelStore {
    static let shared = StoryAlignModelStore()

    struct Artifact: Sendable {
        let name: String
        let size: Int64
        let sha256: String
    }

    static let artifacts = QuartzNetModelPackage.files.map {
        Artifact(name: $0.name, size: $0.size, sha256: $0.sha256)
    }

    private let root: URL
    private var preparation: Task<URL, Error>?
    private var preparationID = UUID()
    private var participants: Set<UUID> = []

    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("Enve/AlignmentModels", isDirectory: true)) {
        self.root = root
    }

    func prepare() async throws -> URL {
        let participant = UUID()
        let task: Task<URL, Error>
        if let preparation {
            task = preparation
        } else {
            preparationID = UUID()
            task = makePreparation()
            preparation = task
        }
        let generation = preparationID
        participants.insert(participant)
        defer { release(participant, generation: generation) }
        return try await withTaskCancellationHandler {
            let directory = try await task.value
            try Task.checkCancellation()
            return directory
        } onCancel: {
            Task { @MainActor in self.release(participant, generation: generation) }
        }
    }

    private func release(_ participant: UUID, generation: UUID) {
        guard generation == preparationID, participants.remove(participant) != nil, participants.isEmpty else { return }
        preparation?.cancel()
        preparation = nil
    }

    private func makePreparation() -> Task<URL, Error> {
        let root = root
        return Task<URL, Error> {
            let directory = root.appendingPathComponent("quartznet15x5-en-3023100-3a4cf199", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var excludedRoot = root
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try excludedRoot.setResourceValues(resources)
            for entry in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                where entry.lastPathComponent.hasPrefix("download-") {
                try FileManager.default.removeItem(at: entry)
            }
            if try await Self.isValid(directory) { return directory }
            let staging = root.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }

            for artifact in Self.artifacts {
                try Task.checkCancellation()
                let url = URL(string: "https://gitlab.com/api/v4/projects/67994333/packages/ml_models/3023100/files/\(artifact.name)")!
                let (temporary, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    throw ModelError.downloadFailed
                }
                let destination = staging.appendingPathComponent(artifact.name)
                try FileManager.default.moveItem(at: temporary, to: destination)
                guard try await Self.matches(destination, artifact: artifact) else {
                    throw ModelError.integrityFailure
                }
            }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.moveItem(at: staging, to: directory)
            return directory
        }
    }

    private static func isValid(_ directory: URL) async throws -> Bool {
        for artifact in artifacts {
            guard try await matches(directory.appendingPathComponent(artifact.name), artifact: artifact) else { return false }
        }
        return true
    }

    static func matches(_ url: URL, artifact: Artifact) async throws -> Bool {
        let task = Task.detached(priority: .utility) {
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard size.map(Int64.init) == artifact.size else { return false }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var digest = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                digest.update(data: data)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined() == artifact.sha256
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    enum ModelError: LocalizedError {
        case downloadFailed
        case integrityFailure

        var errorDescription: String? {
            switch self {
            case .downloadFailed: "The alignment model could not be downloaded. Check your connection and try again."
            case .integrityFailure: "The alignment model failed verification. Try downloading it again."
            }
        }
    }
}
#endif
