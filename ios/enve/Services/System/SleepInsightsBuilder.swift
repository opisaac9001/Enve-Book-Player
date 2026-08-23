import Foundation
import HealthKit

enum SleepStageKind: CaseIterable, Hashable, Sendable {
    case awake, rem, core, deep, unspecified

    var label: String {
        switch self {
        case .awake: "Awake"
        case .rem: "REM"
        case .core: "Core"
        case .deep: "Deep"
        case .unspecified: "Asleep"
        }
    }
}

struct SleepStageSegment: Identifiable, Sendable {
    let start: Date
    let end: Date
    let kind: SleepStageKind

    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct SleepNightListening: Sendable {
    let bookId: String
    let secondsBeforeOnset: TimeInterval
    let gapToOnset: TimeInterval?
    let secondsAfterOnset: TimeInterval
}

struct SleepNight: Identifiable, Sendable {
    let id: Date
    let bedtime: Date?
    let sleepOnset: Date
    let wakeTime: Date
    let totalSleep: TimeInterval
    let stageDurations: [SleepStageKind: TimeInterval]
    let segments: [SleepStageSegment]
    let latency: TimeInterval?
    let efficiency: Double?
    let awakenings: Int
    let hasStageDetail: Bool
    let sourceName: String
    var listening: SleepNightListening?

    var hadBedtimeListening: Bool {
        (listening?.secondsBeforeOnset ?? 0) >= SleepInsightsBuilder.bedtimeListeningThreshold
    }
}

struct SleepListeningComparison: Sendable {
    let nightsWith: Int
    let nightsWithout: Int
    let averageSleepWith: TimeInterval
    let averageSleepWithout: TimeInterval
    let averageLatencyWith: TimeInterval?
    let averageLatencyWithout: TimeInterval?
    let averageEfficiencyWith: Double?
    let averageEfficiencyWithout: Double?
    let averageREMWith: Double?
    let averageREMWithout: Double?
    let averageDeepWith: Double?
    let averageDeepWithout: Double?
}

struct SleepInsightsSummary: Sendable {
    let nights: [SleepNight]
    let averageSleep: TimeInterval
    let averageBedtimeOffset: TimeInterval?
    let averageWakeOffset: TimeInterval?
    let comparison: SleepListeningComparison?
    let historyStart: Date?
    let averageBedtimeListening: TimeInterval?
    let averagePlaybackAfterOnset: TimeInterval?
    let topBedtimeBookId: String?
}

enum SleepInsightsBuilder {
    static let preSleepWindow: TimeInterval = 3 * 3600
    static let bedtimeListeningThreshold: TimeInterval = 300
    private static let minNightSleep: TimeInterval = 3600
    private static let noonOffset: TimeInterval = 43_200
    private static let maxStageGap: TimeInterval = 2 * 3600

    static func summary(
        samples: [SleepAnalysisSample],
        sessions: [HistorySession],
        calendar: Calendar = .current
    ) -> SleepInsightsSummary? {
        let listening = sessions.filter { $0.mediaType == "audiobook" && $0.endTime > $0.startTime }
        let nights = buildNights(samples: samples, calendar: calendar)
            .map { attachListening(to: $0, sessions: listening) }
        guard !nights.isEmpty else { return nil }

        let historyStart = listening.map(\.startTime).min()
        let linked = nights.compactMap(\.listening).filter { $0.secondsBeforeOnset >= bedtimeListeningThreshold }
        let continued = linked.filter { $0.secondsAfterOnset > 0 }
        let secondsByBook = Dictionary(grouping: linked, by: \.bookId)
            .mapValues { $0.reduce(0) { $0 + $1.secondsBeforeOnset } }

        return SleepInsightsSummary(
            nights: nights,
            averageSleep: nights.map(\.totalSleep).reduce(0, +) / Double(nights.count),
            averageBedtimeOffset: average(
                nights.map { ($0.bedtime ?? $0.sleepOnset).timeIntervalSince($0.id.addingTimeInterval(noonOffset)) }
            ),
            averageWakeOffset: average(
                nights.map { $0.wakeTime.timeIntervalSince($0.id.addingTimeInterval(noonOffset)) }
            ),
            comparison: comparison(nights: nights, historyStart: historyStart),
            historyStart: historyStart,
            averageBedtimeListening: average(linked.map(\.secondsBeforeOnset)),
            averagePlaybackAfterOnset: average(continued.map(\.secondsAfterOnset)),
            topBedtimeBookId: secondsByBook.max(by: { $0.value < $1.value })?.key
        )
    }

