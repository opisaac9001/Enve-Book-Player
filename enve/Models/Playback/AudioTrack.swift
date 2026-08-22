import Foundation

nonisolated public struct AudioTrack: Identifiable, Codable, Equatable, Sendable {
    public let id: String

    public let index: Int

    public let title: String?

    public let filePath: String?

    let contentUrl: String?

    let duration: TimeInterval

    let startOffset: TimeInterval

    let fileSize: Int64?

    let format: String?

    let bitrate: Int?

    let sampleRate: Int?

    let channels: Int?

    let headers: [String: String]?

    nonisolated init(
        id: String = UUID().uuidString,
        index: Int,
        title: String? = nil,
        filePath: String? = nil,
        contentUrl: String? = nil,
        duration: TimeInterval,
        startOffset: TimeInterval,
        fileSize: Int64? = nil,
        format: String? = nil,
        bitrate: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        headers: [String: String]? = nil
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.filePath = filePath
        self.contentUrl = contentUrl
        self.duration = duration
        self.startOffset = startOffset
        self.fileSize = fileSize
        self.format = format
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.channels = channels
        self.headers = headers
    }

    var endOffset: TimeInterval {
        return startOffset + duration
    }

    func contains(globalPosition: TimeInterval) -> Bool {
        return globalPosition >= startOffset && globalPosition < endOffset
    }

    func localOffset(for globalPosition: TimeInterval) -> TimeInterval {
        return max(0, globalPosition - startOffset)
    }

    func globalPosition(for localOffset: TimeInterval) -> TimeInterval {
        return startOffset + localOffset
    }
}

nonisolated extension Array where Element == AudioTrack {
    var totalDuration: TimeInterval {
        return self.reduce(0) { $0 + $1.duration }
    }

    func track(at globalPosition: TimeInterval) -> AudioTrack? {
        return self.first { $0.contains(globalPosition: globalPosition) }
    }

    func trackIndex(for globalPosition: TimeInterval) -> Int? {
        return self.firstIndex { $0.contains(globalPosition: globalPosition) }
    }

    func localPosition(for globalPosition: TimeInterval) -> (trackIndex: Int, localOffset: TimeInterval)? {
        guard let track = self.track(at: globalPosition),
            let index = self.firstIndex(of: track)
        else {
            if let last = self.last, globalPosition >= last.endOffset {
                return (self.count - 1, last.duration)
            }
            return nil
        }
        return (index, track.localOffset(for: globalPosition))
    }

    func globalPosition(trackIndex: Int, localOffset: TimeInterval) -> TimeInterval? {
        guard trackIndex >= 0 && trackIndex < self.count else { return nil }
        return self[trackIndex].globalPosition(for: localOffset)
    }
}
