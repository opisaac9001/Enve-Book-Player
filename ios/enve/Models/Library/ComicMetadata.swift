import Foundation

nonisolated enum ComicSection: String, Codable, CaseIterable, Sendable {
    case issues, volumes, specials

    var title: String {
        switch self {
        case .issues: "Issues"
        case .volumes: "Volumes"
        case .specials: "Specials"
        }
    }

    var sortOrder: Int {
        switch self {
        case .issues: 0
        case .volumes: 1
        case .specials: 2
        }
    }
}

nonisolated struct ComicMetadata: Codable, Equatable, Sendable {
    var seriesID: String
    var section: ComicSection = .issues
    var volumeID: String?
    var volumeTitle: String?
    var volumeOrder: Double?
    var issueLabel: String?
    var issueOrder: Double?
    var pageCount: Int?
    var resourceID: String?
}

nonisolated struct ComicSeriesSectionSummary: Hashable, Sendable {
    let section: ComicSection
    let count: Int
}

nonisolated enum ComicSeriesSlice: Hashable, Sendable {
    case section(ComicSection)
    case volume(section: ComicSection, id: String)
    case loose(ComicSection)

    func includes(_ metadata: ComicMetadata?) -> Bool {
        switch self {
        case .section(let section): (metadata?.section ?? .issues) == section
        case .volume(let section, let id): metadata?.section == section && metadata?.volumeID == id
        case .loose(let section): (metadata?.section ?? .issues) == section && metadata?.volumeID == nil
        }
    }
}

nonisolated struct ComicVolumeSummary: Hashable, Identifiable, Sendable {
    let section: ComicSection
    let volumeID: String
    let title: String?
    let order: Double?
    let count: Int

    var id: String { section.rawValue + "/" + volumeID }

    static func grouped(_ metadata: [ComicMetadata]) -> [ComicVolumeSummary] {
        var groups: [String: ComicVolumeSummary] = [:]
        for item in metadata {
            guard let volumeID = item.volumeID else { continue }
            let key = item.section.rawValue + "/" + volumeID
            let previous = groups[key]
            groups[key] = ComicVolumeSummary(
                section: item.section, volumeID: volumeID,
                title: previous?.title ?? item.volumeTitle, order: previous?.order ?? item.volumeOrder,
                count: (previous?.count ?? 0) + 1
            )
        }
        return groups.values.sorted {
            if $0.section != $1.section { return $0.section.sortOrder < $1.section.sortOrder }
            if $0.order != $1.order { return ($0.order ?? .greatestFiniteMagnitude) < ($1.order ?? .greatestFiniteMagnitude) }
            return $0.volumeID.localizedStandardCompare($1.volumeID) == .orderedAscending
        }
    }
}
