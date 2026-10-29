import Foundation

nonisolated struct ProfileStorageLocations: Sendable {
    static var owner: ProfileStorageLocations {
        Self(profileID: FamilyProfile.ownerID)
    }

    let profileID: String
    let documentsDirectory: URL
    let applicationSupportDirectory: URL
    let cachesDirectory: URL

    var bookStoreURL: URL {
        documentsDirectory.appendingPathComponent("BookStore.sqlite")
    }

    var historyDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Enve/History", isDirectory: true)
    }

    var preferencesDomain: String? {
        profileID == FamilyProfile.ownerID ? nil : "com.enve.enve.profiles.\(profileID)"
    }

    func openPreferences() throws -> UserDefaults {
        guard let preferencesDomain else { return .standard }
        guard let defaults = UserDefaults(suiteName: preferencesDomain) else {
            throw ProfileStorageError.preferencesUnavailable
        }
        return defaults
    }

    init(
        profileID: String,
        documentsDirectory: URL? = nil,
        applicationSupportDirectory: URL? = nil,
        cachesDirectory: URL = .cachesDirectory
    ) {
        precondition(FamilyProfile.validID(profileID))
        #if os(tvOS)
        // tvOS restricts writable files to caches and temporary storage.
        let documentsDirectory = documentsDirectory ?? cachesDirectory
        let applicationSupportDirectory = applicationSupportDirectory ?? cachesDirectory
        #else
        let documentsDirectory = documentsDirectory ?? .documentsDirectory
        let applicationSupportDirectory = applicationSupportDirectory ?? .applicationSupportDirectory
        #endif
        self.profileID = profileID
        if profileID == FamilyProfile.ownerID {
            self.documentsDirectory = documentsDirectory
            self.applicationSupportDirectory = applicationSupportDirectory
            self.cachesDirectory = cachesDirectory
        } else {
            let root = applicationSupportDirectory
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(profileID, isDirectory: true)
            self.documentsDirectory = root.appendingPathComponent("Documents", isDirectory: true)
            self.applicationSupportDirectory = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
            self.cachesDirectory = cachesDirectory
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(profileID, isDirectory: true)
        }
    }
}

enum ProfileStorageError: Error {
    case preferencesUnavailable
}
