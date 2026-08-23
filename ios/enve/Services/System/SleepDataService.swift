import Foundation
import HealthKit
import Logging

nonisolated struct SleepAnalysisSample: Sendable, Equatable {
    let start: Date
    let end: Date
    let value: Int
    let sourceId: String
    let sourceName: String
}

actor SleepDataService {
    static let shared = SleepDataService()

    private let store = HKHealthStore()
    private let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private static let authRequestedKey = "com.enve.sleepDataService.authRequested"

    private let maxRewindInterval: TimeInterval = 2 * 3600

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    nonisolated var hasRequestedAuthorization: Bool {
        UserDefaults.standard.bool(forKey: Self.authRequestedKey)
    }

    func requestAuthorization() async throws {
        guard isAvailable else { return }
        try await store.requestAuthorization(toShare: [], read: [sleepType])
        UserDefaults.standard.set(true, forKey: Self.authRequestedKey)
    }

    func fetchSleepAnalysis(daysBack: Int) async throws -> [SleepAnalysisSample] {
        guard isAvailable else { return [] }

        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -daysBack, to: now)
            ?? now.addingTimeInterval(-Double(daysBack) * 86_400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: now, options: [])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    AppLogger.player.error("[SleepData] HealthKit range query failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                    return
                }
                let mapped = (samples as? [HKCategorySample] ?? []).map { sample in
                    SleepAnalysisSample(
                        start: sample.startDate,
                        end: sample.endDate,
                        value: sample.value,
                        sourceId: sample.sourceRevision.source.bundleIdentifier,
                        sourceName: sample.sourceRevision.source.name
                    )
                }
                continuation.resume(returning: mapped)
            }
            store.execute(query)
        }
    }

    func fetchSleepOnset(after date: Date) async -> Date? {
        guard isAvailable else { return nil }

        let endBound = date.addingTimeInterval(maxRewindInterval)
        let predicate = HKQuery.predicateForSamples(
            withStart: date,
            end: endBound,
            options: .strictStartDate
        )

        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
        ]

        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: 20,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    AppLogger.player.error("[SleepData] HealthKit query failed: \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                let onset = (samples as? [HKCategorySample])?
                    .first { asleepValues.contains($0.value) }?
                    .startDate
                continuation.resume(returning: onset)
            }
            store.execute(query)
        }
    }
}
