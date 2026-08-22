import Foundation
import Network

actor StorytellerStreamingServer {
    static let shared = StorytellerStreamingServer()

    private var listener: NWListener?
    private var connections: Set<ObjectIdentifier> = []
    private var port: UInt16 = 0

    private var currentTrackInfos: [AudioTrackInfo] = []
    private var currentRemoteTrackURLs: [URL] = []
    private var currentHeaders: [String: String] = [:]
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    func startStreaming(tracks: [AudioTrackInfo], headers: [String: String]) async throws -> [AudioTrackInfo] {
        await stopStreaming()

        let resolvedTracks = tracks.compactMap { track -> URL? in
            URL(string: track.contentUrl)
        }
        guard resolvedTracks.count == tracks.count, !resolvedTracks.isEmpty else {
            return tracks
        }

        self.currentTrackInfos = tracks
        self.currentRemoteTrackURLs = resolvedTracks
        self.currentHeaders = headers

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
                    guard let port = listener.port else { return }
                    continuation.resume(returning: port.rawValue)
                case .failed(let error):
                    guard resumeFlag.trySet() else { return }
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard resumeFlag.trySet() else { return }
                    continuation.resume(
                        throwing: NSError(
                            domain: "StorytellerStreamingServer",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Proxy cancelled"]
                        )
                    )
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
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

        return tracks.enumerated().map { index, track in
            let ext = URL(string: track.contentUrl)?.pathExtension ?? "mp4"
            let localURL = "http://127.0.0.1:\(serverPort)/track/\(index).\(ext)"
            return AudioTrackInfo(
                index: track.index,
                startOffset: track.startOffset,
                duration: track.duration,
                contentUrl: localURL,
                mimeType: track.mimeType
            )
        }
    }

    func stopStreaming() async {
        listener?.cancel()
        listener = nil
        connections.removeAll()
        currentTrackInfos = []
        currentRemoteTrackURLs = []
        currentHeaders = [:]
        port = 0
    }

    private func addConnection(_ id: ObjectIdentifier) {
        connections.insert(id)
    }

    private func removeConnection(_ id: ObjectIdentifier) {
        connections.remove(id)
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))

        let requestData = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }

        guard let requestData, !requestData.isEmpty else {
            connection.cancel()
            return
        }

        await processRequest(connection: connection, requestData: requestData)
    }

    private func processRequest(connection: NWConnection, requestData: Data) async {
        guard let requestText = String(data: requestData, encoding: .utf8) else {
            await sendErrorResponse(connection: connection, status: 400, message: "Invalid request")
            return
        }

        let lines = requestText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            await sendErrorResponse(connection: connection, status: 400, message: "Missing request line")
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            await sendErrorResponse(connection: connection, status: 400, message: "Malformed request")
            return
        }

        let path = String(parts[1])
        guard path.hasPrefix("/track/") else {
            await sendErrorResponse(connection: connection, status: 404, message: "Not found")
            return
        }

        let filename = String(path.dropFirst("/track/".count))
        let indexString = filename.split(separator: ".").first.map(String.init) ?? ""
        guard let index = Int(indexString),
            currentTrackInfos.indices.contains(index),
            currentRemoteTrackURLs.indices.contains(index)
        else {
            await sendErrorResponse(connection: connection, status: 404, message: "Track not found")
            return
        }

        let track = currentTrackInfos[index]
        let remoteURL = currentRemoteTrackURLs[index]
        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"

        for line in lines {
            if line.lowercased().hasPrefix("range:") {
                let rangeValue = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                request.setValue(rangeValue, forHTTPHeaderField: "Range")
            }
        }

        for (key, value) in currentHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                await sendErrorResponse(connection: connection, status: 502, message: "Invalid upstream response")
                return
            }

            let reasonPhrase = http.statusCode == 206 ? "Partial Content" : "OK"
            var headerText = "HTTP/1.1 \(http.statusCode) \(reasonPhrase)\r\n"

            let normalizedContentType: String
            if track.mimeType == "audio/mp4" || track.mimeType == "audio/mpeg" || track.mimeType == "audio/aac"
                || track.mimeType == "audio/flac" || track.mimeType == "audio/ogg"
            {
                normalizedContentType = track.mimeType
            } else if let upstreamType = http.value(forHTTPHeaderField: "Content-Type"), upstreamType == "application/mp4" {
                normalizedContentType = "audio/mp4"
            } else {
                normalizedContentType = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            }
            headerText += "Content-Type: \(normalizedContentType)\r\n"
            if let contentLength = http.value(forHTTPHeaderField: "Content-Length") {
                headerText += "Content-Length: \(contentLength)\r\n"
            } else {
                headerText += "Content-Length: \(data.count)\r\n"
            }
            if let contentRange = http.value(forHTTPHeaderField: "Content-Range") {
                headerText += "Content-Range: \(contentRange)\r\n"
            }
            headerText += "Accept-Ranges: \(http.value(forHTTPHeaderField: "Accept-Ranges") ?? "bytes")\r\n"
            headerText += "Connection: close\r\n"
            headerText += "Cache-Control: no-cache\r\n\r\n"

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(
                    content: headerText.data(using: .utf8),
                    completion: .contentProcessed { _ in
                        continuation.resume()
                    }
                )
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(
                    content: data,
                    completion: .contentProcessed { _ in
                        continuation.resume()
                    }
                )
            }
            connection.cancel()
        } catch {
            await sendErrorResponse(connection: connection, status: 502, message: error.localizedDescription)
        }
    }

    private func sendErrorResponse(connection: NWConnection, status: Int, message: String) async {
        let response =
            "HTTP/1.1 \(status) Error\r\nContent-Type: text/plain\r\nContent-Length: \(message.utf8.count)\r\nConnection: close\r\n\r\n\(message)"
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
