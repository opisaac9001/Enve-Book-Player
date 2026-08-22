#if DEBUG
import Foundation

struct SyncConflictScenarioResult: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let expected: SyncDirection
    let actual: SyncDirection

    var passed: Bool { expected == actual }
}

enum SyncConflictScenarioRunner {
    static func run() -> [SyncConflictScenarioResult] {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = now.addingTimeInterval(-60)
        let newer = now.addingTimeInterval(60)
        let withinWindow = now.addingTimeInterval(1)

        let scenarios: [(String, Double, Date, Double, Date, Bool, SyncDirection)] = [
            ("both zero", 0, now, 0, newer, false, .none),
            ("local empty pulls server", 0, now, 0.35, older, false, .pull),
            ("server empty pushes local", 0.35, older, 0, newer, false, .push),
            ("local newer pushes", 0.4, newer, 0.2, older, false, .push),
            ("server newer pulls", 0.2, older, 0.4, newer, false, .pull),
            ("within window picks server higher", 0.2, now, 0.4, withinWindow, false, .pull),
            ("within window picks local higher", 0.4, now, 0.2, withinWindow, false, .push),
            ("equal progress no-ops", 0.4, older, 0.401, newer, false, .none),
            ("backward guard conflicts server regression", 0.6, older, 0.2, newer, true, .conflict),
            ("backward guard conflicts local regression", 0.2, newer, 0.6, older, true, .conflict),
        ]

        return scenarios.map { scenario in
            let actual = ProgressConflictResolver.resolve(
                localPosition: scenario.1,
                localDate: scenario.2,
                serverPosition: scenario.3,
                serverDate: scenario.4,
                protectsAgainstBackwardProgress: scenario.5
            )
            return SyncConflictScenarioResult(name: scenario.0, expected: scenario.6, actual: actual)
        }
    }
}
#endif
