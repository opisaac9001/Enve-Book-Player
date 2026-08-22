import Foundation
import Logging
import Network

actor SMBService {
    struct FileEntry: Sendable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
        let created: Date?
    }

    enum SMBError: LocalizedError, Sendable {
        case unavailable
        case invalidURL
        case connectionFailed(String)
        case authenticationFailed
        case shareNotFound(String)
        case pathNotFound(String)
        case enumerationFailed(String)
        case hostUnreachable(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "SMB client not available in this build"
            case .invalidURL: return "Invalid SMB server URL"
            case .connectionFailed(let msg): return "Connection failed: \(msg)"
            case .authenticationFailed: return "Authentication failed"
            case .shareNotFound(let s): return "Share not found: \(s)"
            case .pathNotFound(let p): return "Path not found: \(p)"
            case .enumerationFailed(let p): return "Enumeration failed at: \(p)"
            case .hostUnreachable(let h): return "Cannot reach host: \(h)"
            }
        }
    }

    nonisolated func testConnection(hostname: String, port: Int) async throws -> Bool {
        return try await withCheckedThrowingContinuation { continuation in
            let host = NWEndpoint.Host(hostname)
            let port = NWEndpoint.Port(integerLiteral: UInt16(port))
            let connection = NWConnection(host: host, port: port, using: .tcp)

            final class ResumeGate: @unchecked Sendable {
                private let lock = NSLock()
                private var didResume = false

                func resume(_ continuation: CheckedContinuation<Bool, Error>, with result: Result<Bool, Error>) {
                    lock.lock()
                    guard !didResume else {
                        lock.unlock()
                        return
                    }
                    didResume = true
                    lock.unlock()

                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
            let gate = ResumeGate()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    gate.resume(continuation, with: .success(true))
                case .failed(let error):
                    connection.cancel()
                    gate.resume(
                        continuation,
                        with: .failure(SMBError.hostUnreachable("\(hostname):\(port) - \(error.localizedDescription)"))
                    )
                case .cancelled:
                    break
                default:
                    break
                }
            }

            connection.start(queue: .global())

            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if connection.state != .ready && connection.state != .cancelled {
                    connection.cancel()
                    gate.resume(continuation, with: .failure(SMBError.hostUnreachable("\(hostname):\(port) - Connection timed out")))
                }
            }
        }
    }

    func listShares(hostname: String, port: Int, username: String, password: String) async throws -> [String] {
        #if canImport(AMSMB2)
        return try await _listShares_impl_AMSMB2(hostname: hostname, port: port, username: username, password: password)
        #else
        throw SMBError.unavailable
        #endif
    }

    func connect(config: SMBServerConfiguration, password: String) async throws {
        #if canImport(AMSMB2)
        try await _connect_impl_AMSMB2(config: config, password: password)
        #else
        throw SMBError.unavailable
        #endif
    }

    func disconnect() async {
        #if canImport(AMSMB2)
        await _disconnect_impl_AMSMB2()
        #endif
    }

    func listDirectory(at path: String) async throws -> [FileEntry] {
        #if canImport(AMSMB2)
        return try await _listDirectory_impl_AMSMB2(path: path)
        #else
        throw SMBError.unavailable
        #endif
    }

    func downloadFile(from remotePath: String, to localURL: URL, onProgress: (@Sendable (Int64, Int64) -> Void)? = nil) async throws {
        #if canImport(AMSMB2)
        try await _downloadFile_impl_AMSMB2(from: remotePath, to: localURL, onProgress: onProgress)
        #else
        throw SMBError.unavailable
        #endif
    }

    func downloadFilePartial(
        from remotePath: String,
        to localURL: URL,
        maxBytes: Int64,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        #if canImport(AMSMB2)
        try await _downloadFilePartial_impl_AMSMB2(from: remotePath, to: localURL, maxBytes: maxBytes, onProgress: onProgress)
        #else
        throw SMBError.unavailable
        #endif
    }
    func readFileRange(from remotePath: String, offset: Int64, length: Int) async throws -> Data {
        #if canImport(AMSMB2)
        return try await _readFileRange_impl_AMSMB2(from: remotePath, offset: offset, length: length)
        #else
        throw SMBError.unavailable
        #endif
    }

    func getFileSize(at remotePath: String) async throws -> Int64 {
        #if canImport(AMSMB2)
        return try await _getFileSize_impl_AMSMB2(at: remotePath)
        #else
        throw SMBError.unavailable
        #endif
    }
    func enumerateRecursively(from rootPath: String, maxDepth: Int = 8) -> AsyncThrowingStream<FileEntry, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self._enumerate(from: rootPath, depth: 0, maxDepth: maxDepth, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func _enumerate(
        from path: String,
        depth: Int,
        maxDepth: Int,
        continuation: AsyncThrowingStream<FileEntry, Error>.Continuation
    ) async throws {
        guard depth <= maxDepth else { return }
        let entries = try await listDirectory(at: path)
        for entry in entries {
            continuation.yield(entry)
            if entry.isDirectory {
                try await _enumerate(from: entry.path, depth: depth + 1, maxDepth: maxDepth, continuation: continuation)
            }
        }
    }
}

