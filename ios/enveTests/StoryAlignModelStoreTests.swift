import CryptoKit
import Foundation
import Testing

@testable import enve

@Suite @MainActor
struct StoryAlignModelStoreTests {
    @Test func verifiesDigestRatherThanSizeAlone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("model.onnx")
        let original = Data("known model content".utf8)
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let artifact = StoryAlignModelStore.Artifact(name: "model.onnx", size: Int64(original.count), sha256: digest)
        try original.write(to: url)
        let valid = try await StoryAlignModelStore.matches(url, artifact: artifact)
        #expect(valid)
        var corrupt = original
        corrupt[0] ^= 1
        try corrupt.write(to: url)
        let invalid = try await StoryAlignModelStore.matches(url, artifact: artifact)
        #expect(!invalid)
    }

    @Test func rejectsMissingAndTruncatedFiles() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let artifact = StoryAlignModelStore.Artifact(name: "model.onnx", size: 10, sha256: String(repeating: "0", count: 64))
        let missing = try await StoryAlignModelStore.matches(url, artifact: artifact)
        #expect(!missing)
        try Data([0, 1]).write(to: url)
        let truncated = try await StoryAlignModelStore.matches(url, artifact: artifact)
        #expect(!truncated)
    }
}
