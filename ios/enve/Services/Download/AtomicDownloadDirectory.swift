import Darwin
import Foundation

nonisolated struct AtomicDownloadDirectory: Sendable {
    let staging: URL
    let destination: URL

    init(destination: URL) throws {
        self.destination = destination
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        staging = parent.appendingPathComponent(".enve-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
    }

    func publish() throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            // Swap whole directories so readers see either complete version; failed refreshes keep the old one.
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        discard()
    }

    func discard() {
        try? FileManager.default.removeItem(at: staging)
    }
}