#if canImport(AMSMB2)
import AMSMB2

extension SMBService {
    private nonisolated(unsafe) static var client_AMSMB2: SMB2Manager?

    fileprivate func _connect_impl_AMSMB2(config: SMBServerConfiguration, password: String) async throws {
        let urlString = "smb://\(config.hostname)\(config.port != 445 ? ":\(config.port)" : "")"
        guard let serverURL = URL(string: urlString) else {
            throw SMBError.invalidURL
        }

        let isAnonymous = config.username.isEmpty || config.username.lowercased() == "guest"

        let authMethods: [(user: String, pass: String, domain: String)] =
            isAnonymous
            ? [
                ("guest", "", ""),
                ("Guest", "", ""),
                ("", "", ""),
                ("guest", "", "WORKGROUP"),
                ("nobody", "", ""),
            ]
            : [
                (config.username, password, ""),
                (config.username, password, "WORKGROUP"),
            ]

        var lastError: Error?

        for (user, pass, domain) in authMethods {
            let credential = URLCredential(
                user: user,
                password: pass,
                persistence: .forSession
            )

            guard let manager = SMB2Manager(url: serverURL, domain: domain, credential: credential) else {
                continue
            }

            manager.timeout = 15

            do {
                try await manager.connectShare(name: config.shareName, encrypted: false)
                Self.client_AMSMB2 = manager
                AppLogger.network.debug(
                    "Connected SMB credentialId=\(DiagnosticLogSanitizer.identifier(for: user + "|" + domain))"
                )
                return
            } catch {
                lastError = error
                AppLogger.network.error(
                    "SMB connect failed credentialId=\(DiagnosticLogSanitizer.identifier(for: user + "|" + domain)): \(error.localizedDescription)"
                )
            }
        }

        if let error = lastError {
            let nsError = error as NSError
            let posixCode = (error as? POSIXError)?.code.rawValue ?? Int32(nsError.code)

            switch posixCode {
            case 1:
                if isAnonymous {
                    throw SMBError.connectionFailed(
                        "Guest access not supported. Please use a real username and password from your Unraid server."
                    )
                } else {
                    throw SMBError.connectionFailed(
                        "Access denied. Check that share '\(config.shareName)' exists and your credentials are correct."
                    )
                }
            case 13:
                throw SMBError.authenticationFailed
            default:
                throw SMBError.connectionFailed("[\(nsError.domain):\(posixCode)] \(error.localizedDescription)")
            }
        } else {
            throw SMBError.connectionFailed("Failed to create SMB connection")
        }
    }

