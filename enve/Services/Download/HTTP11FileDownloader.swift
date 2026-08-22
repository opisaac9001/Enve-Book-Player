import Foundation
import Logging
import Network

final class HTTP11FileDownloader: @unchecked Sendable {
    private let url: URL
    private let authHeaders: [String: String]
    let tempFileURL: URL

    nonisolated(unsafe) private var connection: NWConnection?
    nonisolated(unsafe) private var fileHandle: FileHandle?
    private let lock = NSLock()

    nonisolated(unsafe) private(set) var bytesWritten: Int64 = 0
    nonisolated(unsafe) private(set) var expectedLength: Int64 = -1
    nonisolated(unsafe) private(set) var isComplete = false
    nonisolated(unsafe) private(set) var error: Error?

    nonisolated(unsafe) private var headerBuffer = Data()
    nonisolated(unsafe) private var headersParsed = false
    nonisolated(unsafe) private var isChunked = false
    nonisolated(unsafe) private var chunkState = ChunkParseState.readingSize
    nonisolated(unsafe) private var chunkRemaining: Int = 0
    nonisolated(unsafe) private var chunkSizeBuf = Data()

    private enum ChunkParseState: Sendable {
        case readingSize, readingData, readingTrailer
    }

    nonisolated init(url: URL, headers: [String: String], tempFileURL: URL) {
        self.url = url
        self.authHeaders = headers
        self.tempFileURL = tempFileURL
    }

