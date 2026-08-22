import Foundation

@MainActor
protocol SiloReaderArtifactIDMapping: AnyObject {
    func annotationRemoteID(connectionID: UUID, bookID: String, localID: String) -> String?
    func setAnnotationRemoteID(_ remoteID: String, connectionID: UUID, bookID: String, localID: String)
    func removeAnnotationRemoteID(connectionID: UUID, bookID: String, localID: String)
    func localAnnotationID(connectionID: UUID, bookID: String, remoteID: String) -> String?

    func bookmarkRemoteID(connectionID: UUID, bookID: String, localID: String) -> String?
    func setBookmarkRemoteID(_ remoteID: String, connectionID: UUID, bookID: String, localID: String)
    func removeBookmarkRemoteID(connectionID: UUID, bookID: String, localID: String)
    func localBookmarkID(connectionID: UUID, bookID: String, remoteID: String) -> String?
}

@MainActor
final class SiloReaderArtifactIDStore: SiloReaderArtifactIDMapping {
    static let shared = SiloReaderArtifactIDStore()

    private let defaults = UserDefaults.standard

    private init() {}

    func annotationRemoteID(connectionID: UUID, bookID: String, localID: String) -> String? {
        annotationMap(connectionID: connectionID, bookID: bookID)[localID]
    }

    func setAnnotationRemoteID(_ remoteID: String, connectionID: UUID, bookID: String, localID: String) {
        var map = annotationMap(connectionID: connectionID, bookID: bookID)
        map[localID] = remoteID
        defaults.set(map, forKey: annotationKey(connectionID: connectionID, bookID: bookID))
    }

    func removeAnnotationRemoteID(connectionID: UUID, bookID: String, localID: String) {
        var map = annotationMap(connectionID: connectionID, bookID: bookID)
        map.removeValue(forKey: localID)
        defaults.set(map, forKey: annotationKey(connectionID: connectionID, bookID: bookID))
    }

    func localAnnotationID(connectionID: UUID, bookID: String, remoteID: String) -> String? {
        annotationMap(connectionID: connectionID, bookID: bookID).first(where: { $0.value == remoteID })?.key
    }

    func bookmarkRemoteID(connectionID: UUID, bookID: String, localID: String) -> String? {
        bookmarkMap(connectionID: connectionID, bookID: bookID)[localID]
    }

    func setBookmarkRemoteID(_ remoteID: String, connectionID: UUID, bookID: String, localID: String) {
        var map = bookmarkMap(connectionID: connectionID, bookID: bookID)
        map[localID] = remoteID
        defaults.set(map, forKey: bookmarkKey(connectionID: connectionID, bookID: bookID))
    }

    func removeBookmarkRemoteID(connectionID: UUID, bookID: String, localID: String) {
        var map = bookmarkMap(connectionID: connectionID, bookID: bookID)
        map.removeValue(forKey: localID)
        defaults.set(map, forKey: bookmarkKey(connectionID: connectionID, bookID: bookID))
    }

    func localBookmarkID(connectionID: UUID, bookID: String, remoteID: String) -> String? {
        bookmarkMap(connectionID: connectionID, bookID: bookID).first(where: { $0.value == remoteID })?.key
    }

    private func annotationMap(connectionID: UUID, bookID: String) -> [String: String] {
        defaults.dictionary(forKey: annotationKey(connectionID: connectionID, bookID: bookID)) as? [String: String] ?? [:]
    }

    private func bookmarkMap(connectionID: UUID, bookID: String) -> [String: String] {
        defaults.dictionary(forKey: bookmarkKey(connectionID: connectionID, bookID: bookID)) as? [String: String] ?? [:]
    }

    private func annotationKey(connectionID: UUID, bookID: String) -> String {
        "silo.reader.annotationIds.\(connectionID.uuidString).\(bookID)"
    }

    private func bookmarkKey(connectionID: UUID, bookID: String) -> String {
        "silo.reader.bookmarkIds.\(connectionID.uuidString).\(bookID)"
    }
}
