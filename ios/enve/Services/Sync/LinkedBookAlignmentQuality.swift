import Foundation

enum LinkedBookAlignmentDefect: String, Codable, Equatable, Sendable {
    case tooFewAnchors
    case malformedAnchors
    case notMonotonic
    case degenerateSpan
}

enum LinkedBookAlignmentRejection: String, Codable, Equatable, Sendable {
    case invalidCandidate
    case inferiorCandidate
}

struct LinkedBookAlignmentQuality: Codable, Equatable, Sendable {
    var unitCount: Int
    var coverage: Double
    var largestGap: Double
    var monotonicity: Double
    var timingConsistency: Double
    var purity: Double
    var confidence: Double?
    var defects: [LinkedBookAlignmentDefect]

    var isUsable: Bool { defects.isEmpty }
}

enum LinkedBookAlignmentDecision: Equatable, Sendable {
    case accepted(LinkedBookAlignmentQuality, explanation: String)
    case rejected(LinkedBookAlignmentRejection, quality: LinkedBookAlignmentQuality, explanation: String)

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    var quality: LinkedBookAlignmentQuality {
        switch self {
        case .accepted(let quality, _), .rejected(_, let quality, _):
            return quality
        }
    }

    var explanation: String {
        switch self {
        case .accepted(_, let explanation), .rejected(_, _, let explanation):
            return explanation
        }
    }
}

enum LinkedBookAlignmentEvaluator {
    struct Assessment: Equatable, Sendable {
        let anchors: [LinkedBookCalibrationAnchor]
        let quality: LinkedBookAlignmentQuality
    }

    private static let minimumStep = 0.002
    private static let minimumSpan = 0.02
    private static let majority = 0.5
    private static let minimumAnchors = 2
    private static let margin = 0.10
    private static let unitCountMargin = 0.25

    static func assess(_ candidate: [LinkedBookCalibrationAnchor]) -> Assessment {
        let usable = candidate.filter(isWellFormed)
        let chain = monotoneChain(usable)
        let purity = candidate.isEmpty ? 0 : Double(usable.count) / Double(candidate.count)
        let monotonicity = usable.isEmpty ? 0 : Double(chain.count) / Double(usable.count)
        let coverage = span(chain)

        var defects: [LinkedBookAlignmentDefect] = []
        if chain.count < minimumAnchors { defects.append(.tooFewAnchors) }
        if purity < majority { defects.append(.malformedAnchors) }
        if monotonicity < majority { defects.append(.notMonotonic) }
        if chain.count >= minimumAnchors, coverage < minimumSpan { defects.append(.degenerateSpan) }

        return Assessment(
            anchors: chain,
            quality: LinkedBookAlignmentQuality(
                unitCount: chain.count,
                coverage: coverage,
                largestGap: largestGap(chain),
                monotonicity: monotonicity,
                timingConsistency: timingConsistency(chain),
                purity: purity,
                confidence: chain.isEmpty
                    ? nil
                    : chain.reduce(0) { $0 + $1.confidence } / Double(chain.count),
                defects: defects
            )
        )
    }

    static func decide(
        candidate: Assessment,
        incumbent: LinkedBookAlignmentQuality?
    ) -> LinkedBookAlignmentDecision {
        guard candidate.quality.isUsable else {
            return .rejected(
                .invalidCandidate,
                quality: candidate.quality,
                explanation: "the new alignment is \(describe(candidate.quality.defects))"
            )
        }
        let accepted = LinkedBookAlignmentDecision.accepted(
            candidate.quality,
            explanation: "saved \(candidate.quality.unitCount) anchors"
        )
        guard let incumbent, incumbent.isUsable else { return accepted }

        let measurements = comparisons(candidate: candidate.quality, incumbent: incumbent)
        let regressions = measurements.filter(\.regressed)
        guard regressions.count > measurements.filter(\.improved).count else { return accepted }
        return .rejected(
            .inferiorCandidate,
            quality: candidate.quality,
            explanation: "the new alignment lost \(regressions.map(\.name).joined(separator: " and "))"
        )
    }