    fileprivate func _listShares_impl_AMSMB2(hostname: String, port: Int, username: String, password: String) async throws -> [String] {
        let urlString = "smb://\(hostname)\(port != 445 ? ":\(port)" : "")"
        guard let serverURL = URL(string: urlString) else {
            throw SMBError.invalidURL
        }

        let isAnonymous = username.isEmpty || username.lowercased() == "guest"

        let authMethods: [(user: String, pass: String, domain: String)] =
            isAnonymous
            ? [
                ("guest", "", ""),
                ("Guest", "", ""),
                ("", "", ""),
                ("guest", "", "WORKGROUP"),
                ("nobody", "", ""),
            ]
            : [
                (username, password, ""),
                (username, password, "WORKGROUP"),
            ]

        var lastError: Error?

        for (user, pass, domain) in authMethods {
            let credential = URLCredential(user: user, password: pass, persistence: .forSession)

            guard let manager = SMB2Manager(url: serverURL, domain: domain, credential: credential) else {
                continue
            }

            manager.timeout = 15

            do {
                let shares = try await manager.listShares(enumerateHidden: false)
                AppLogger.network.debug(
                    "Listed SMB shares credentialId=\(DiagnosticLogSanitizer.identifier(for: user + "|" + domain))"
                )
                return shares.map { $0.name }
            } catch {
                lastError = error
                AppLogger.network.error(
                    "SMB list shares failed credentialId=\(DiagnosticLogSanitizer.identifier(for: user + "|" + domain)): \(error.localizedDescription)"
                )
            }
        }

        if let error = lastError {
            let nsError = error as NSError
            let posixCode = (error as? POSIXError)?.code.rawValue ?? Int32(nsError.code)
            switch posixCode {
            case 1:
                if isAnonymous {
                    throw SMBError.connectionFailed(
                        "Guest access not supported. Please use a real username and password from your Unraid server."
                    )
                } else {
                    throw SMBError.connectionFailed("Access denied. Check your username and password.")
                }
            case 51:
                throw SMBError.connectionFailed("Network unreachable. Is Tailscale connected?")
            case 60:
                throw SMBError.connectionFailed("Connection timed out.")
            case 61:
                throw SMBError.connectionFailed("Connection refused on port \(port).")
            case 64, 65:
                throw SMBError.connectionFailed("Host unreachable.")
            default:
                throw SMBError.connectionFailed("[\(nsError.domain):\(posixCode)] \(error.localizedDescription)")
            }
        }
        throw SMBError.connectionFailed("Failed to list shares")
    }

    fileprivate func _disconnect_impl_AMSMB2() async {
        if let c = Self.client_AMSMB2 {
            try? await c.disconnectShare()
        }
        Self.client_AMSMB2 = nil
    }

