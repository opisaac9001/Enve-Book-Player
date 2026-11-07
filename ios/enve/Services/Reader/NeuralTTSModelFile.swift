#if os(iOS) && !targetEnvironment(macCatalyst)
import CryptoKit
import Foundation

nonisolated struct NeuralTTSModelFile: Decodable, Sendable {
    let path: String
    let size: Int
    let sha256: String

    var name: String { URL(fileURLWithPath: path).lastPathComponent }

    func hasExpectedSize(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == size
    }

    func isValid(at url: URL) -> Bool {
        guard hasExpectedSize(at: url), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == sha256
    }

    func install(from url: URL, at destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        if isValid(at: destination) { return }
        let delegate = await MainActor.run { URLSessionDownloadProgressDelegate(progressHandler: progress) }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (temporary, response) = try await delegate.awaitResult { session.downloadTask(with: url) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard response.statusCode == 200, isValid(at: temporary) else { throw NeuralTTSError.invalidModel }
        try Task.checkCancellation()
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }
    }
}
#endif