    private struct Comparison {
        let name: String
        let candidate: Double
        let incumbent: Double
        let margin: Double

        var regressed: Bool { incumbent - candidate > margin }
        var improved: Bool { candidate - incumbent > margin }
    }

    private static func comparisons(
        candidate: LinkedBookAlignmentQuality,
        incumbent: LinkedBookAlignmentQuality
    ) -> [Comparison] {
        var measurements = [
            Comparison(
                name: "anchors",
                candidate: Double(candidate.unitCount),
                incumbent: Double(incumbent.unitCount),
                margin: Double(incumbent.unitCount) * unitCountMargin
            ),
            Comparison(
                name: "coverage",
                candidate: candidate.coverage,
                incumbent: incumbent.coverage,
                margin: margin
            ),
            Comparison(
                name: "continuity",
                candidate: 1 - candidate.largestGap,
                incumbent: 1 - incumbent.largestGap,
                margin: margin
            ),
            Comparison(
                name: "ordering",
                candidate: candidate.monotonicity,
                incumbent: incumbent.monotonicity,
                margin: margin
            ),
            Comparison(
                name: "timing consistency",
                candidate: candidate.timingConsistency,
                incumbent: incumbent.timingConsistency,
                margin: margin
            ),
            Comparison(
                name: "well-formed anchors",
                candidate: candidate.purity,
                incumbent: incumbent.purity,
                margin: margin
            ),
        ]
        if let candidateConfidence = candidate.confidence,
            let incumbentConfidence = incumbent.confidence
        {
            measurements.append(
                Comparison(
                    name: "confidence",
                    candidate: candidateConfidence,
                    incumbent: incumbentConfidence,
                    margin: margin
                )
            )
        }
        return measurements
    }

    private static func describe(_ defects: [LinkedBookAlignmentDefect]) -> String {
        defects.map { defect -> String in
            switch defect {
            case .tooFewAnchors: return "too short"
            case .malformedAnchors: return "mostly malformed"
            case .notMonotonic: return "out of order"
            case .degenerateSpan: return "confined to one spot in the book"
            }
        }
        .joined(separator: " and ")
    }