    private static func buildNights(samples: [SleepAnalysisSample], calendar: Calendar) -> [SleepNight] {
        Dictionary(grouping: samples) { calendar.startOfDay(for: $0.start.addingTimeInterval(-noonOffset)) }
            .compactMap { night(id: $0.key, samples: $0.value) }
            .filter { $0.totalSleep >= minNightSleep }
            .sorted { $0.id > $1.id }
    }

    private struct SourceCandidate {
        let sourceId: String
        let sourceName: String
        let segments: [SleepStageSegment]
        let asleep: TimeInterval
        let detail: TimeInterval

        var score: TimeInterval { asleep + detail }
    }

    private static func night(id: Date, samples: [SleepAnalysisSample]) -> SleepNight? {
        let candidates = Dictionary(grouping: samples, by: \.sourceId).values.flatMap(sourceCandidates)
        guard let best = candidates.max(by: candidateRanksBefore), best.asleep > 0 else { return nil }

        let asleep = best.segments.filter { $0.kind != .awake }
        guard let onset = asleep.first?.start, let wakeTime = asleep.last?.end else { return nil }

        var stageDurations: [SleepStageKind: TimeInterval] = [:]
        for segment in best.segments {
            stageDurations[segment.kind, default: 0] += segment.duration
        }

        let inBedValue = HKCategoryValueSleepAnalysis.inBed.rawValue
        let overlappingInBed = samples.filter {
            $0.value == inBedValue && $0.start < wakeTime && $0.end > onset
        }
        let preferredInBed = overlappingInBed.filter { $0.sourceId == best.sourceId }
        let inBed = (preferredInBed.isEmpty ? overlappingInBed : preferredInBed).max {
            overlap($0, onset: onset, wakeTime: wakeTime) < overlap($1, onset: onset, wakeTime: wakeTime)
        }
        let bedtime = inBed.map { min($0.start, onset) }
        let inBedEnd = inBed.map { max($0.end, wakeTime) } ?? wakeTime
        let timeInBed = bedtime.map { inBedEnd.timeIntervalSince($0) }
        let awakenings = best.segments.filter {
            $0.kind == .awake && $0.start >= onset && $0.end <= wakeTime && $0.duration >= 60
        }.count

        return SleepNight(
            id: id,
            bedtime: bedtime,
            sleepOnset: onset,
            wakeTime: wakeTime,
            totalSleep: best.asleep,
            stageDurations: stageDurations,
            segments: best.segments,
            latency: bedtime.map { max(0, onset.timeIntervalSince($0)) },
            efficiency: timeInBed.flatMap { $0 > 0 ? min(1, best.asleep / $0) : nil },
            awakenings: awakenings,
            hasStageDetail: best.detail > 0,
            sourceName: best.sourceName,
            listening: nil
        )
    }

    private static func sourceCandidates(_ samples: [SleepAnalysisSample]) -> [SourceCandidate] {
        let stageSamples = samples.filter { kind(forValue: $0.value) != nil }.sorted { $0.start < $1.start }
        guard let first = stageSamples.first else { return [] }

        var clusters: [[SleepAnalysisSample]] = [[first]]
        var clusterEnd = first.end
        for sample in stageSamples.dropFirst() {
            if sample.start.timeIntervalSince(clusterEnd) > maxStageGap {
                clusters.append([sample])
            } else {
                clusters[clusters.count - 1].append(sample)
            }
            clusterEnd = max(clusterEnd, sample.end)
        }

        return clusters.compactMap { cluster in
            let segments = normalizedSegments(cluster)
            let asleep = segments.filter { $0.kind != .awake }.reduce(0) { $0 + $1.duration }
            guard asleep > 0 else { return nil }
            let detail = segments.filter { $0.kind == .rem || $0.kind == .core || $0.kind == .deep }
                .reduce(0) { $0 + $1.duration }
            return SourceCandidate(
                sourceId: first.sourceId,
                sourceName: first.sourceName,
                segments: segments,
                asleep: asleep,
                detail: detail
            )
        }
    }

