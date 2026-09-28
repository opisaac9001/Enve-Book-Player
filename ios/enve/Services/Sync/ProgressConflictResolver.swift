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
        protectsAgainstBackwardProgress: Bool = false,
        localLocator: String? = nil,
        serverLocator: String? = nil
    ) -> SyncDirection {
        let localCFI = EpubLocationBridge.sourceEngine(from: localLocator) == .foliate
            ? EpubLocationBridge.canonicalFullEPUBCFI(EpubLocationBridge.epubCFI(from: localLocator)) : nil
        let serverCFI = EpubLocationBridge.sourceEngine(from: serverLocator) == .foliate
            ? EpubLocationBridge.canonicalFullEPUBCFI(EpubLocationBridge.epubCFI(from: serverLocator)) : nil
        if localCFI != serverCFI, localDate != .distantPast, serverDate != .distantPast {
            if serverCFI != nil, serverDate > localDate { return .pull }
            if localCFI != nil, localDate > serverDate { return .push }
        }
        // Narrated positions resolve to an exact sentence, so a newer sentence wins even inside the percentage tolerance.
        let localSentence = narratedSentence(in: localLocator)
        let serverSentence = narratedSentence(in: serverLocator)
        if localSentence != serverSentence, localDate != .distantPast, serverDate != .distantPast,
            abs(serverDate.timeIntervalSince(localDate)) >= timestampTieWindow
        {
            if serverSentence != nil, serverDate > localDate, !protectsAgainstBackwardProgress || serverPosition >= localPosition - 0.005 {
                return .pull
            }
            if localSentence != nil, localDate > serverDate, !protectsAgainstBackwardProgress || localPosition >= serverPosition - 0.005 {
                return .push
            }
        }
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

    private static func narratedSentence(in locator: String?) -> String? {
        guard let data = locator?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let href = object["href"] as? String,
            let locations = object["locations"] as? [String: Any]
        else { return nil }
        if let fragment = (locations["fragments"] as? [Any])?.compactMap({ $0 as? String })
            .first(where: { !$0.hasPrefix("t=") && !$0.hasPrefix("epubcfi(") })
        {
            return "\(EpubLocationBridge.normalizedHref(href))#\(fragment)"
        }
        if let start = (locations["domRange"] as? [String: Any])?["start"] as? [String: Any],
            let selector = start["cssSelector"] as? String,
            selector.hasPrefix("#"), selector.count > 1,
            !selector.dropFirst().contains(where: { " >.:[".contains($0) })
        {
            return "\(EpubLocationBridge.normalizedHref(href))\(selector)"
        }
        return nil
    }
}


func resolveProgressConflict(
    localPosition: Double,
    localDate: Date,
    serverPosition: Double,
    serverDate: Date,
    localLocator: String? = nil,
    serverLocator: String? = nil
) -> SyncDirection {
    ProgressConflictResolver.resolve(
        localPosition: localPosition,
        localDate: localDate,
        serverPosition: serverPosition,
        serverDate: serverDate,
        localLocator: localLocator,
        serverLocator: serverLocator
    )
}

func resolveProgressConflictWithBackwardCheck(
    localPosition: Double,
    localDate: Date,
    serverPosition: Double,
    serverDate: Date,
    localLocator: String? = nil,
    serverLocator: String? = nil
) -> SyncDirection {
    ProgressConflictResolver.resolve(
        localPosition: localPosition,
        localDate: localDate,
        serverPosition: serverPosition,
        serverDate: serverDate,
        protectsAgainstBackwardProgress: true,
        localLocator: localLocator,
        serverLocator: serverLocator
    )
}
