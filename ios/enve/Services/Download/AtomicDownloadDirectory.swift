import Darwin
import Foundation

nonisolated struct AtomicDownloadDirectory: Sendable {
    let staging: URL
    let destination: URL
    let attemptID: UUID
    private static let markerName = ".enve-download-attempt"

    init(destination: URL, attemptID: UUID = UUID()) throws {
        self.destination = destination
        self.attemptID = attemptID
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        staging = parent.appendingPathComponent(".enve-download-\(attemptID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try Self.makeBackgroundReadable(staging)
        let marker = staging.appendingPathComponent(Self.markerName)
        try Data(attemptID.uuidString.utf8).write(to: marker, options: .atomic)
        try Self.makeBackgroundReadable(marker)
    }

    init(destination: URL, stagingName: String, attemptID: UUID) throws {
        guard stagingName == ".enve-download-\(attemptID.uuidString)" else { throw CocoaError(.fileReadCorruptFile) }
        self.destination = destination
        self.attemptID = attemptID
        staging = destination.deletingLastPathComponent().appendingPathComponent(stagingName, isDirectory: true)
    }

    var isPublished: Bool { markerMatches(in: destination) }

    func publish() throws {
        // The marker travels with rename, so replay after a crash cannot swap the old book back.
        if isPublished { discard(); return }
        guard markerMatches(in: staging) else { throw CocoaError(.fileReadCorruptFile) }
        if FileManager.default.fileExists(atPath: destination.path) {
            guard renameatx_np(AT_FDCWD, staging.path, AT_FDCWD, destination.path, UInt32(RENAME_SWAP)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        discard()
    }

    private func markerMatches(in directory: URL) -> Bool {
        (try? Data(contentsOf: directory.appendingPathComponent(Self.markerName))) == Data(attemptID.uuidString.utf8)
    }

    static func makeBackgroundReadable(_ url: URL) throws {
        #if os(iOS) || os(tvOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    func discard() { try? FileManager.default.removeItem(at: staging) }
}