    private static func normalizedSegments(_ samples: [SleepAnalysisSample]) -> [SleepStageSegment] {
        let typed = samples.compactMap { sample -> (sample: SleepAnalysisSample, kind: SleepStageKind)? in
            guard let kind = kind(forValue: sample.value) else { return nil }
            return (sample, kind)
        }
        let boundaries = Set(typed.flatMap { [$0.sample.start, $0.sample.end] }).sorted()
        var segments: [SleepStageSegment] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
            let covering = typed.filter { $0.sample.start < end && $0.sample.end > start }
            guard let kind = covering.max(by: { stagePriority($0.kind) < stagePriority($1.kind) })?.kind else {
                continue
            }
            if let last = segments.last, last.kind == kind, start.timeIntervalSince(last.end) < 1 {
                segments[segments.count - 1] = SleepStageSegment(start: last.start, end: end, kind: kind)
            } else {
                segments.append(SleepStageSegment(start: start, end: end, kind: kind))
            }
        }
        return segments
    }

    private static func stagePriority(_ kind: SleepStageKind) -> Int {
        switch kind {
        case .awake: 3
        case .rem, .core, .deep: 2
        case .unspecified: 1
        }
    }

    private static func candidateRanksBefore(_ lhs: SourceCandidate, _ rhs: SourceCandidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score < rhs.score }
        return lhs.asleep < rhs.asleep
    }

    private static func overlap(_ sample: SleepAnalysisSample, onset: Date, wakeTime: Date) -> TimeInterval {
        max(0, min(sample.end, wakeTime).timeIntervalSince(max(sample.start, onset)))
    }

    private static func attachListening(to night: SleepNight, sessions: [HistorySession]) -> SleepNight {
        let windowStart = night.sleepOnset.addingTimeInterval(-preSleepWindow)
        let relevant = sessions.filter { $0.startTime < night.sleepOnset && $0.endTime > windowStart }
        let secondsBefore = relevant.reduce(0.0) {
            $0 + max(0, min($1.endTime, night.sleepOnset).timeIntervalSince(max($1.startTime, windowStart)))
        }
        guard secondsBefore >= 60, let last = relevant.max(by: { $0.endTime < $1.endTime }) else { return night }

        let after = relevant.reduce(0.0) {
            $0 + max(0, min($1.endTime, night.wakeTime).timeIntervalSince(max($1.startTime, night.sleepOnset)))
        }
        var updated = night
        updated.listening = SleepNightListening(
            bookId: last.bookId,
            secondsBeforeOnset: secondsBefore,
            gapToOnset: after > 0 ? nil : max(0, night.sleepOnset.timeIntervalSince(last.endTime)),
            secondsAfterOnset: after
        )
        return updated
    }

    private static func comparison(
        nights: [SleepNight],
        historyStart: Date?
    ) -> SleepListeningComparison? {
        guard let historyStart else { return nil }
        let eligible = nights.filter { $0.sleepOnset >= historyStart }
        let with = eligible.filter(\.hadBedtimeListening)
        let without = eligible.filter { !$0.hadBedtimeListening }
        guard let sleepWith = average(with.map(\.totalSleep)),
            let sleepWithout = average(without.map(\.totalSleep))
        else { return nil }

        return SleepListeningComparison(
            nightsWith: with.count,
            nightsWithout: without.count,
            averageSleepWith: sleepWith,
            averageSleepWithout: sleepWithout,
            averageLatencyWith: average(with.compactMap(\.latency)),
            averageLatencyWithout: average(without.compactMap(\.latency)),
            averageEfficiencyWith: average(with.compactMap(\.efficiency)),
            averageEfficiencyWithout: average(without.compactMap(\.efficiency)),
            averageREMWith: average(with.compactMap { stageFraction(.rem, night: $0) }),
            averageREMWithout: average(without.compactMap { stageFraction(.rem, night: $0) }),
            averageDeepWith: average(with.compactMap { stageFraction(.deep, night: $0) }),
            averageDeepWithout: average(without.compactMap { stageFraction(.deep, night: $0) })
        )
    }

    private static func stageFraction(_ kind: SleepStageKind, night: SleepNight) -> Double? {
        guard night.totalSleep > 0, let seconds = night.stageDurations[kind], seconds > 0 else { return nil }
        return seconds / night.totalSleep
    }

    private static func kind(forValue value: Int) -> SleepStageKind? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .awake: .awake
        case .asleepREM: .rem
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepUnspecified: .unspecified
        default: nil
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

