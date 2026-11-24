import Foundation

enum CastPlaybackError: LocalizedError, Equatable {
    case readAloudUnsupported
    case localMediaUnsupported
    case headerAuthenticatedStream
    case receiverCannotReachStream
    case emptySession
    case invalidTimeline
    case loadFailed
    case notConnected

    var errorDescription: String? {
        switch self {
        case .readAloudUnsupported:
            "Read-aloud books can't be cast. Disconnect from the Cast device to play this book here."
        case .localMediaUnsupported:
            "This book is only available on this device and can't be cast."
        case .headerAuthenticatedStream:
            "This server requires sign-in details that Cast devices can't send."
        case .receiverCannotReachStream:
            "The Cast device can't reach or verify this server's stream."
        case .emptySession:
            "The server didn't return any audio to cast."
        case .invalidTimeline:
            "The server's track list for this book is incomplete, so it can't be cast."
        case .loadFailed:
            "The Cast device couldn't start playback."
        case .notConnected:
            "The Cast device disconnected."
        }
    }
}

enum CastCompatibility {
    private static let credentialHeaderNames: Set<String> = [
        "authorization", "x-plex-token", "x-emby-token", "x-emby-authorization", "x-mediabrowser-token",
    ]
    private static let credentialQueryNames: Set<String> = [
        "token", "api_key", "apikey", "x-plex-token", "access_token", "signature", "sig", "x-amz-signature",
    ]
    private static let privateHostSuffixes = [".ts.net", ".local", ".lan", ".home", ".internal"]

    /// The default receiver sends no custom headers and can't trust private certificates.
    static func receiverURL(for contentURL: String, streamingHeaders: [String: String]) throws -> URL {
        guard let url = URL(string: contentURL),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host?.lowercased(), !host.isEmpty
        else {
            throw CastPlaybackError.localMediaUnsupported
        }
        guard url.user == nil, url.password == nil else { throw CastPlaybackError.headerAuthenticatedStream }
        guard !isLoopback(host) else { throw CastPlaybackError.localMediaUnsupported }
        guard scheme == "http" || receiverCanValidate(host: host) else {
            throw CastPlaybackError.receiverCannotReachStream
        }

        let headerNames = Set(streamingHeaders.filter { !$0.value.isEmpty }.keys.map { $0.lowercased() })
        guard headerNames.isSubset(of: credentialHeaderNames) else { throw CastPlaybackError.headerAuthenticatedStream }
        if !headerNames.isEmpty {
            let queryNames = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { !($0.value ?? "").isEmpty }
                .map { $0.name.lowercased() } ?? []
            guard queryNames.contains(where: credentialQueryNames.contains) else {
                throw CastPlaybackError.headerAuthenticatedStream
            }
        }
        return url
    }

    static func receiverCanValidate(host: String) -> Bool {
        if host.hasSuffix(".plex.direct") { return true }
        if privateHostSuffixes.contains(where: host.hasSuffix) { return false }
        return !isIPLiteral(host)
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }
}

struct CastProgressSample: Equatable {
    let position: TimeInterval
    let updatedAt: Date
}

enum CastResumePolicy {
    /// The newest local record wins, so a deliberate rewind is kept; server progress is adopted only when newer.
    static func resumePosition(
        local: [CastProgressSample],
        server: CastProgressSample?,
        tolerance: TimeInterval
    ) -> TimeInterval {
        let latestLocal = local.filter { $0.position.isFinite && $0.position >= 0 }.max { $0.updatedAt < $1.updatedAt }
        guard let server, server.position.isFinite, server.position > 0 else { return latestLocal?.position ?? 0 }
        guard let latestLocal else { return server.position }
        let serverIsNewer = server.updatedAt > latestLocal.updatedAt
        return serverIsNewer && abs(server.position - latestLocal.position) > tolerance ? server.position : latestLocal.position
    }
}

struct CastQueueEntry: Equatable {
    let trackIndex: Int
    let url: URL
    let mimeType: String
    let title: String?
    let startOffset: TimeInterval
    let duration: TimeInterval
}

struct CastMediaPlan: Equatable {
    let entries: [CastQueueEntry]
    let startIndex: Int
    let startTime: TimeInterval

    init(tracks: [AudioTrackInfo], resumeAt globalTime: TimeInterval, streamingHeaders: [String: String]) throws {
        let ordered = tracks.sorted {
            $0.startOffset == $1.startOffset ? $0.index < $1.index : $0.startOffset < $1.startOffset
        }
        guard !ordered.isEmpty else { throw CastPlaybackError.emptySession }
        try Self.validateTimeline(ordered)
        entries = try ordered.enumerated().map { position, track in
            CastQueueEntry(
                trackIndex: position,
                url: try CastCompatibility.receiverURL(for: track.contentUrl, streamingHeaders: streamingHeaders),
                mimeType: track.mimeType.isEmpty ? "audio/mpeg" : track.mimeType,
                title: track.title,
                startOffset: track.startOffset,
                duration: track.duration
            )
        }
        let state = ordered.playbackState(at: max(0, globalTime))
        startIndex = state?.index ?? 0
        startTime = state?.localTime ?? 0
    }

    /// Receiver seeks address one queue item, so every track but the last needs a known, non-overlapping span.
    private static func validateTimeline(_ tracks: [AudioTrackInfo]) throws {
        for (index, track) in tracks.enumerated() {
            guard track.startOffset.isFinite, track.startOffset >= 0,
                track.duration.isFinite, track.duration >= 0
            else { throw CastPlaybackError.invalidTimeline }
            guard index + 1 < tracks.count else { continue }
            guard track.duration > 0, tracks[index + 1].startOffset >= track.startOffset + track.duration - 1 else {
                throw CastPlaybackError.invalidTimeline
            }
        }
    }

    var duration: TimeInterval {
        entries.last.map { $0.startOffset + max(0, $0.duration) } ?? 0
    }

    var startPosition: TimeInterval {
        globalPosition(trackIndex: startIndex, localPosition: startTime)
    }

    func globalPosition(trackIndex: Int, localPosition: TimeInterval) -> TimeInterval {
        guard entries.indices.contains(trackIndex) else { return max(0, localPosition) }
        let entry = entries[trackIndex]
        let local = entry.duration > 0 ? min(max(0, localPosition), entry.duration) : max(0, localPosition)
        return entry.startOffset + local
    }

    func target(forGlobalPosition globalTime: TimeInterval) -> (trackIndex: Int, localPosition: TimeInterval) {
        let clamped = max(0, duration > 0 ? min(globalTime, duration) : globalTime)
        guard let index = entries.lastIndex(where: { $0.startOffset <= clamped }) else { return (0, 0) }
        let entry = entries[index]
        let local = clamped - entry.startOffset
        return (index, entry.duration > 0 ? min(local, entry.duration) : local)
    }
}