    fileprivate func _listDirectory_impl_AMSMB2(path: String) async throws -> [FileEntry] {
        guard let c = Self.client_AMSMB2 else { throw SMBError.connectionFailed("Not connected") }
        let p = path.hasPrefix("/") ? path : "/" + path
        do {
            let contents = try await c.contentsOfDirectory(atPath: p)
            return contents.compactMap { info in
                let name = info[.nameKey] as? String
                let fullPath = info[.pathKey] as? String
                let isDir = (info[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                let size = info[.fileSizeKey] as? Int64 ?? 0
                let modified = info[.contentModificationDateKey] as? Date
                let created = info[.creationDateKey] as? Date
                guard let n = name, let fp = fullPath else { return nil }
                if n.hasPrefix(".") { return nil }
                return FileEntry(name: n, path: fp, isDirectory: isDir, size: size, modified: modified, created: created)
            }
        } catch {
            throw SMBError.enumerationFailed(p)
        }
    }

    fileprivate func _downloadFile_impl_AMSMB2(
        from remotePath: String,
        to localURL: URL,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        guard let c = Self.client_AMSMB2 else { throw SMBError.connectionFailed("Not connected") }
        let p = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath

        AppLogger.network.debug(
            "[SMB Download] Starting chunked download sourceId=\(DiagnosticLogSanitizer.identifier(for: p))"
        )

        let fm = FileManager.default
        if fm.fileExists(atPath: localURL.path) {
            try? fm.removeItem(at: localURL)
            AppLogger.network.info("[SMB Download] Removed existing file")
        }

        let fileSize = try await _getFileSize_impl_AMSMB2(at: p)
        AppLogger.network.info("[SMB Download] File size: \(fileSize) bytes (\(fileSize / 1024 / 1024)MB)")

        guard fm.createFile(atPath: localURL.path, contents: nil, attributes: nil) else {
            throw SMBError.connectionFailed("Failed to create file at \(localURL.path)")
        }
        AppLogger.network.debug(
            "[SMB Download] Created \(DiagnosticLogSanitizer.fileDescriptor(for: localURL))"
        )

        guard let fileHandle = try? FileHandle(forWritingTo: localURL) else {
            throw SMBError.connectionFailed("Failed to create file handle")
        }

        defer {
            try? fileHandle.close()
            AppLogger.network.info("[SMB Download] Closed file handle")
        }

        let chunkSize: Int64 = 1_048_576
        var offset: Int64 = 0
        var lastLoggedPercent = -1

        AppLogger.network.info("[SMB Download] Starting chunked download in \(chunkSize) byte chunks")

        while offset < fileSize {
            let remaining = fileSize - offset
            let currentChunkSize = min(chunkSize, remaining)

            do {
                let chunk = try await c.contents(atPath: p, range: offset..<(offset + currentChunkSize))

                if chunk.isEmpty {
                    AppLogger.network.info("[SMB Download] Received empty chunk at offset \(offset)")
                    break
                }

                try fileHandle.write(contentsOf: chunk)

                offset += Int64(chunk.count)

                onProgress?(offset, fileSize)

                let percent = Int((Double(offset) / Double(fileSize)) * 100)
                if percent >= lastLoggedPercent + 10 {
                    lastLoggedPercent = percent
                    AppLogger.network.info("[SMB Download] Progress: \(percent)% (\(offset / 1024 / 1024)MB / \(fileSize / 1024 / 1024)MB)")
                }
            } catch {
                AppLogger.network.error("[SMB Download] Error reading chunk at offset \(offset): \(error)")
                throw error
            }
        }

        try fileHandle.synchronize()
        AppLogger.network.info("[SMB Download] File synchronized to disk")

        if let attrs = try? fm.attributesOfItem(atPath: localURL.path),
            let actualSize = attrs[.size] as? Int64
        {
            AppLogger.network.info("[SMB Download] Final file size: \(actualSize) bytes (expected: \(fileSize))")
            if actualSize != fileSize {
                throw SMBError.connectionFailed("File size mismatch: got \(actualSize), expected \(fileSize)")
            }
        }
    }

    fileprivate func _downloadFilePartial_impl_AMSMB2(
        from remotePath: String,
        to localURL: URL,
        maxBytes: Int64,
        onProgress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws {
        guard let c = Self.client_AMSMB2 else { throw SMBError.connectionFailed("Not connected") }
        let p = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath

        let fm = FileManager.default
        if fm.fileExists(atPath: localURL.path) { try? fm.removeItem(at: localURL) }

        do {
            try await c.downloadItem(atPath: p, to: localURL) { progress, total -> Bool in
                onProgress?(progress, total)
                return progress < maxBytes
            }
        } catch {
            throw error
        }
    }

    fileprivate func _readFileRange_impl_AMSMB2(from remotePath: String, offset: Int64, length: Int) async throws -> Data {
        guard let c = Self.client_AMSMB2 else { throw SMBError.connectionFailed("Not connected") }
        let p = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath

        let range = offset..<(offset + Int64(length))
        let data = try await c.contents(atPath: p, range: range)
        return data
    }

    fileprivate func _getFileSize_impl_AMSMB2(at remotePath: String) async throws -> Int64 {
        guard let c = Self.client_AMSMB2 else { throw SMBError.connectionFailed("Not connected") }
        let p = remotePath.hasPrefix("/") ? remotePath : "/" + remotePath

        let attrs: [URLResourceKey: Any] = try await c.attributesOfItem(atPath: p)
        if let size = attrs[.fileSizeKey] as? Int64 {
            return size
        } else if let size = attrs[.fileSizeKey] as? UInt64 {
            return Int64(size)
        } else if let size = attrs[.fileSizeKey] as? Int {
            return Int64(size)
        } else if let size = attrs[.fileSizeKey] as? NSNumber {
            return size.int64Value
        }
        if let size = attrs[.totalFileSizeKey] as? Int64 {
            return size
        } else if let size = attrs[.totalFileSizeKey] as? NSNumber {
            return size.int64Value
        }
        throw SMBError.pathNotFound(p)
    }
}
#endif
