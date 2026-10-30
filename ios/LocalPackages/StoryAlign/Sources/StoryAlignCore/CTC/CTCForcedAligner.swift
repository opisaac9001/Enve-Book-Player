import Foundation

struct CTCEmissions: Codable, Sendable {
    let values: [Float]
    let frames: Int
    let classes: Int
    let secondsPerFrame: Double

    func slice(_ range: Range<Int>) -> CTCEmissions {
        CTCEmissions(values: Array(values[(range.lowerBound * classes)..<(range.upperBound * classes)]), frames: range.count, classes: classes, secondsPerFrame: secondsPerFrame)
    }
}

struct CTCCharacterAlignment: Sendable {
    let label: Int
    let startFrame: Int
    let endFrame: Int
    let meanLogProbability: Float
}

enum CTCForcedAligner {
    static let maximumCells = 8_000_000

    static func align(_ emissions: CTCEmissions, labels: [Int], blank: Int) throws -> [CTCCharacterAlignment]? {
        guard !labels.isEmpty, emissions.frames > 0, emissions.classes > 1,
              emissions.values.count == emissions.frames * emissions.classes,
              (0..<emissions.classes).contains(blank),
              labels.allSatisfy({ (0..<emissions.classes).contains($0) && $0 != blank })
        else { return nil }
        let minimumFrames = labels.count + zip(labels, labels.dropFirst()).filter { $0 == $1 }.count
        guard emissions.frames >= minimumFrames else { return nil }
        let states = labels.count * 2 + 1
        guard states <= maximumCells / emissions.frames else { return nil }
        let tokens = (0..<states).map { $0.isMultiple(of: 2) ? blank : labels[$0 / 2] }
        var previous = [Float](repeating: -.infinity, count: states)
        var current = previous
        var traceback = [UInt8](repeating: 0, count: states * emissions.frames)
        previous[0] = 0
        previous[1] = emissions.values[labels[0]] - emissions.values[0..<emissions.classes].max()!
        var terminalFrame = -1
        var terminalState = -1
        var bestTerminal: Float = -.infinity

        for frame in 0..<emissions.frames {
            if frame.isMultiple(of: 64) { try Task.checkCancellation() }
            if frame > 0 {
                let baseline = emissions.values[(frame * emissions.classes)..<((frame + 1) * emissions.classes)].max()!
                current[0] = 0
                for state in 1..<states {
                    var score = previous[state]
                    var step: UInt8 = 0
                    if previous[state - 1] > score { score = previous[state - 1]; step = 1 }
                    if state > 1, !state.isMultiple(of: 2), tokens[state] != tokens[state - 2], previous[state - 2] > score {
                        score = previous[state - 2]
                        step = 2
                    }
                    current[state] = score + emissions.values[frame * emissions.classes + tokens[state]] - baseline
                    traceback[frame * states + state] = step
                }
                swap(&previous, &current)
            }
            // End on the final character; surrounding audio is not forced to be silence.
            let state = states - 2
            if previous[state] >= bestTerminal {
                bestTerminal = previous[state]
                terminalFrame = frame
                terminalState = state
            }
        }
        guard bestTerminal.isFinite else { return nil }
        var first = [Int](repeating: -1, count: labels.count)
        var last = first
        var sums = [Float](repeating: 0, count: labels.count)
        var counts = [Int](repeating: 0, count: labels.count)
        var state = terminalState
        var frame = terminalFrame
        while frame >= 0 && state > 0 {
            if !state.isMultiple(of: 2) {
                let index = state / 2
                first[index] = frame
                if last[index] < 0 { last[index] = frame }
                sums[index] += emissions.values[frame * emissions.classes + labels[index]]
                counts[index] += 1
            }
            if frame > 0 { state -= Int(traceback[frame * states + state]) }
            frame -= 1
        }
        guard counts.allSatisfy({ $0 > 0 }) else { return nil }
        return labels.indices.map {
            CTCCharacterAlignment(label: labels[$0], startFrame: first[$0], endFrame: last[$0] + 1, meanLogProbability: sums[$0] / Float(counts[$0]))
        }
    }
}
