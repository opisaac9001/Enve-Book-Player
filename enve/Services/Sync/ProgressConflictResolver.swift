import Foundation

enum SyncDirection: Equatable, Sendable {
    case pull
    case push
    case conflict
    case none
}

struct ProgressConflictResolver: Sendable {
    private static let timestampTieWindow: TimeInterval = 2

    static func resolve(
        localPosition: Double,
        localDate: Date,
        serverPosition: Double,
        serverDate: Date,
        protectsAgainstBackwardProgress: Bool = false
    ) -> SyncDirection {
        if localPosition <= 0 && serverPosition <= 0 { return .none }
        if localPosition <= 0 { return .pull }
        if serverPosition <= 0 { return .push }

        let positionDelta = abs(serverPosition - localPosition)
        let tolerance = max(localPosition, serverPosition) > 1.5 ? 2.0 : 0.005
        if positionDelta < tolerance { return .none }

        let dateDelta = abs(serverDate.timeIntervalSince(localDate))
        if dateDelta < timestampTieWindow {
            if serverPosition > localPosition { return .pull }
            if localPosition > serverPosition { return .push }
            return .none
        }

        if serverDate > localDate {
            if protectsAgainstBackwardProgress, serverPosition < localPosition {
                return .conflict
            }
            return .pull
        }

        if localDate > serverDate {
            if protectsAgainstBackwardProgress, localPosition < serverPosition {
                return .conflict
            }
            return .push
        }

        if serverPosition > localPosition { return .pull }
        if localPosition > serverPosition { return .push }
        return .none
    }
}

func resolveProgressConflict(
    localPosition: Double,
    localDate: Date,
    serverPosition: Double,
    serverDate: Date
) -> SyncDirection {
    ProgressConflictResolver.resolve(
        localPosition: localPosition,
        localDate: localDate,
        serverPosition: serverPosition,
        serverDate: serverDate
    )
}

func resolveProgressConflictWithBackwardCheck(
    localPosition: Double,
    localDate: Date,
    serverPosition: Double,
    serverDate: Date
) -> SyncDirection {
    ProgressConflictResolver.resolve(
        localPosition: localPosition,
        localDate: localDate,
        serverPosition: serverPosition,
        serverDate: serverDate,
        protectsAgainstBackwardProgress: true
    )
}