    private static func isWellFormed(_ anchor: LinkedBookCalibrationAnchor) -> Bool {
        anchor.ebookProgress.isFinite
            && anchor.audioProgress.isFinite
            && anchor.confidence.isFinite
            && (0...1).contains(anchor.ebookProgress)
            && (0...1).contains(anchor.audioProgress)
            && (0...1).contains(anchor.confidence)
            && !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func monotoneChain(
        _ anchors: [LinkedBookCalibrationAnchor]
    ) -> [LinkedBookCalibrationAnchor] {
        let ordered = anchors.sorted {
            $0.audioProgress == $1.audioProgress
                ? $0.ebookProgress < $1.ebookProgress
                : $0.audioProgress < $1.audioProgress
        }
        guard !ordered.isEmpty else { return [] }

        var scores = ordered.map(\.confidence)
        var lengths = Array(repeating: 1, count: ordered.count)
        var predecessors = [Int?](repeating: nil, count: ordered.count)
        for upper in ordered.indices {
            for lower in ordered.indices where lower < upper {
                guard ordered[upper].ebookProgress > ordered[lower].ebookProgress + minimumStep,
                    ordered[upper].audioProgress > ordered[lower].audioProgress + minimumStep
                else { continue }
                let candidateScore = scores[lower] + ordered[upper].confidence
                let candidateLength = lengths[lower] + 1
                if candidateScore > scores[upper]
                    || (abs(candidateScore - scores[upper]) < 0.0001
                        && candidateLength > lengths[upper])
                {
                    scores[upper] = candidateScore
                    lengths[upper] = candidateLength
                    predecessors[upper] = lower
                }
            }
        }

        var cursor = ordered.indices.max {
            if abs(scores[$0] - scores[$1]) > 0.0001 {
                return scores[$0] < scores[$1]
            }
            return lengths[$0] < lengths[$1]
        }
        var result: [LinkedBookCalibrationAnchor] = []
        while let index = cursor {
            result.append(ordered[index])
            cursor = predecessors[index]
        }
        return result.reversed()
    }

    private static func span(_ chain: [LinkedBookCalibrationAnchor]) -> Double {
        guard let first = chain.first, let last = chain.last, chain.count >= minimumAnchors else {
            return 0
        }
        return min(
            last.audioProgress - first.audioProgress,
            last.ebookProgress - first.ebookProgress
        )
    }

    private static func largestGap(_ chain: [LinkedBookCalibrationAnchor]) -> Double {
        guard let first = chain.first, let last = chain.last, chain.count >= minimumAnchors else {
            return 1
        }
        var gap = max(first.audioProgress, first.ebookProgress)
        for index in 1..<chain.count {
            gap = max(gap, chain[index].audioProgress - chain[index - 1].audioProgress)
            gap = max(gap, chain[index].ebookProgress - chain[index - 1].ebookProgress)
        }
        gap = max(gap, 1 - last.audioProgress, 1 - last.ebookProgress)
        return min(max(gap, 0), 1)
    }

    private static func timingConsistency(_ chain: [LinkedBookCalibrationAnchor]) -> Double {
        guard chain.count >= 3, let first = chain.first, let last = chain.last else { return 1 }
        let audioSpan = last.audioProgress - first.audioProgress
        let ebookSpan = last.ebookProgress - first.ebookProgress
        guard audioSpan > 0, ebookSpan > 0 else { return 0 }
        let overallRate = ebookSpan / audioSpan

        var deviations: [Double] = []
        for index in 1..<chain.count {
            let audioStep = chain[index].audioProgress - chain[index - 1].audioProgress
            let ebookStep = chain[index].ebookProgress - chain[index - 1].ebookProgress
            guard audioStep > 0, ebookStep > 0 else { continue }
            deviations.append(abs(log(ebookStep / audioStep / overallRate)))
        }
        guard let middle = median(deviations) else { return 1 }
        return 1 / (1 + middle)
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

struct LinkedBookCalibrationVersions: Equatable, Sendable {
    var accepted: [LinkedBookCalibrationAnchor]? = nil
    var acceptedQuality: LinkedBookAlignmentQuality? = nil
    var previous: [LinkedBookCalibrationAnchor]? = nil
    var previousQuality: LinkedBookAlignmentQuality? = nil

    var hasPrevious: Bool { previous?.isEmpty == false }

    @discardableResult
    mutating func install(_ candidate: [LinkedBookCalibrationAnchor]) -> LinkedBookAlignmentDecision {
        let assessment = LinkedBookAlignmentEvaluator.assess(candidate)
        let incumbent = accepted.flatMap { $0.isEmpty ? nil : acceptedQuality ?? LinkedBookAlignmentEvaluator.assess($0).quality }
        let decision = LinkedBookAlignmentEvaluator.decide(candidate: assessment, incumbent: incumbent)
        guard decision.isAccepted else { return decision }

        if let accepted, !accepted.isEmpty {
            previous = accepted
            previousQuality = acceptedQuality
        }
        accepted = assessment.anchors
        acceptedQuality = assessment.quality
        return decision
    }

    @discardableResult
    mutating func restorePrevious() -> Bool {
        guard let previous, !previous.isEmpty else { return false }
        let restoredQuality = previousQuality
        self.previous = accepted
        previousQuality = acceptedQuality
        accepted = previous
        acceptedQuality = restoredQuality
        return true
    }

    mutating func clear() {
        accepted = nil
        acceptedQuality = nil
        previous = nil
        previousQuality = nil
    }
}
