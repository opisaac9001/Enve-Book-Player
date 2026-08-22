import Foundation

@MainActor
@Observable
final class BookIntelligenceSettingsStore {
    static let shared = BookIntelligenceSettingsStore()

    private static let playerButtonKey = "bookIntelligence.showPlayerButton"
    private static let backendKey = "bookIntelligence.librarianBackend"
    private static let serverURLKey = "bookIntelligence.librarianServerURL"
    private static let serverModelKey = "bookIntelligence.librarianServerModel"
    private static let serverAPIKeyKeychainKey = "librarianServerAPIKey"

    var showPlayerButton: Bool {
        didSet { userDefaults.set(showPlayerButton, forKey: Self.playerButtonKey) }
    }

    var librarianBackendID: String {
        didSet { userDefaults.set(librarianBackendID, forKey: Self.backendKey) }
    }

    var librarianServerURLString: String {
        didSet { userDefaults.set(librarianServerURLString, forKey: Self.serverURLKey) }
    }

    var librarianServerModel: String {
        didSet { userDefaults.set(librarianServerModel, forKey: Self.serverModelKey) }
    }

    var librarianServerAPIKey: String? {
        get { KeychainHelper.shared.get(Self.serverAPIKeyKeychainKey) }
        set {
            if let newValue, !newValue.isEmpty {
                KeychainHelper.shared.set(newValue, key: Self.serverAPIKeyKeychainKey)
            } else {
                KeychainHelper.shared.delete(Self.serverAPIKeyKeychainKey)
            }
        }
    }

    var librarianServerBaseURL: URL? {
        normalizedLibrarianServerURL(librarianServerURLString)
    }

    var librarianServerConfigured: Bool {
        librarianServerBaseURL != nil && !librarianServerModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var activeBackend: LibrarianBackend {
        librarianBackendID == OpenAICompatibleLibrarianBackend.shared.id
            ? OpenAICompatibleLibrarianBackend.shared
            : FoundationModelsLibrarianBackend.shared
    }

    @ObservationIgnored private let userDefaults = UserDefaults.standard

    private init() {
        if userDefaults.object(forKey: Self.playerButtonKey) == nil {
            showPlayerButton = true
        } else {
            showPlayerButton = userDefaults.bool(forKey: Self.playerButtonKey)
        }
        librarianBackendID = userDefaults.string(forKey: Self.backendKey) ?? "apple"
        librarianServerURLString = userDefaults.string(forKey: Self.serverURLKey) ?? ""
        librarianServerModel = userDefaults.string(forKey: Self.serverModelKey) ?? ""
    }
}
