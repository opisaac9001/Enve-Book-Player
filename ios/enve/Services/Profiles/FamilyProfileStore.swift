import Foundation

@MainActor
@Observable
final class FamilyProfileStore {
    private let fileURL: URL
    private let pinStore: AdultPINStore

    private(set) var profiles: [FamilyProfile]

    init(
        fileURL: URL = URL.applicationSupportDirectory.appendingPathComponent("Profiles/catalog.json"),
        pinStore: AdultPINStore = .shared
    ) throws {
        self.fileURL = fileURL
        self.pinStore = pinStore
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let saved = try JSONDecoder().decode([FamilyProfile].self, from: Data(contentsOf: fileURL))
            guard saved.first?.id == FamilyProfile.ownerID,
                saved.first?.role == .adult,
                Set(saved.map(\.id)).count == saved.count,
                saved.allSatisfy({ FamilyProfile.validID($0.id) && Self.validName($0.name) })
            else {
                throw FamilyProfileError.invalidCatalog
            }
            profiles = saved
        } else {
            profiles = [FamilyProfile(id: FamilyProfile.ownerID, name: "Adult", role: .adult)]
        }
    }

    @discardableResult
    func addAdult(name: String) throws -> FamilyProfile {
        try add(name: name, role: .adult)
    }

    @discardableResult
    func addChild(name: String) throws -> FamilyProfile {
        guard try pinStore.isConfigured() else { throw AdultPINError.notConfigured }
        return try add(name: name, role: .child)
    }

    func rename(profileID: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(trimmed) else { throw FamilyProfileError.invalidName }
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw FamilyProfileError.profileNotFound
        }
        var updated = profiles
        updated[index].name = trimmed
        try save(updated)
    }

    func remove(profileID: String) throws {
        guard profileID != FamilyProfile.ownerID,
            profiles.contains(where: { $0.id == profileID })
        else { throw FamilyProfileError.profileNotFound }
        try save(profiles.filter { $0.id != profileID })
    }

    private func add(name: String, role: FamilyProfileRole) throws -> FamilyProfile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validName(trimmed) else { throw FamilyProfileError.invalidName }
        let profile = FamilyProfile(id: UUID().uuidString, name: trimmed, role: role)
        try save(profiles + [profile])
        return profile
    }

    private func save(_ updated: [FamilyProfile]) throws {
        let data = try JSONEncoder().encode(updated)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        profiles = updated
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf16.count <= 40 &&
            name == name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
