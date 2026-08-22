import Foundation

struct RelativeTrackSeekTarget: Equatable {
    let index: Int
    let position: TimeInterval
}

func resolveRelativeTrackSeek(
    durations: [TimeInterval],
    currentIndex: Int,
    currentPosition: TimeInterval,
    delta: TimeInterval
) -> RelativeTrackSeekTarget {
    guard !durations.isEmpty else {
        return RelativeTrackSeekTarget(index: 0, position: max(0, currentPosition + delta))
    }

    var index = min(max(currentIndex, 0), durations.count - 1)
    var position = max(0, currentPosition) + delta

    while position < 0, index > 0 {
        let previousDuration = durations[index - 1]
        guard previousDuration > 0 else {
            return RelativeTrackSeekTarget(index: index, position: 0)
        }
        index -= 1
        position += previousDuration
    }

    while index < durations.count - 1 {
        let duration = durations[index]
        guard duration > 0, position > duration else { break }
        position -= duration
        index += 1
    }

    let duration = durations[index]
    return RelativeTrackSeekTarget(
        index: index,
        position: duration > 0 ? min(max(0, position), duration) : max(0, position)
    )
}

extension AudioTrackInfo {
    var endOffset: Double {
        return startOffset + duration
    }

    func contains(globalTime: TimeInterval) -> Bool {
        return globalTime >= startOffset && globalTime < endOffset
    }

    func localTime(for globalTime: TimeInterval) -> TimeInterval {
        let local = max(0, globalTime - startOffset)
        guard duration > 0 else { return local }
        return min(duration, local)
    }

    func globalTime(for localTime: TimeInterval) -> TimeInterval {
        return startOffset + localTime
    }
}

extension Array where Element == AudioTrackInfo {
    var totalDuration: TimeInterval {
        return self.reduce(0) { $0 + $1.duration }
    }

    func track(at globalTime: TimeInterval) -> AudioTrackInfo? {
        guard !self.isEmpty else { return nil }

        let ordered = self.sorted {
            if $0.startOffset == $1.startOffset {
                return $0.index < $1.index
            }
            return $0.startOffset < $1.startOffset
        }

        if globalTime <= ordered[0].startOffset {
            return ordered[0]
        }

        for idx in ordered.indices {
            let track = ordered[idx]
            if track.contains(globalTime: globalTime) {
                return track
            }

            if idx + 1 < ordered.count {
                let nextStart = ordered[idx + 1].startOffset
                if globalTime > track.endOffset && globalTime < nextStart {
                    return track
                }
            }
        }

        return ordered.last
    }

    func trackIndex(at globalTime: TimeInterval) -> Int? {
        return playbackState(at: globalTime)?.index
    }

    func playbackState(at globalTime: TimeInterval) -> (track: AudioTrackInfo, localTime: TimeInterval, index: Int)? {
        guard !self.isEmpty else { return nil }

        guard let track = self.track(at: globalTime) else {
            return nil
        }

        guard
            let index = self.firstIndex(where: {
                $0.startOffset == track.startOffset && $0.contentUrl == track.contentUrl
            })
        else {
            return nil
        }

        let local = track.localTime(for: globalTime)
        return (track, local, index)
    }
}
