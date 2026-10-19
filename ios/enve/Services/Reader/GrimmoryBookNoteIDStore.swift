import Foundation

// Grimmory book notes have their own id space, so they never occupy ReaderAnnotation.remoteID.
@MainActor
protocol GrimmoryBookNoteIDMapping: AnyObject {
    func noteID(connectionID: UUID, bookID: String, localID: String) -> Int?
    func localID(connectionID: UUID, bookID: String, noteID: Int) -> String?
    func setNoteID(_ noteID: Int, connectionID: UUID, bookID: String, localID: String)
    func removeNoteID(connectionID: UUID, bookID: String, localID: String)
}

@MainActor
final class GrimmoryBookNoteIDStore: GrimmoryBookNoteIDMapping {
    static let shared = GrimmoryBookNoteIDStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func noteID(connectionID: UUID, bookID: String, localID: String) -> Int? {
        map(connectionID: connectionID, bookID: bookID)[localID]
    }

    func localID(connectionID: UUID, bookID: String, noteID: Int) -> String? {
        map(connectionID: connectionID, bookID: bookID).first(where: { $0.value == noteID })?.key
    }

    func setNoteID(_ noteID: Int, connectionID: UUID, bookID: String, localID: String) {
        var map = map(connectionID: connectionID, bookID: bookID)
        map[localID] = noteID
        defaults.set(map, forKey: key(connectionID: connectionID, bookID: bookID))
    }

    func removeNoteID(connectionID: UUID, bookID: String, localID: String) {
        var map = map(connectionID: connectionID, bookID: bookID)
        map.removeValue(forKey: localID)
        defaults.set(map, forKey: key(connectionID: connectionID, bookID: bookID))
    }

    private func map(connectionID: UUID, bookID: String) -> [String: Int] {
        defaults.dictionary(forKey: key(connectionID: connectionID, bookID: bookID)) as? [String: Int] ?? [:]
    }

    private func key(connectionID: UUID, bookID: String) -> String {
        "grimmory.reader.bookNoteIds.\(connectionID.uuidString).\(bookID)"
    }
}
