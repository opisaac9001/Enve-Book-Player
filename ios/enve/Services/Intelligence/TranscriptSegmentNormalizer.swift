import Foundation

enum TranscriptSegmentNormalizer {
    static func normalize(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let ordered =
            segments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    if lhs.endTime == rhs.endTime {
                        return lhs.trackIndex < rhs.trackIndex
                    }
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }

        guard !ordered.isEmpty else { return [] }

        var normalized: [TranscriptSegment] = []
        normalized.reserveCapacity(ordered.count)

        for segment in ordered {
            guard let previous = normalized.last else {
                normalized.append(segment)
                continue
            }

            guard shouldCollapse(segment, into: previous) else {
                normalized.append(segment)
                continue
            }

            normalized[normalized.count - 1] = mergedSegment(previous, segment)
        }

        return normalized
    }

    static func mergedText(from segments: [TranscriptSegment]) -> String {
        let fragments =
            segments
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard var merged = fragments.first else { return "" }
        for fragment in fragments.dropFirst() {
            merged = mergeTextFragments(merged, fragment)
        }

        return
            merged
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func shouldCollapse(_ next: TranscriptSegment, into previous: TranscriptSegment) -> Bool {
        guard previous.trackIndex == next.trackIndex else { return false }

        let previousNormalized = normalizedText(previous.text)
        let nextNormalized = normalizedText(next.text)
        guard !previousNormalized.isEmpty, !nextNormalized.isEmpty else { return false }

        let startsClose = abs(next.startTime - previous.startTime) <= 4
        let overlapsInTime = next.startTime <= previous.endTime + 0.8

        if startsClose && previousNormalized == nextNormalized {
            return true
        }

        if overlapsInTime && (previousNormalized.contains(nextNormalized) || nextNormalized.contains(previousNormalized)) {
            return true
        }

        return false
    }

    private static func mergedSegment(_ lhs: TranscriptSegment, _ rhs: TranscriptSegment) -> TranscriptSegment {
        let preferred = preferredSegment(between: lhs, and: rhs)
        return TranscriptSegment(
            id: preferred.id,
            bookStableId: preferred.bookStableId,
            chapterId: preferred.chapterId ?? (preferred.id == lhs.id ? rhs.chapterId : lhs.chapterId),
            trackIndex: preferred.trackIndex,
            startTime: min(lhs.startTime, rhs.startTime),
            endTime: max(lhs.endTime, rhs.endTime),
            text: mergeTextFragments(lhs.text, rhs.text),
            confidence: preferred.confidence ?? (preferred.id == lhs.id ? rhs.confidence : lhs.confidence),
            isFinal: lhs.isFinal || rhs.isFinal
        )
    }

    private static func preferredSegment(between lhs: TranscriptSegment, and rhs: TranscriptSegment) -> TranscriptSegment {
        let lhsNormalized = normalizedText(lhs.text)
        let rhsNormalized = normalizedText(rhs.text)

        if rhsNormalized.count > lhsNormalized.count {
            return rhs
        }
        if lhsNormalized.count > rhsNormalized.count {
            return lhs
        }

        let lhsDuration = lhs.endTime - lhs.startTime
        let rhsDuration = rhs.endTime - rhs.startTime
        return rhsDuration >= lhsDuration ? rhs : lhs
    }

    private static func mergeTextFragments(_ lhs: String, _ rhs: String) -> String {
        let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }

        let leftNormalized = normalizedText(left)
        let rightNormalized = normalizedText(right)

        if leftNormalized == rightNormalized || leftNormalized.contains(rightNormalized) {
            return left
        }
        if rightNormalized.contains(leftNormalized) {
            return right
        }

        let leftWords = wordTokens(from: left)
        let rightWords = wordTokens(from: right)
        let leftNormalizedWords = leftWords.map(normalizedWord)
        let rightNormalizedWords = rightWords.map(normalizedWord)
        let maxOverlap = min(12, leftWords.count, rightWords.count)

        if maxOverlap >= 2 {
            for overlap in stride(from: maxOverlap, through: 2, by: -1) {
                let leftSuffix = Array(leftNormalizedWords.suffix(overlap))
                let rightPrefix = Array(rightNormalizedWords.prefix(overlap))
                if leftSuffix == rightPrefix {
                    let suffix = rightWords.dropFirst(overlap).joined(separator: " ")
                    guard !suffix.isEmpty else { return left }
                    return "\(left) \(suffix)"
                }
            }
        }

        return "\(left) \(right)"
    }

    private static func wordTokens(from text: String) -> [String] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedWord(_ word: String) -> String {
        normalizedText(word)
    }
}