#if DEBUG
enum SleepInsightsFixture {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-sleepInsightsFixture")
    }

    static let bookTitles = [
        "fixture-night-circus": "The Night Circus",
        "fixture-hail-mary": "Project Hail Mary",
    ]

    static func samples(reference: Date, calendar: Calendar = .current) -> [SleepAnalysisSample] {
        var samples: [SleepAnalysisSample] = []
        for back in 1...14 {
            guard let anchor = anchor(back: back, reference: reference, calendar: calendar) else { continue }
            var cursor = anchor.onset
            func stage(_ minutes: Int, _ value: HKCategoryValueSleepAnalysis) {
                let end = cursor.addingTimeInterval(TimeInterval(minutes) * 60)
                samples.append(
                    SleepAnalysisSample(
                        start: cursor,
                        end: end,
                        value: value.rawValue,
                        sourceId: "fixture.watch",
                        sourceName: "Apple Watch"
                    )
                )
                cursor = end
            }
            for cycle in 0..<4 {
                stage(42 + (back + cycle * 7) % 16, .asleepCore)
                stage(cycle < 2 ? 20 + back % 9 : 8, .asleepDeep)
                stage(11 + cycle * 5 + back % 7, .asleepREM)
                if (back + cycle) % 3 == 0 { stage(3 + (back + cycle) % 5, .awake) }
            }
            samples.append(
                SleepAnalysisSample(
                    start: anchor.bedtime,
                    end: cursor,
                    value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                    sourceId: "fixture.phone",
                    sourceName: "iPhone"
                )
            )
            samples.append(
                SleepAnalysisSample(
                    start: anchor.onset,
                    end: cursor,
                    value: HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
                    sourceId: "fixture.phone",
                    sourceName: "iPhone"
                )
            )
        }
        return samples
    }

    static func sessions(reference: Date, calendar: Calendar = .current) -> [HistorySession] {
        var sessions: [HistorySession] = []
        for back in stride(from: 2, through: 14, by: 2) {
            guard let anchor = anchor(back: back, reference: reference, calendar: calendar) else { continue }
            let spillsPastOnset = back % 6 == 2
            let end =
                spillsPastOnset
                ? anchor.onset.addingTimeInterval(12 * 60)
                : anchor.onset.addingTimeInterval(-TimeInterval((9 + back % 8) * 60))
            let start = end.addingTimeInterval(-TimeInterval((35 + back % 20) * 60))
            sessions.append(
                HistorySession(
                    id: "fixture-session-\(back)",
                    bookId: spillsPastOnset ? "fixture-hail-mary" : "fixture-night-circus",
                    mediaType: "audiobook",
                    startTime: start,
                    endTime: end,
                    durationSeconds: Int(end.timeIntervalSince(start)),
                    startProgress: nil,
                    endProgress: nil,
                    progressDelta: nil,
                    startLocation: nil,
                    endLocation: nil,
                    pagesRead: nil,
                    source: .local
                )
            )
        }
        return sessions
    }

    private static func anchor(back: Int, reference: Date, calendar: Calendar) -> (bedtime: Date, onset: Date)? {
        let noonToday = calendar.startOfDay(for: reference).addingTimeInterval(43_200)
        guard let noon = calendar.date(byAdding: .day, value: -back, to: noonToday) else { return nil }
        let bedtime = noon.addingTimeInterval(TimeInterval(10 * 3600 + ((back * 37) % 55) * 60))
        let onset = bedtime.addingTimeInterval(TimeInterval((7 + (back * 13) % 21) * 60))
        return (bedtime, onset)
    }
}
#endif
