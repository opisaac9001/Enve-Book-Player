import Foundation

nonisolated struct PassageBufferPolicy {
    private(set) var rate: Double?

    mutating func record(audioSeconds: Double, wallSeconds: Double) {
        guard audioSeconds.isFinite, wallSeconds.isFinite, audioSeconds > 0, wallSeconds > 0 else { return }
        let measured = audioSeconds / wallSeconds
        rate = rate.map { $0 * 0.6 + measured * 0.4 } ?? measured
    }

    var listeningSecondsAhead: Double {
        min(600, max(120, rate.map { 38 / $0 * 3 } ?? 0))
    }
}
