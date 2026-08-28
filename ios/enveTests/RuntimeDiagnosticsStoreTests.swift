#if os(iOS)
import Foundation
import Testing

@testable import enve

@MainActor
struct RuntimeDiagnosticsStoreTests {
    @Test func storesOnlyBoundedDiagnosticSummaries() {
        let suiteName = "RuntimeDiagnosticsStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RuntimeDiagnosticsStore(defaults: defaults, storageKey: "runtime")
        let incidentDate = Date.now.addingTimeInterval(-60)

        store.record([.hang: 2, .crash: 1], at: incidentDate)
        store.recordMetricReport(at: .now)

        let cutoff = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        #expect(store.snapshot.count(.hang, since: cutoff) == 2)
        #expect(store.snapshot.count(.crash, since: cutoff) == 1)
        #expect(store.snapshot.recentIncidentCount(since: cutoff) == 3)
        #expect(store.snapshot.lastIncidentAt == incidentDate)
        #expect(store.snapshot.lastMetricReportAt != nil)

        let restored = RuntimeDiagnosticsStore(defaults: defaults, storageKey: "runtime")
        #expect(restored.snapshot.events == store.snapshot.events)
        #expect(restored.snapshot.lastMetricReportAt == store.snapshot.lastMetricReportAt)
    }
}
#endif