    nonisolated func start() {
        guard let host = url.host else {
            flagError("Invalid URL: no host")
            return
        }
        let port = UInt16(url.port ?? (url.scheme == "http" ? 80 : 443))
        let isHTTPS = url.scheme?.lowercased() != "http"

        let params: NWParameters
        if isHTTPS {
            let tlsOptions = NWProtocolTLS.Options()
            sec_protocol_options_add_tls_application_protocol(
                tlsOptions.securityProtocolOptions,
                "http/1.1"
            )
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, _, completionHandler in completionHandler(true) },
                .global()
            )
            params = NWParameters(tls: tlsOptions)
        } else {
            params = NWParameters.tcp
        }

        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: tempFileURL) else {
            flagError("Cannot create temp file")
            return
        }
        fileHandle = handle

        let conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port),
            using: params
        )
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendRequest()
            case .failed(let e):
                self.flagNWError(e)
            case .cancelled:
                self.flagDone()
            default:
                break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    nonisolated func cancel() {
        connection?.cancel()
        lock.lock()
        try? fileHandle?.close()
        fileHandle = nil
        isComplete = true
        lock.unlock()
    }

    nonisolated func closeFile() {
        lock.lock()
        try? fileHandle?.close()
        fileHandle = nil
        lock.unlock()
    }

    nonisolated private func flagError(_ msg: String) {
        lock.lock()
        error = NSError(
            domain: "HTTP11FileDownloader",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: msg]
        )
        isComplete = true
        lock.unlock()
    }

    nonisolated private func flagNWError(_ e: NWError) {
        lock.lock()
        error = e
        isComplete = true
        lock.unlock()
    }

    nonisolated private func flagDone() {
        lock.lock()
        isComplete = true
        lock.unlock()
    }

    nonisolated private func sendRequest() {
        guard let host = url.host else { return }

        let requestURI: String
        if let sr = url.absoluteString.range(of: "://") {
            let after = url.absoluteString[sr.upperBound...]
            if let si = after.firstIndex(of: "/") {
                requestURI = String(after[si...])
            } else {
                requestURI = "/"
            }
        } else {
            requestURI = "/"
        }

        var lines = [
            "GET \(requestURI) HTTP/1.1",
            "Host: \(host)",
            "Accept: */*",
            "Accept-Encoding: identity",
            "User-Agent: Enve/1.0",
            "Connection: close",
        ]
        for (k, v) in authHeaders {
            lines.append("\(k): \(v)")
        }
        let raw = lines.joined(separator: "\r\n") + "\r\n\r\n"

        connection?.send(
            content: raw.data(using: .utf8),
            completion: .contentProcessed { [weak self] err in
                if let err {
                    self?.flagError(err.localizedDescription)
                    return
                }
                self?.recv()
            }
        )
    }

    nonisolated private func recv() {
        connection?.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, _, done, err in
            guard let self else { return }

            if let err {
                self.lock.lock()
                if self.error == nil { self.error = err }
                self.isComplete = true
                self.lock.unlock()
                return
            }

            if let data, !data.isEmpty {
                self.ingest(data)
            }

            if done {
                self.lock.lock()
                try? self.fileHandle?.close()
                self.fileHandle = nil
                self.isComplete = true
                self.lock.unlock()
            } else {
                self.recv()
            }
        }
    }

    nonisolated private func ingest(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        if !headersParsed {
            headerBuffer.append(data)

            guard let endRange = headerBuffer.range(of: Data("\r\n\r\n".utf8)) else {
                return
            }

            let hdrData = headerBuffer[headerBuffer.startIndex..<endRange.lowerBound]
            guard let hdrStr = String(data: hdrData, encoding: .utf8) else {
                error = NSError(
                    domain: "HTTP11FileDownloader",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Bad response headers"]
                )
                isComplete = true
                return
            }

            let lines = hdrStr.components(separatedBy: "\r\n")
            if let status = lines.first {
                let parts = status.split(separator: " ", maxSplits: 2)
                if parts.count >= 2, let code = Int(parts[1]), !(200...299).contains(code) {
                    let reason = parts.count > 2 ? String(parts[2]) : "Error"
                    error = NSError(
                        domain: "HTTP11FileDownloader",
                        code: code,
                        userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(reason)"]
                    )
                    isComplete = true
                    connection?.cancel()
                    return
                }
            }

            for line in lines.dropFirst() {
                let lo = line.lowercased()
                if lo.hasPrefix("content-length:") {
                    let v = line.dropFirst("content-length:".count)
                        .trimmingCharacters(in: .whitespaces)
                    expectedLength = Int64(v) ?? -1
                } else if lo.hasPrefix("transfer-encoding:") {
                    let v = line.dropFirst("transfer-encoding:".count)
                        .trimmingCharacters(in: .whitespaces).lowercased()
                    isChunked = v.contains("chunked")
                }
            }

            AppLogger.network.info("[HTTP/1.1] Content-Length=\(expectedLength), chunked=\(isChunked)")
            headersParsed = true

            let bodyStart = endRange.upperBound
            if bodyStart < headerBuffer.endIndex {
                writeBody(Data(headerBuffer[bodyStart...]))
            }
            headerBuffer.removeAll()
        } else {
            writeBody(data)
        }
    }

    nonisolated private func writeBody(_ data: Data) {
        guard !isChunked else {
            parseChunked(data)
            return
        }
        fileHandle?.write(data)
        bytesWritten += Int64(data.count)
    }

    nonisolated private func parseChunked(_ data: Data) {
        var off = data.startIndex
        while off < data.endIndex {
            switch chunkState {
            case .readingSize:
                while off < data.endIndex {
                    let b = data[off]
                    off += 1
                    if b == 0x0A {
                        if let s = String(data: chunkSizeBuf, encoding: .ascii)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                            let sz = Int(s, radix: 16)
                        {
                            chunkRemaining = sz
                            chunkSizeBuf.removeAll()
                            if sz == 0 { return }
                            chunkState = .readingData
                        } else {
                            chunkSizeBuf.removeAll()
                        }
                        break
                    } else if b != 0x0D {
                        chunkSizeBuf.append(b)
                    }
                }
            case .readingData:
                let avail = data.endIndex - off
                let n = min(avail, chunkRemaining)
                fileHandle?.write(data[off..<(off + n)])
                bytesWritten += Int64(n)
                off += n
                chunkRemaining -= n
                if chunkRemaining == 0 { chunkState = .readingTrailer }
            case .readingTrailer:
                if data[off] == 0x0A { chunkState = .readingSize }
                off += 1
            }
        }
    }
}
