import Foundation
import Logging
import Network

actor SMBStreamingServer {
    static let shared = SMBStreamingServer()

    private struct StreamableFile {
        let smbPath: String
        let fileSize: Int64
        let urlPath: String
    }

    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var port: UInt16 = 0

    private var currentSMBPath: String?
    private var currentSourceId: String?
    private var currentFileSize: Int64 = 0
    private var streamableFiles: [StreamableFile] = []
    private var smbService: SMBService?

    private init() {}

    func startStreaming(book: Book) async throws -> URL? {
        let urls = try await startStreamingAllFiles(book: book)
        return urls?.first
    }

    func startStreamingAllFiles(book: Book) async throws -> [URL]? {
        guard book.source == .smb else {
            AppLogger.network.info("Book is not from SMB source")
            return nil
        }

        guard let sourceId = book.backendId else {
            AppLogger.network.warning("Missing backendId for SMB book")
            return nil
        }

        if let localFiles = await LocalStorageManager.shared.localAudiobookFilesIfExists(for: book), !localFiles.isEmpty {
            AppLogger.network.info("Using \(localFiles.count) locally cached file(s)")
            return localFiles
        }

        let smbBooks = await SMBLibraryService.shared.getBooks(for: sourceId)
        guard let smbBook = smbBooks.first(where: { $0.id == book.id }) else {
            AppLogger.network.warning("SMB book not found in library index")
            return nil
        }

        guard !smbBook.audioFiles.isEmpty else {
            AppLogger.network.info("No audio files in SMB book")
            return nil
        }

        return try await startStreamingFiles(smbBook.audioFiles, sourceId: sourceId)
    }

    func startStreaming(smbPath: String, sourceId: String) async throws -> URL {
        let urls = try await startStreamingFiles(
            [SMBAudioFile(name: (smbPath as NSString).lastPathComponent, path: smbPath, size: 0)],
            sourceId: sourceId
        )
        return urls.first!
    }

    private func startStreamingFiles(_ audioFiles: [SMBAudioFile], sourceId: String) async throws -> [URL] {
        return try await Task.withTimeout(seconds: 30) { [self] in
            return try await self._startStreamingImpl(audioFiles: audioFiles, sourceId: sourceId)
        }
    }

    private func _startStreamingImpl(audioFiles: [SMBAudioFile], sourceId: String) async throws -> [URL] {
        await stopStreaming()

        guard let source = await SMBLibraryService.shared.getSources().first(where: { $0.id == sourceId }),
            let password = await SMBLibraryService.shared.getPassword(for: sourceId)
        else {
            throw NSError(domain: "SMBStreamingServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "SMB source not found"])
        }

        let service = SMBService()
        let config = source.toServerConfiguration()
        try await service.connect(config: config, password: password)

        var files: [StreamableFile] = []
        for (index, audioFile) in audioFiles.enumerated() {
            let size: Int64
            if audioFile.size > 0 {
                size = audioFile.size
            } else {
                size = (try? await service.getFileSize(at: audioFile.path)) ?? 0
            }
            let ext = (audioFile.path as NSString).pathExtension
            let urlPath = "/track_\(index).\(ext)"
            files.append(StreamableFile(smbPath: audioFile.path, fileSize: size, urlPath: urlPath))
        }

        self.smbService = service
        self.streamableFiles = files
        self.currentSMBPath = audioFiles.first?.path
        self.currentSourceId = sourceId
        self.currentFileSize = files.first?.fileSize ?? 0

        let totalSize = files.reduce(Int64(0)) { $0 + $1.fileSize }
        AppLogger.network.info("[SMB Stream] \(files.count) file(s), total size: \(totalSize / 1024 / 1024)MB")

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: .any)

        let serverPort: UInt16 = try await withCheckedThrowingContinuation { continuation in

            final class ResumeFlag: @unchecked Sendable {
                private var value = false
                private let lock = NSLock()
                func trySet() -> Bool {
                    lock.lock()
                    defer { lock.unlock() }
                    if value { return false }
                    value = true
                    return true
                }
            }
            let resumeFlag = ResumeFlag()

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumeFlag.trySet() else { return }
                    if let port = listener.port {
                        AppLogger.network.info("[SMB Stream] Server ready on port \(port.rawValue)")
                        continuation.resume(returning: port.rawValue)
                    }
                case .failed(let error):
                    guard resumeFlag.trySet() else { return }
                    AppLogger.network.error("[SMB Stream] Server failed: \(error)")
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard resumeFlag.trySet() else { return }
                    continuation.resume(
                        throwing: NSError(domain: "SMBStreamingServer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Server cancelled"])
                    )
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                let connId = ObjectIdentifier(connection)
                Task {
                    await self.addConnection(connId)
                    await self.handleConnection(connection)
                    await self.removeConnection(connId)
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }

        self.listener = listener
        self.port = serverPort

        let urls = files.compactMap { file in
            URL(string: "http://127.0.0.1:\(serverPort)\(file.urlPath)")
        }

        AppLogger.network.info("[SMB Stream] Serving \(urls.count) track URL(s) on port \(serverPort)")
        return urls
    }

    private func addConnection(_ id: ObjectIdentifier) {
        connections.insert(id)
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        connections.remove(id)
    }

    func stopStreaming() async {
        listener?.cancel()
        listener = nil
        connections.removeAll()

        if let service = smbService {
            await service.disconnect()
        }
        smbService = nil
        currentSMBPath = nil
        currentSourceId = nil
        currentFileSize = 0
        streamableFiles = []
        port = 0
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))

        let requestData = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }

        guard let data = requestData, !data.isEmpty else {
            connection.cancel()
            return
        }

        await processRequest(connection: connection, requestData: data)
    }

    private func processRequest(connection: NWConnection, requestData: Data) async {
        guard let request = String(data: requestData, encoding: .utf8),
            let service = smbService
        else {
            await sendErrorResponse(connection: connection, status: 500, message: "Server not ready")
            return
        }

        let requestPath = request.components(separatedBy: " ").dropFirst().first ?? "/"
        let resolved = resolveFile(for: String(requestPath))
        let smbPath = resolved.smbPath
        let fileSize = resolved.fileSize

        var rangeStart: Int64 = 0
        var rangeEnd: Int64? = nil

        let lines = request.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                let rangeValue = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if rangeValue.hasPrefix("bytes=") {
                    let rangeSpec = String(rangeValue.dropFirst(6))
                    let parts = rangeSpec.split(separator: "-", omittingEmptySubsequences: false)
                    if let startStr = parts.first, let startVal = Int64(startStr) {
                        rangeStart = startVal
                    }
                    if parts.count > 1, let endStr = parts.last, !endStr.isEmpty, let endVal = Int64(endStr) {
                        rangeEnd = endVal
                    }
                }
                break
            }
        }

        let ext = (smbPath as NSString).pathExtension.lowercased()
        let contentType: String
        switch ext {
        case "m4b", "m4a": contentType = "audio/mp4"
        case "mp3": contentType = "audio/mpeg"
        case "aac": contentType = "audio/aac"
        case "flac": contentType = "audio/flac"
        default: contentType = "audio/mpeg"
        }

        let effectiveEnd = min(rangeEnd ?? (fileSize - 1), fileSize - 1)
        let contentLength = effectiveEnd - rangeStart + 1

        AppLogger.network.info("[SMB Stream] Range request: \(rangeStart)-\(effectiveEnd) (\(contentLength / 1024)KB)")

        let statusLine: String
        var headers: String

        if rangeStart > 0 || rangeEnd != nil {
            statusLine = "HTTP/1.1 206 Partial Content\r\n"
            headers = "Content-Type: \(contentType)\r\n"
            headers += "Content-Length: \(contentLength)\r\n"
            headers += "Content-Range: bytes \(rangeStart)-\(effectiveEnd)/\(fileSize)\r\n"
        } else {
            statusLine = "HTTP/1.1 200 OK\r\n"
            headers = "Content-Type: \(contentType)\r\n"
            headers += "Content-Length: \(fileSize)\r\n"
        }

        headers += "Accept-Ranges: bytes\r\n"
        headers += "Connection: close\r\n"
        headers += "Cache-Control: no-cache\r\n"
        headers += "\r\n"

        let responseHeader = statusLine + headers

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: responseHeader.data(using: .utf8),
                completion: .contentProcessed { _ in
                    continuation.resume()
                }
            )
        }

        let chunkSize = 262144
        var currentOffset = rangeStart
        let endOffset = effectiveEnd

        while currentOffset <= endOffset {
            let bytesToRead = min(chunkSize, Int(endOffset - currentOffset + 1))

            do {
                let chunk = try await service.readFileRange(from: smbPath, offset: currentOffset, length: bytesToRead)

                if chunk.isEmpty {
                    break
                }

                let sendSuccess = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    connection.send(
                        content: chunk,
                        completion: .contentProcessed { error in
                            continuation.resume(returning: error == nil)
                        }
                    )
                }

                if !sendSuccess {
                    AppLogger.network.info("[SMB Stream] Client disconnected")
                    break
                }

                currentOffset += Int64(chunk.count)

            } catch {
                AppLogger.network.error("[SMB Stream] Read error at offset \(currentOffset): \(error.localizedDescription)")
                break
            }
        }

        connection.cancel()
    }

    private func resolveFile(for requestPath: String) -> (smbPath: String, fileSize: Int64) {
        let cleaned = requestPath.split(separator: "?").first.map(String.init) ?? requestPath
        if let match = streamableFiles.first(where: { cleaned.hasSuffix($0.urlPath) }) {
            return (match.smbPath, match.fileSize)
        }
        return (currentSMBPath ?? "", currentFileSize)
    }

    private func sendErrorResponse(connection: NWConnection, status: Int, message: String) async {
        let response = "HTTP/1.1 \(status) Error\r\nContent-Type: text/plain\r\nContent-Length: \(message.count)\r\n\r\n\(message)"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: response.data(using: .utf8),
                completion: .contentProcessed { _ in
                    continuation.resume()
                }
            )
        }
        connection.cancel()
    }
}
