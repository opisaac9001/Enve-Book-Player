#if os(iOS)
import Foundation
import MetricKit
import Observation

enum RuntimeDiagnosticKind: String, Codable, CaseIterable, Sendable {
    case crash
    case hang
    case cpuException
    case diskWriteException
    case appLaunch
    case memoryException
}

struct RuntimeDiagnosticEvent: Codable, Equatable, Sendable {
    let kind: RuntimeDiagnosticKind
    let occurredAt: Date
}

struct RuntimeDiagnosticsSnapshot: Codable, Equatable, Sendable {
    var events: [RuntimeDiagnosticEvent] = []
    var lastMetricReportAt: Date?

    func count(_ kind: RuntimeDiagnosticKind, since date: Date) -> Int {
        events.count { $0.kind == kind && $0.occurredAt >= date }
    }

    func recentIncidentCount(since date: Date) -> Int {
        events.count {
            $0.occurredAt >= date && $0.kind != .appLaunch
        }
    }

    var lastIncidentAt: Date? {
        events.lazy
            .filter { $0.kind != .appLaunch }
            .map(\.occurredAt)
            .max()
    }
}

@MainActor
@Observable
final class RuntimeDiagnosticsStore {
    static let shared = RuntimeDiagnosticsStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var snapshot: RuntimeDiagnosticsSnapshot

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "enve.runtimeDiagnostics.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
            let stored = try? JSONDecoder().decode(RuntimeDiagnosticsSnapshot.self, from: data)
        {
            snapshot = stored
        } else {
            snapshot = RuntimeDiagnosticsSnapshot()
        }
        prune()
    }

    func record(_ kind: RuntimeDiagnosticKind, at date: Date) {
        snapshot.events.append(RuntimeDiagnosticEvent(kind: kind, occurredAt: date))
        prune()
        persist()
    }

    func record(_ counts: [RuntimeDiagnosticKind: Int], at date: Date) {
        for (kind, count) in counts where count > 0 {
            snapshot.events.append(contentsOf: repeatElement(RuntimeDiagnosticEvent(kind: kind, occurredAt: date), count: count))
        }
        prune()
        persist()
    }

    func recordMetricReport(at date: Date) {
        snapshot.lastMetricReportAt = max(snapshot.lastMetricReportAt ?? .distantPast, date)
        persist()
    }

    private func prune(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        snapshot.events = Array(snapshot.events.filter { $0.occurredAt >= cutoff }.suffix(100))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

@MainActor
final class RuntimeDiagnosticsCollector {
    static let shared = RuntimeDiagnosticsCollector()

    private var reportTasks: [Task<Void, Never>] = []
    private var currentManager: AnyObject?
    private var legacySubscriber: AnyObject?
    private var hasStarted = false

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            startCurrentReports()
        } else {
            startLegacyReports()
        }
        #else
        startLegacyReports()
        #endif
    }

    #if compiler(>=6.4)
    @available(iOS 27.0, *)
    private func startCurrentReports() {
        let manager = MetricManager()
        currentManager = manager

        reportTasks.append(
            Task { @MainActor in
                for await report in manager.diagnosticReports {
                    let kind: RuntimeDiagnosticKind
                    switch report.result {
                    case .crash: kind = .crash
                    case .hang: kind = .hang
                    case .cpuException: kind = .cpuException
                    case .diskWriteException: kind = .diskWriteException
                    case .appLaunch: kind = .appLaunch
                    case .memoryException: kind = .memoryException
                    @unknown default: continue
                    }
                    RuntimeDiagnosticsStore.shared.record(kind, at: report.timeRange.end)
                }
            }
        )
        reportTasks.append(
            Task { @MainActor in
                for await report in manager.metricReports {
                    RuntimeDiagnosticsStore.shared.recordMetricReport(at: report.timeRange.end)
                }
            }
        )
    }
    #endif

    @available(iOS, introduced: 17.0, obsoleted: 27.0)
    private func startLegacyReports() {
        let subscriber = LegacyRuntimeDiagnosticsSubscriber { counts, date in
            Task { @MainActor in
                RuntimeDiagnosticsStore.shared.record(counts, at: date)
            }
        } metricHandler: { date in
            Task { @MainActor in
                RuntimeDiagnosticsStore.shared.recordMetricReport(at: date)
            }
        }
        legacySubscriber = subscriber
        MXMetricManager.shared.add(subscriber)
    }
}

@available(iOS, introduced: 17.0, obsoleted: 27.0)
private nonisolated final class LegacyRuntimeDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    private let diagnosticHandler: @Sendable ([RuntimeDiagnosticKind: Int], Date) -> Void
    private let metricHandler: @Sendable (Date) -> Void

    init(
        diagnosticHandler: @escaping @Sendable ([RuntimeDiagnosticKind: Int], Date) -> Void,
        metricHandler: @escaping @Sendable (Date) -> Void
    ) {
        self.diagnosticHandler = diagnosticHandler
        self.metricHandler = metricHandler
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            diagnosticHandler(
                [
                    .crash: payload.crashDiagnostics?.count ?? 0,
                    .hang: payload.hangDiagnostics?.count ?? 0,
                    .cpuException: payload.cpuExceptionDiagnostics?.count ?? 0,
                    .diskWriteException: payload.diskWriteExceptionDiagnostics?.count ?? 0,
                    .appLaunch: payload.appLaunchDiagnostics?.count ?? 0,
                ],
                payload.timeStampEnd
            )
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            metricHandler(payload.timeStampEnd)
        }
    }
}
#endif
