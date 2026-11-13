import Foundation

// Access is serialized by BookDownloadManager's state queue, including file publication.
nonisolated final class BookHTTPTransferStore: @unchecked Sendable {
    enum Mode: String, Codable, Sendable { case single, multiTrack }
    enum Outcome: String, Codable, Sendable { case active, completed, failed }
    enum Failure: String, Codable, Sendable {
        case interrupted, transport, invalidResponse, fileSystem, stalled
        var message: String {
            switch self {
            case .interrupted: "Download interrupted. Retry to reconnect."
            case .transport: "Download failed. Retry to reconnect."
            case .stalled: "Download stopped making progress. Retry to continue."
            case .invalidResponse: "Server returned an incomplete or unsupported audio file."
            case .fileSystem: "Could not save the downloaded audio."
            }
        }
    }
    struct Part: Codable, Sendable {
        let index: Int
        var fileNames: [String] = []
    }
    struct Transfer: Codable, Sendable {
        let bookID: String
        let attemptID: UUID
        let mode: Mode
        let stagingName: String
        let destinationName: String
        var parts: [Part]
        var outcome: Outcome = .active
        var failure: Failure?
        var httpStatusCode: Int?
        var failureMessage: String {
            if let httpStatusCode { return "Download failed with HTTP status: \(httpStatusCode)" }
            return (failure ?? .interrupted).message
        }
        func taskDescription(for index: Int) -> String { "enve-http.\(attemptID.uuidString).\(index)" }
    }

    private let fileURL: URL
    private let audioRoot: URL
    private var transfers: [String: Transfer] = [:]
    private var loadError: Error?

    init(storage: ProfileStorageLocations, audioRoot: URL) {
        self.audioRoot = audioRoot
        fileURL = storage.applicationSupportDirectory.appendingPathComponent("Enve/Downloads/BookHTTPTransfers.json")
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                do {
                    let loaded = try JSONDecoder().decode([Transfer].self, from: data)
                    for transfer in loaded {
                        guard Self.valid(transfer), transfers[transfer.bookID] == nil else { throw CocoaError(.fileReadCorruptFile) }
                        transfers[transfer.bookID] = transfer
                    }
                } catch {
                    let preserved = fileURL.deletingLastPathComponent()
                        .appendingPathComponent("BookHTTPTransfers.corrupt-\(UUID().uuidString).json")
                    try FileManager.default.moveItem(at: fileURL, to: preserved)
                    transfers = [:]
                }
            }
        } catch { loadError = error; transfers = [:] }
    }

    var all: [Transfer] { Array(transfers.values) }
    func transfer(for bookID: String) -> Transfer? { transfers[bookID] }
    func transfer(taskDescription: String?) -> (Transfer, Int)? {
        guard let taskDescription else { return nil }
        for transfer in transfers.values where transfer.outcome == .active {
            if let part = transfer.parts.first(where: { $0.fileNames.isEmpty && transfer.taskDescription(for: $0.index) == taskDescription }) {
                return (transfer, part.index)
            }
        }
        return nil
    }

    func begin(bookID: String, destination: URL, mode: Mode, count: Int) throws -> Transfer {
        guard count > 0, destination.deletingLastPathComponent().standardizedFileURL.path == audioRoot.standardizedFileURL.path,
            Self.validName(destination.lastPathComponent) else { throw CocoaError(.fileWriteInvalidFileName) }
        if let loadError { throw loadError }
        if let existing = transfers[bookID], existing.outcome == .active { throw CocoaError(.fileWriteFileExists) }
        let id = UUID()
        let directory = try AtomicDownloadDirectory(destination: destination, attemptID: id)
        let transfer = Transfer(bookID: bookID, attemptID: id, mode: mode,
            stagingName: directory.staging.lastPathComponent, destinationName: destination.lastPathComponent,
            parts: (0..<count).map { Part(index: $0) })
        do { try save(transfer) } catch { directory.discard(); throw error }
        return transfer
    }

    func directory(for transfer: Transfer) throws -> AtomicDownloadDirectory {
        try AtomicDownloadDirectory(destination: audioRoot.appendingPathComponent(transfer.destinationName, isDirectory: true),
            stagingName: transfer.stagingName, attemptID: transfer.attemptID)
    }

    @discardableResult
    func completePart(bookID: String, attemptID: UUID, index: Int, fileNames: [String]) throws -> Transfer? {
        guard var transfer = transfers[bookID], transfer.attemptID == attemptID, transfer.outcome == .active,
            transfer.parts.indices.contains(index), transfer.parts[index].fileNames.isEmpty else { return nil }
        guard !fileNames.isEmpty, fileNames.allSatisfy(Self.validAudioName) else { throw CocoaError(.fileWriteInvalidFileName) }
        transfer.parts[index].fileNames = fileNames
        try save(transfer)
        if transfer.parts.allSatisfy({ !$0.fileNames.isEmpty }) {
            try directory(for: transfer).publish()
            transfer.outcome = .completed
            try save(transfer)
        }
        return transfer
    }

    func fail(bookID: String, attemptID: UUID, category: Failure, httpStatusCode: Int? = nil) throws -> Transfer? {
        guard var transfer = transfers[bookID], transfer.attemptID == attemptID, transfer.outcome == .active else { return nil }
        if try directory(for: transfer).isPublished {
            transfer.outcome = .completed
        } else {
            transfer.outcome = .failed
            transfer.failure = category
            transfer.httpStatusCode = httpStatusCode.flatMap { (100...599).contains($0) ? $0 : nil }
        }
        do {
            try save(transfer)
        } catch {
            transfers[bookID] = transfer
            try? directory(for: transfer).discard()
            throw error
        }
        try directory(for: transfer).discard()
        return transfer
    }

    func cancel(bookID: String) throws {
        guard let transfer = transfers[bookID] else { return }
        var next = transfers
        next.removeValue(forKey: bookID)
        do { try persist(next) }
        catch {
            transfers = next
            try directory(for: transfer).discard()
            throw error
        }
        try directory(for: transfer).discard()
    }

    func acknowledge(bookID: String) throws {
        guard let transfer = transfers[bookID], transfer.outcome != .active else { return }
        try cancel(bookID: bookID)
    }

    func recover(liveTaskDescriptions: Set<String>, attemptIDs: Set<UUID>? = nil) throws {
        if let loadError { throw loadError }
        for var transfer in all where transfer.outcome == .active {
            if let attemptIDs, !attemptIDs.contains(transfer.attemptID) { continue }
            let directory = try directory(for: transfer)
            if directory.isPublished {
                transfer.outcome = .completed
                try save(transfer)
                directory.discard()
                continue
            }
            let validParts = transfer.parts.filter { part in
                !part.fileNames.isEmpty && part.fileNames.allSatisfy { name in
                    let url = directory.staging.appendingPathComponent(name)
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    return size > 0
                }
            }
            if validParts.count == transfer.parts.count {
                try directory.publish()
                transfer.outcome = .completed
                try save(transfer)
            } else if transfer.parts.contains(where: { part in
                !validParts.contains(where: { $0.index == part.index }) && !liveTaskDescriptions.contains(transfer.taskDescription(for: part.index))
            }) {
                _ = try fail(bookID: transfer.bookID, attemptID: transfer.attemptID, category: .interrupted)
            }
        }
    }

    private func save(_ transfer: Transfer) throws {
        var next = transfers
        next[transfer.bookID] = transfer
        try persist(next)
    }
    private func persist(_ next: [String: Transfer]) throws {
        if let loadError { throw loadError }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicDownloadDirectory.makeBackgroundReadable(fileURL.deletingLastPathComponent())
        try JSONEncoder().encode(Array(next.values)).write(to: fileURL, options: .atomic)
        try AtomicDownloadDirectory.makeBackgroundReadable(fileURL)
        transfers = next
    }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
    private static func validAudioName(_ name: String) -> Bool {
        guard validName(name), name.hasPrefix("chapter_") else { return false }
        let components = name.dropFirst("chapter_".count).split(separator: ".", omittingEmptySubsequences: false)
        return components.count == 2 && !components[0].isEmpty && components[0].allSatisfy(\.isNumber)
            && !components[1].isEmpty && components[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    private static func valid(_ transfer: Transfer) -> Bool {
        (transfer.httpStatusCode.map { (100...599).contains($0) } ?? true)
            && validName(transfer.destinationName) && transfer.stagingName == ".enve-download-\(transfer.attemptID.uuidString)"
            && !transfer.parts.isEmpty && transfer.parts.enumerated().allSatisfy { index, part in
                part.index == index && part.fileNames.allSatisfy(validAudioName)
            }
    }
}
